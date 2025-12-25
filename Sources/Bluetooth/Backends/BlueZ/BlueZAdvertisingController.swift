#if os(Linux)
#if canImport(FoundationEssentials)
import FoundationEssentials
import Foundation
#else
import Foundation
#endif

import DBUS
import NIOCore

#if canImport(Glibc)
import Glibc
#endif

actor _BlueZAdvertisingController {
    private let adapterPath = "/org/bluez/hci0"
    private let bluezBusName = "org.bluez"

    private var isAdvertising = false
    private var stopRequested = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var task: Task<Void, Never>?
    private var activePath: String?

    func startAdvertising(
        advertisingData: AdvertisementData,
        scanResponseData: AdvertisementData?,
        parameters: AdvertisingParameters
    ) async throws {
        if isAdvertising {
            throw BluetoothError.invalidState("BlueZ advertising already in progress")
        }

        let verbose = ProcessInfo.processInfo.environment["BLUETOOTH_BLUEZ_VERBOSE"] == "1"
        let merged = merge(advertisingData: advertisingData, scanResponseData: scanResponseData, verbose: verbose)
        let path = makeAdvertisementPath()
        activePath = path
        isAdvertising = true
        stopRequested = false

        let config = AdvertisementConfig(
            path: path,
            type: parameters.isConnectable ? "peripheral" : "broadcast",
            includeTxPower: parameters.includeTxPower,
            data: merged,
            parameters: parameters,
            verbose: verbose
        )

        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            task = Task { [weak self] in
                await self?.runDbusAdvertising(config)
            }
        }
    }

    func stopAdvertising() async {
        guard isAdvertising else {
            cleanup()
            return
        }

        stopRequested = true
        if let continuation = stopContinuation {
            stopContinuation = nil
            continuation.resume()
        }

        if let task {
            await task.value
        }
        cleanup()
    }

    private func runDbusAdvertising(_ config: AdvertisementConfig) async {
        do {
            let address = try SocketAddress(unixDomainSocketPath: "/var/run/dbus/system_bus_socket")
            let auth = AuthType.external(userID: String(getuid()))

            let object = makeAdvertisementObject(config: config)
            try await DBusClient.withConnection(to: address, auth: auth) { connection in
                let server = DBusObjectServer(connection: connection)
                await server.export(object)

                if config.verbose {
                    print("[bluez] Registering advertisement at \(config.path)")
                }
                try await self.registerAdvertisement(connection, path: config.path)
                if config.verbose {
                    print("[bluez] Advertisement registered")
                }
                await self.resumeStartIfNeeded()
                await self.waitForStop()
                if config.verbose {
                    print("[bluez] Unregistering advertisement")
                }
                try await self.unregisterAdvertisement(connection, path: config.path)
                await server.unexport(path: config.path)
            }
        } catch {
            resumeStartIfNeeded(error: error)
        }

        cleanup()
    }

    private func makeAdvertisementObject(config: AdvertisementConfig) -> DBusObjectServer.ExportedObject {
        let release = DBusObjectServer.Method(name: "Release") { [weak self] _ in
            await self?.handleRelease()
            return []
        }

        let properties = buildProperties(config: config)
        let iface = DBusObjectServer.Interface(
            name: "org.bluez.LEAdvertisement1",
            methods: [release],
            properties: properties,
            signals: []
        )

        return DBusObjectServer.ExportedObject(path: config.path, interfaces: [iface])
    }

    private func registerAdvertisement(_ connection: DBusClient.Connection, path: String) async throws {
        let request = DBusRequest.createMethodCall(
            destination: bluezBusName,
            path: adapterPath,
            interface: "org.bluez.LEAdvertisingManager1",
            method: "RegisterAdvertisement",
            body: [
                .objectPath(path),
                .dictionary([:]),
            ]
        )

        guard let reply = try await connection.send(request) else { return }
        if reply.messageType == .error {
            let name = dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
            throw BluetoothError.invalidState("D-Bus RegisterAdvertisement failed: \(name)")
        }
    }

    private func unregisterAdvertisement(_ connection: DBusClient.Connection, path: String) async throws {
        let request = DBusRequest.createMethodCall(
            destination: bluezBusName,
            path: adapterPath,
            interface: "org.bluez.LEAdvertisingManager1",
            method: "UnregisterAdvertisement",
            body: [
                .objectPath(path)
            ]
        )

        guard let reply = try await connection.send(request) else { return }
        if reply.messageType == .error {
            let name = dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
            if name == "org.bluez.Error.DoesNotExist" {
                return
            }
            throw BluetoothError.invalidState("D-Bus UnregisterAdvertisement failed: \(name)")
        }
    }

    private func handleRelease() async {
        stopRequested = true
        if let continuation = stopContinuation {
            stopContinuation = nil
            continuation.resume()
        }
    }

    private func waitForStop() async {
        if stopRequested {
            stopRequested = false
            return
        }

        await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
        stopContinuation = nil
        stopRequested = false
    }

    private func resumeStartIfNeeded(error: Error? = nil) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func buildProperties(config: AdvertisementConfig) -> [DBusObjectServer.Property] {
        var properties: [DBusObjectServer.Property] = []
        properties.append(.init(name: "Type", value: .string(config.type)))

        if let name = config.data.localName, !name.isEmpty {
            properties.append(.init(name: "LocalName", value: .string(name)))
        }

        if !config.data.serviceUUIDs.isEmpty {
            let values = config.data.serviceUUIDs.map { DBusValue.string($0.description) }
            properties.append(.init(name: "ServiceUUIDs", value: .array(values)))
        }

        if let manufacturer = config.data.manufacturerData, !manufacturer.data.isEmpty {
            let bytes = manufacturer.data.map { DBusValue.byte($0) }
            let dict: [DBusValue: DBusValue] = [
                .uint16(manufacturer.companyIdentifier): .variant(DBusVariant(.array(bytes)))
            ]
            properties.append(.init(name: "ManufacturerData", value: .dictionary(dict)))
        }

        if !config.data.serviceData.isEmpty {
            var dict: [DBusValue: DBusValue] = [:]
            for (uuid, data) in config.data.serviceData where !data.isEmpty {
                let bytes = data.map { DBusValue.byte($0) }
                dict[.string(uuid.description)] = .variant(DBusVariant(.array(bytes)))
            }
            if !dict.isEmpty {
                properties.append(.init(name: "ServiceData", value: .dictionary(dict)))
            }
        }

        if config.includeTxPower {
            properties.append(.init(name: "IncludeTxPower", value: .boolean(true)))
        }

        if config.verbose {
            if config.parameters.interval != nil {
                print("[bluez] Advertising interval is not configurable via D-Bus backend yet.")
            }
            if config.parameters.primaryPHY != nil || config.parameters.secondaryPHY != nil {
                print("[bluez] PHY selection is not configurable via D-Bus backend yet.")
            }
            if config.parameters.isExtended {
                print("[bluez] Extended advertising is not configurable via D-Bus backend yet.")
            }
        }

        return properties
    }

    private func merge(
        advertisingData: AdvertisementData,
        scanResponseData: AdvertisementData?,
        verbose: Bool
    ) -> AdvertisementData {
        guard let scanResponseData else { return advertisingData }

        var merged = advertisingData

        if merged.localName == nil || merged.localName?.isEmpty == true {
            if let fallback = scanResponseData.localName, !fallback.isEmpty {
                merged.localName = fallback
            }
        }

        if !scanResponseData.serviceUUIDs.isEmpty {
            let combined = advertisingData.serviceUUIDs + scanResponseData.serviceUUIDs
            let unique = Array(Set(combined))
            merged.serviceUUIDs = unique
        }

        if let manufacturer = scanResponseData.manufacturerData, merged.manufacturerData == nil {
            merged.manufacturerData = manufacturer
        } else if scanResponseData.manufacturerData != nil, merged.manufacturerData != nil, verbose {
            print("[bluez] scanResponseData manufacturer data ignored (already set in advertising data).")
        }

        if !scanResponseData.serviceData.isEmpty {
            var combined = merged.serviceData
            for (uuid, data) in scanResponseData.serviceData {
                if combined[uuid] == nil {
                    combined[uuid] = data
                } else if verbose {
                    print("[bluez] scanResponseData service data for \(uuid) ignored (already set).")
                }
            }
            merged.serviceData = combined
        }

        return merged
    }

    private func makeAdvertisementPath() -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return "/org/wendylabsinc/bluetooth/advertisement\(suffix)"
    }

    private func dbusErrorName(_ message: DBusMessage) -> String? {
        guard
            let field = message.headerFields.first(where: { $0.code == .errorName }),
            case .string(let name) = field.variant.value
        else {
            return nil
        }
        return name
    }

    private func cleanup() {
        activePath = nil
        isAdvertising = false
        stopRequested = false
        stopContinuation = nil
        startContinuation = nil
        task?.cancel()
        task = nil
    }

    private struct AdvertisementConfig {
        let path: String
        let type: String
        let includeTxPower: Bool
        let data: AdvertisementData
        let parameters: AdvertisingParameters
        let verbose: Bool
    }
}

#endif
