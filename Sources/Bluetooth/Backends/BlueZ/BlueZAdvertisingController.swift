#if os(Linux)
#if canImport(FoundationEssentials)
import FoundationEssentials
import Foundation
#else
import Foundation
#endif

import DBUS
import Logging
import NIOCore

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

actor _BlueZAdvertisingController {
    private let client: BlueZClient
    private let adapterPath: String
    private let registerTimeoutNanos: UInt64 = 10 * 1_000_000_000
    private let registerRetryDelayNanos: UInt64 = 500 * 1_000_000
    private let registerMaxAttempts = 3

    private var isAdvertising = false
    private var stopRequested = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var task: Task<Void, Never>?
    private var activePath: String?

    private var logger: Logger {
        var logger = BluetoothLogger.advertising
        logger[metadataKey: BluetoothLogMetadata.adapterPath] = "\(adapterPath)"
        if let activePath {
            logger[metadataKey: BluetoothLogMetadata.advertisementPath] = "\(activePath)"
        }
        return logger
    }

    init(client: BlueZClient, adapterPath: String) {
        self.client = client
        self.adapterPath = adapterPath
    }

    func startAdvertising(
        advertisingData: AdvertisementData,
        scanResponseData: AdvertisementData?,
        parameters: AdvertisingParameters
    ) async throws {
        if isAdvertising {
            logger.warning("Advertising already in progress, rejecting new request")
            throw BluetoothError.invalidState("BlueZ advertising already in progress")
        }

        let merged = merge(advertisingData: advertisingData, scanResponseData: scanResponseData)
        let path = makeAdvertisementPath()
        activePath = path
        isAdvertising = true
        stopRequested = false

        logger.debug("Starting advertising", metadata: [
            BluetoothLogMetadata.advertisementPath: "\(path)",
            "type": "\(parameters.isConnectable ? "peripheral" : "broadcast")",
            "includeTxPower": "\(parameters.includeTxPower)"
        ])

        let config = AdvertisementConfig(
            path: path,
            type: parameters.isConnectable ? "peripheral" : "broadcast",
            includeTxPower: parameters.includeTxPower,
            data: merged,
            parameters: parameters
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
            let connection = try await client.getConnection()
            let server = try await client.getObjectServer()

            // Ensure the adapter is powered on before advertising
            try await ensureAdapterPowered(connection)

            // Proactively try to clean up any stale advertisement from a crashed process
            // This is a no-op if nothing is registered at this path
            logger.debug("Cleaning up any stale advertisement at path")
            try? await unregisterAdvertisement(connection, path: config.path)
            await server.unexport(path: config.path)

            let object = makeAdvertisementObject(config: config)
            await server.export(object)

            logger.debug("Registering advertisement via D-Bus", metadata: [
                BluetoothLogMetadata.advertisementPath: "\(config.path)"
            ])
            try await registerAdvertisement(connection, path: config.path)
            logger.debug("Advertisement registered successfully")

            await resumeStartIfNeeded()
            await waitForStop()

            logger.debug("Unregistering advertisement")
            try await unregisterAdvertisement(connection, path: config.path)
            await server.unexport(path: config.path)
            logger.debug("Advertisement stopped")
        } catch {
            logger.error("Advertising failed", metadata: [
                BluetoothLogMetadata.error: "\(error)"
            ])
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
        logger.debug("Advertisement properties", metadata: [
            "propertyCount": "\(properties.count)",
            "propertyNames": "\(properties.map { $0.name }.joined(separator: ", "))"
        ])
        let iface = DBusObjectServer.Interface(
            name: "org.bluez.LEAdvertisement1",
            methods: [release],
            properties: properties,
            signals: []
        )

        return DBusObjectServer.ExportedObject(path: config.path, interfaces: [iface])
    }

    private func registerAdvertisement(
        _ connection: DBusClient.Connection,
        path: String
    ) async throws {
        var lastError: Error?
        for attempt in 1...registerMaxAttempts {
            do {
                let request = makeRegisterRequest(path: path)
                let reply = try await sendWithTimeout(
                    connection,
                    request: request,
                    timeoutNanos: registerTimeoutNanos,
                    action: "RegisterAdvertisement"
                )

                if let reply, reply.messageType == .error {
                    let name = client.dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"

                    // If AlreadyExists, try to unregister from BlueZ and retry on any attempt
                    // Note: We don't need to re-export the D-Bus object - it's already exported
                    // We just need to tell BlueZ to forget its stale registration
                    if name == "org.bluez.Error.AlreadyExists" && attempt < registerMaxAttempts {
                        logger.debug("Stale advertisement found, unregistering from BlueZ before retry", metadata: [
                            BluetoothLogMetadata.attempt: "\(attempt)"
                        ])
                        try? await unregisterAdvertisement(connection, path: path)
                        try await Task.sleep(nanoseconds: registerRetryDelayNanos)
                        continue
                    }

                    throw BluetoothError.invalidState("D-Bus RegisterAdvertisement failed: \(name)")
                }
                logger.trace("RegisterAdvertisement succeeded", metadata: [
                    BluetoothLogMetadata.attempt: "\(attempt)"
                ])
                return
            } catch {
                lastError = error
                if attempt < registerMaxAttempts {
                    logger.warning("RegisterAdvertisement attempt failed, retrying", metadata: [
                        BluetoothLogMetadata.attempt: "\(attempt)",
                        BluetoothLogMetadata.maxAttempts: "\(registerMaxAttempts)",
                        BluetoothLogMetadata.error: "\(error)"
                    ])
                    try await Task.sleep(nanoseconds: registerRetryDelayNanos)
                }
            }
        }

        logger.error("RegisterAdvertisement failed after all attempts", metadata: [
            BluetoothLogMetadata.maxAttempts: "\(registerMaxAttempts)",
            BluetoothLogMetadata.error: "\(lastError.map { "\($0)" } ?? "unknown")"
        ])
        throw lastError ?? BluetoothError.invalidState("D-Bus RegisterAdvertisement failed")
    }

    private func unregisterAdvertisement(
        _ connection: DBusClient.Connection,
        path: String
    ) async throws {
        let request = makeUnregisterRequest(path: path)
        let reply = try await sendWithTimeout(
            connection,
            request: request,
            timeoutNanos: registerTimeoutNanos,
            action: "UnregisterAdvertisement"
        )

        guard let reply else { return }
        if reply.messageType == .error {
            let name = client.dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
            if name == "org.bluez.Error.DoesNotExist" {
                logger.debug("Advertisement already unregistered (DoesNotExist)")
                return
            }
            logger.error("UnregisterAdvertisement failed", metadata: [
                BluetoothLogMetadata.error: "\(name)"
            ])
            throw BluetoothError.invalidState("D-Bus UnregisterAdvertisement failed: \(name)")
        }
    }

    private func sendWithTimeout(
        _ connection: DBusClient.Connection,
        request: DBusRequest,
        timeoutNanos: UInt64,
        action: String
    ) async throws -> DBusMessage? {
        try await withThrowingTaskGroup(of: DBusMessage?.self) { group in
            group.addTask {
                try await connection.send(request)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanos)
                throw BluetoothError.invalidState("D-Bus \(action) timed out")
            }

            let result = try await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func makeRegisterRequest(path: String) -> DBusRequest {
        DBusRequest.createMethodCall(
            destination: client.busName,
            path: adapterPath,
            interface: "org.bluez.LEAdvertisingManager1",
            method: "RegisterAdvertisement",
            body: [
                .objectPath(path),
                .dictionary([:]),
            ],
            signature: "oa{sv}"  // Explicitly specify signature for empty dictionary
        )
    }

    private func makeUnregisterRequest(path: String) -> DBusRequest {
        DBusRequest.createMethodCall(
            destination: client.busName,
            path: adapterPath,
            interface: "org.bluez.LEAdvertisingManager1",
            method: "UnregisterAdvertisement",
            body: [
                .objectPath(path)
            ]
        )
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
            logger.debug("Advertisement LocalName set", metadata: ["name": "\(name)"])
        } else {
            logger.warning("Advertisement has no LocalName - device may not be discoverable by name")
        }

        if !config.data.serviceUUIDs.isEmpty {
            let values = config.data.serviceUUIDs.map { DBusValue.string($0.description) }
            logger.debug("Adding ServiceUUIDs to advertisement", metadata: [
                "uuids": "\(config.data.serviceUUIDs.map { $0.description }.joined(separator: ", "))"
            ])
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

        if config.parameters.interval != nil {
            logger.notice("Advertising interval is not configurable via D-Bus backend")
        }
        if config.parameters.primaryPHY != nil || config.parameters.secondaryPHY != nil {
            logger.notice("PHY selection is not configurable via D-Bus backend")
        }
        if config.parameters.isExtended {
            logger.notice("Extended advertising is not configurable via D-Bus backend")
        }

        return properties
    }

    private func merge(
        advertisingData: AdvertisementData,
        scanResponseData: AdvertisementData?
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
        } else if scanResponseData.manufacturerData != nil, merged.manufacturerData != nil {
            logger.debug("scanResponseData manufacturer data ignored (already set in advertising data)")
        }

        if !scanResponseData.serviceData.isEmpty {
            var combined = merged.serviceData
            for (uuid, data) in scanResponseData.serviceData {
                if combined[uuid] == nil {
                    combined[uuid] = data
                } else {
                    logger.debug("scanResponseData service data ignored (already set)", metadata: [
                        BluetoothLogMetadata.serviceUUID: "\(uuid)"
                    ])
                }
            }
            merged.serviceData = combined
        }

        return merged
    }

    private func makeAdvertisementPath() -> String {
        // Use a fixed path so we can clean up stale advertisements from crashed processes
        // The path is tied to the adapter to support multiple adapters
        let adapterSuffix = adapterPath.replacingOccurrences(of: "/", with: "_")
        return "/org/wendylabsinc/bluetooth/advertisement\(adapterSuffix)"
    }

    private func ensureAdapterPowered(_ connection: DBusClient.Connection) async throws {
        // First check if adapter is already powered
        let getRequest = DBusRequest.createMethodCall(
            destination: client.busName,
            path: adapterPath,
            interface: "org.freedesktop.DBus.Properties",
            method: "Get",
            body: [
                .string("org.bluez.Adapter1"),
                .string("Powered")
            ]
        )

        if let reply = try await connection.send(getRequest),
           reply.messageType == .methodReturn,
           let body = reply.body.first,
           case .variant(let variant) = body,
           case .boolean(let powered) = variant.value,
           powered {
            logger.debug("Adapter is already powered on")
            return
        }

        // Power on the adapter
        logger.info("Powering on Bluetooth adapter")
        let setRequest = DBusRequest.createMethodCall(
            destination: client.busName,
            path: adapterPath,
            interface: "org.freedesktop.DBus.Properties",
            method: "Set",
            body: [
                .string("org.bluez.Adapter1"),
                .string("Powered"),
                .variant(DBusVariant(.boolean(true)))
            ]
        )

        if let reply = try await connection.send(setRequest),
           reply.messageType == .error {
            let name = client.dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
            logger.error("Failed to power on adapter", metadata: [
                BluetoothLogMetadata.error: "\(name)"
            ])
            throw BluetoothError.invalidState("Failed to power on Bluetooth adapter: \(name)")
        }

        // Wait a moment for the adapter to power up
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms
        logger.debug("Adapter powered on successfully")
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
    }
}

#endif
