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

actor _BlueZScanController {
    private let adapterPath: String
    private let bluezBusName = "org.bluez"
    private let objectManagerPath = "/"

    private var isScanning = false
    private var allowDuplicates = false
    private var scanFilter: ScanFilter?
    private var continuation: AsyncThrowingStream<ScanResult, Error>.Continuation?
    private var devices: [String: DeviceState] = [:]
    private var emitted: Set<String> = []
    private var devicePathMap: [String: String] = [:]
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var stopRequested = false
    private var scanTask: Task<Void, Never>?

    init(adapterPath: String) {
        self.adapterPath = adapterPath
    }

    func startScan(
        filter: ScanFilter?,
        parameters: ScanParameters
    ) async throws -> AsyncThrowingStream<ScanResult, Error> {
        if isScanning {
            throw BluetoothError.invalidState("BlueZ scan already in progress")
        }

        isScanning = true
        allowDuplicates = parameters.allowDuplicates
        scanFilter = filter
        devices.removeAll()
        emitted.removeAll()
        devicePathMap.removeAll()

        scanTask = Task {
            await runDbusScan(parameters: parameters)
        }

        return AsyncThrowingStream { continuation in
            self.attach(continuation)
        }
    }

    func stopScan() {
        guard isScanning else { return }
        stopRequested = true
        if let continuation = stopContinuation {
            stopContinuation = nil
            continuation.resume()
        }
    }

    func emit(_ result: ScanResult) {
        continuation?.yield(result)
    }

    func finish(error: Error? = nil) {
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }

        cleanup()
    }

    private func attach(_ continuation: AsyncThrowingStream<ScanResult, Error>.Continuation) {
        self.continuation = continuation
        continuation.onTermination = { @Sendable _ in
            Task {
                await self.cleanup()
            }
        }
    }

    private func cleanup() {
        isScanning = false
        allowDuplicates = false
        scanFilter = nil
        continuation = nil
        devices.removeAll()
        emitted.removeAll()
        devicePathMap.removeAll()
        stopContinuation = nil
        stopRequested = false
        scanTask?.cancel()
        scanTask = nil
    }

    private func runDbusScan(parameters: ScanParameters) async {
        do {
            let address = try SocketAddress(unixDomainSocketPath: "/var/run/dbus/system_bus_socket")
            let auth = AuthType.external(userID: String(getuid()))

            try await DBusClient.withConnection(to: address, auth: auth) { connection in
                await connection.setMessageHandler { [weak self] message in
                    await self?.handleDbusMessage(message)
                }

                try await self.addMatchRules(connection)
                try await self.setDiscoveryFilter(connection, parameters: parameters)
                try await self.startDiscovery(connection)
                try await self.loadManagedObjects(connection)
                await self.waitForStop()
                try await self.stopDiscovery(connection)
            }

            finish()
        } catch {
            finish(error: error)
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

    private func addMatchRules(_ connection: DBusClient.Connection) async throws {
        let rules = [
            "type='signal',sender='\(bluezBusName)',interface='org.freedesktop.DBus.ObjectManager',member='InterfacesAdded'",
            "type='signal',sender='\(bluezBusName)',interface='org.freedesktop.DBus.ObjectManager',member='InterfacesRemoved'",
            "type='signal',sender='\(bluezBusName)',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'",
        ]

        for rule in rules {
            let request = DBusRequest.createMethodCall(
                destination: "org.freedesktop.DBus",
                path: "/org/freedesktop/DBus",
                interface: "org.freedesktop.DBus",
                method: "AddMatch",
                body: [.string(rule)]
            )
            _ = try await send(connection, request: request, action: "AddMatch")
        }
    }

    private func setDiscoveryFilter(
        _ connection: DBusClient.Connection,
        parameters: ScanParameters
    ) async throws {
        var filterDict: [DBusValue: DBusValue] = [:]
        filterDict[.string("Transport")] = .variant(DBusVariant(.string("le")))
        filterDict[.string("DuplicateData")] = .variant(DBusVariant(.boolean(parameters.allowDuplicates)))

        if let filter = scanFilter, !filter.serviceUUIDs.isEmpty {
            let uuids = filter.serviceUUIDs.map { $0.description }
            let array = DBusValue.array(uuids.map { .string($0) })
            filterDict[.string("UUIDs")] = .variant(DBusVariant(array))
        }

        let request = DBusRequest.createMethodCall(
            destination: bluezBusName,
            path: adapterPath,
            interface: "org.bluez.Adapter1",
            method: "SetDiscoveryFilter",
            body: [.dictionary(filterDict)]
        )
        _ = try await send(connection, request: request, action: "SetDiscoveryFilter")
    }

    private func startDiscovery(_ connection: DBusClient.Connection) async throws {
        let request = DBusRequest.createMethodCall(
            destination: bluezBusName,
            path: adapterPath,
            interface: "org.bluez.Adapter1",
            method: "StartDiscovery"
        )
        _ = try await send(connection, request: request, action: "StartDiscovery")
    }

    private func stopDiscovery(_ connection: DBusClient.Connection) async throws {
        let request = DBusRequest.createMethodCall(
            destination: bluezBusName,
            path: adapterPath,
            interface: "org.bluez.Adapter1",
            method: "StopDiscovery"
        )
        _ = try await send(connection, request: request, action: "StopDiscovery")
    }

    private func loadManagedObjects(_ connection: DBusClient.Connection) async throws {
        let request = DBusRequest.createMethodCall(
            destination: bluezBusName,
            path: objectManagerPath,
            interface: "org.freedesktop.DBus.ObjectManager",
            method: "GetManagedObjects"
        )
        guard let reply = try await send(connection, request: request, action: "GetManagedObjects"),
              reply.messageType == .methodReturn,
              let body = reply.body.first,
              case .dictionary(let objects) = body
        else {
            return
        }

        for (pathValue, interfacesValue) in objects {
            guard case .objectPath(let path) = pathValue else { continue }
            guard isAdapterDevicePath(path) else { continue }
            guard case .dictionary(let interfaces) = interfacesValue else { continue }
            if let props = properties(for: "org.bluez.Device1", in: interfaces) {
                updateDevice(path: path, properties: props)
            }
        }
    }

    private func handleDbusMessage(_ message: DBusMessage) async {
        guard message.messageType == .signal else { return }
        guard let interface = message.interface, let member = message.member else { return }

        switch (interface, member) {
        case ("org.freedesktop.DBus.ObjectManager", "InterfacesAdded"):
            guard message.body.count >= 2 else { return }
            guard case .objectPath(let path) = message.body[0] else { return }
            guard isAdapterDevicePath(path) else { return }
            guard case .dictionary(let interfaces) = message.body[1] else { return }
            if let props = properties(for: "org.bluez.Device1", in: interfaces) {
                updateDevice(path: path, properties: props)
            }
        case ("org.freedesktop.DBus.ObjectManager", "InterfacesRemoved"):
            guard message.body.count >= 2 else { return }
            guard case .objectPath(let path) = message.body[0] else { return }
            guard isAdapterDevicePath(path) else { return }
            guard case .array(let values) = message.body[1] else { return }
            if values.contains(where: { value in
                if case .string(let name) = value {
                    return name == "org.bluez.Device1"
                }
                return false
            }) {
                removeDevice(path: path)
            }
        case ("org.freedesktop.DBus.Properties", "PropertiesChanged"):
            guard message.body.count >= 2 else { return }
            guard case .string(let iface) = message.body[0], iface == "org.bluez.Device1" else { return }
            guard case .dictionary(let props) = message.body[1] else { return }
            guard let path = message.path else { return }
            guard isAdapterDevicePath(path) else { return }
            updateDevice(path: path, properties: props)
        default:
            return
        }
    }

    private func properties(
        for interfaceName: String,
        in interfaces: [DBusValue: DBusValue]
    ) -> [DBusValue: DBusValue]? {
        for (key, value) in interfaces {
            guard case .string(let name) = key, name == interfaceName else { continue }
            guard case .dictionary(let props) = value else { continue }
            return props
        }
        return nil
    }

    private func updateDevice(path: String, properties: [DBusValue: DBusValue]) {
        guard isAdapterDevicePath(path) else { return }
        var address = devicePathMap[path] ?? addressFromPath(path)
        var state: DeviceState? = nil

        for (keyValue, rawValue) in properties {
            guard case .string(let key) = keyValue else { continue }
            let value = unwrapVariant(rawValue)

            switch key {
            case "Address":
                if case .string(let addr) = value {
                    address = addr
                    devicePathMap[path] = addr
                }
            case "Name":
                if case .string(let name) = value {
                    state = ensureState(address: address)
                    updateName(&state, name: name)
                }
            case "Alias":
                if case .string(let name) = value {
                    state = ensureState(address: address)
                    updateName(&state, name: name)
                }
            case "RSSI":
                if let rssi = parseInt(value) {
                    state = ensureState(address: address)
                    state?.rssi = rssi
                }
            case "TxPower":
                if let tx = parseInt(value) {
                    state = ensureState(address: address)
                    state?.advertisementData.txPowerLevel = tx
                }
            case "UUIDs":
                if case .array(let values) = value {
                    let uuids = values.compactMap { entry -> BluetoothUUID? in
                        guard case .string(let uuid) = entry else { return nil }
                        return parseBluetoothUUID(uuid)
                    }
                    state = ensureState(address: address)
                    state?.advertisementData.serviceUUIDs = uuids
                }
            case "ManufacturerData":
                if case .dictionary(let values) = value {
                    if let manufacturer = parseManufacturerData(values) {
                        state = ensureState(address: address)
                        state?.advertisementData.manufacturerData = manufacturer
                    }
                }
            case "ServiceData":
                if case .dictionary(let values) = value {
                    let data = parseServiceData(values)
                    state = ensureState(address: address)
                    state?.advertisementData.serviceData = data
                }
            default:
                break
            }
        }

        if let updated = state, let address {
            devices[address] = updated
        } else if let address {
            _ = ensureState(address: address)
        }

        if let address {
            emitIfNeeded(address: address)
        }
    }

    private func removeDevice(path: String) {
        guard isAdapterDevicePath(path) else { return }
        guard let address = devicePathMap[path] else { return }
        devices[address] = nil
        emitted.remove(address)
        devicePathMap[path] = nil
    }

    private func isAdapterDevicePath(_ path: String) -> Bool {
        path.hasPrefix("\(adapterPath)/dev_")
    }

    private func ensureState(address: String?) -> DeviceState? {
        guard let address else { return nil }
        if let state = devices[address] {
            return state
        }
        let peripheral = Peripheral(id: .address(BluetoothAddress(address)))
        let state = DeviceState(peripheral: peripheral, advertisementData: AdvertisementData(), rssi: nil)
        devices[address] = state
        return state
    }

    private func updateName(_ state: inout DeviceState?, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let lower = trimmed.lowercased()
        if lower == "n/a" || lower == "unknown" || lower == "na" {
            return
        }

        if var stateValue = state {
            stateValue.peripheral.name = trimmed
            stateValue.advertisementData.localName = trimmed
            state = stateValue
        }
    }

    private func parseManufacturerData(_ dict: [DBusValue: DBusValue]) -> ManufacturerData? {
        for (key, value) in dict {
            guard case .uint16(let company) = key else { continue }
            let payload = unwrapVariant(value)
            if let data = dataFromValue(payload) {
                return ManufacturerData(companyIdentifier: company, data: data)
            }
        }
        return nil
    }

    private func parseServiceData(_ dict: [DBusValue: DBusValue]) -> [BluetoothUUID: Data] {
        var result: [BluetoothUUID: Data] = [:]
        for (key, value) in dict {
            guard case .string(let uuidString) = key else { continue }
            guard let uuid = parseBluetoothUUID(uuidString) else { continue }
            let payload = unwrapVariant(value)
            if let data = dataFromValue(payload) {
                result[uuid] = data
            }
        }
        return result
    }

    private func emitIfNeeded(address: String) {
        guard let state = devices[address], matchesFilter(state) else { return }
        if allowDuplicates || !emitted.contains(address) {
            let rssi = state.rssi ?? 0
            emit(ScanResult(peripheral: state.peripheral, advertisementData: state.advertisementData, rssi: rssi))
            emitted.insert(address)
        }
    }

    private func matchesFilter(_ state: DeviceState) -> Bool {
        guard let filter = scanFilter else { return true }

        if let prefix = filter.namePrefix {
            let name = state.peripheral.name ?? state.advertisementData.localName
            guard let name, name.lowercased().hasPrefix(prefix.lowercased()) else {
                return false
            }
        }

        if !filter.serviceUUIDs.isEmpty {
            let advertised = Set(state.advertisementData.serviceUUIDs)
            if advertised.intersection(filter.serviceUUIDs).isEmpty {
                return false
            }
        }

        return true
    }

    private func send(
        _ connection: DBusClient.Connection,
        request: DBusRequest,
        action: String
    ) async throws -> DBusMessage? {
        let reply = try await connection.send(request)
        guard let reply else { return nil }
        if reply.messageType == .error {
            let name = dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
            throw BluetoothError.invalidState("D-Bus \(action) failed: \(name)")
        }
        return reply
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


    private func parseInt(_ value: DBusValue) -> Int? {
        switch value {
        case .int16(let v): return Int(v)
        case .int32(let v): return Int(v)
        case .int64(let v): return Int(v)
        case .uint16(let v): return Int(v)
        case .uint32(let v): return Int(v)
        case .uint64(let v): return Int(v)
        default:
            return nil
        }
    }

    private func unwrapVariant(_ value: DBusValue) -> DBusValue {
        if case .variant(let variant) = value {
            return variant.value
        }
        return value
    }

    private func dataFromValue(_ value: DBusValue) -> Data? {
        guard case .array(let values) = value else { return nil }
        var bytes: [UInt8] = []
        for entry in values {
            if case .byte(let byte) = entry {
                bytes.append(byte)
            } else {
                return nil
            }
        }
        return Data(bytes)
    }

    private func parseBluetoothUUID(_ value: String) -> BluetoothUUID? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let noPrefix = trimmed.hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
        if noPrefix.contains("-"), let uuid = UUID(uuidString: noPrefix) {
            return .bit128(uuid)
        }
        if noPrefix.count <= 4, let short = UInt16(noPrefix, radix: 16) {
            return .bit16(short)
        }
        if noPrefix.count <= 8, let mid = UInt32(noPrefix, radix: 16) {
            return .bit32(mid)
        }
        return nil
    }

    private func addressFromPath(_ path: String) -> String? {
        guard let range = path.range(of: "/dev_") else { return nil }
        let suffix = path[range.upperBound...]
        let address = suffix.replacingOccurrences(of: "_", with: ":")
        return address
    }

    private struct DeviceState {
        var peripheral: Peripheral
        var advertisementData: AdvertisementData
        var rssi: Int?
    }
}

#endif
