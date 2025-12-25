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

actor _BlueZPeripheralConnectionBackend: _PeripheralConnectionBackend {
    private let bluezBusName = "org.bluez"
    private let devicePath: String
    private let verbose: Bool

    private var stateValue: PeripheralConnectionState = .connecting
    private var mtuValue: Int = 23
    private var rssiValue: Int?

    private var stateContinuations: [UUID: AsyncStream<PeripheralConnectionState>.Continuation] = [:]
    private var mtuContinuations: [UUID: AsyncStream<Int>.Continuation] = [:]

    private var connection: DBusClient.Connection?
    private var task: Task<Void, Never>?
    private var stopRequested = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var connectContinuation: CheckedContinuation<Void, Error>?

    init(peripheral: Peripheral, options: ConnectionOptions) throws {
        guard let address = Self.extractAddress(from: peripheral) else {
            throw BluetoothError.invalidState("BlueZ requires a peripheral address on Linux")
        }
        if options.requiresBonding {
            throw BluetoothError.notSupported("BlueZ bonding support is not implemented")
        }

        self.devicePath = "/org/bluez/hci0/dev_" + address.uppercased().replacingOccurrences(of: ":", with: "_")
        self.verbose = ProcessInfo.processInfo.environment["BLUETOOTH_BLUEZ_VERBOSE"] == "1"
    }

    var state: PeripheralConnectionState { stateValue }

    func stateUpdates() -> AsyncStream<PeripheralConnectionState> {
        AsyncStream { continuation in
            let id = UUID()
            stateContinuations[id] = continuation
            continuation.yield(stateValue)
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeStateContinuation(id) }
            }
        }
    }

    var mtu: Int { mtuValue }

    func mtuUpdates() -> AsyncStream<Int> {
        AsyncStream { continuation in
            let id = UUID()
            mtuContinuations[id] = continuation
            continuation.yield(mtuValue)
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeMtuContinuation(id) }
            }
        }
    }

    func connect() async throws {
        if task != nil {
            throw BluetoothError.invalidState("BlueZ connection already started")
        }

        updateState(.connecting)

        try await withCheckedThrowingContinuation { continuation in
            connectContinuation = continuation
            task = Task { [weak self] in
                await self?.runConnection()
            }
        }
    }

    func disconnect() async {
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

    func discoverServices(_ uuids: [BluetoothUUID]?) async throws -> [GATTService] {
        _ = uuids
        throw BluetoothError.unimplemented("BlueZ GATT service discovery backend")
    }

    func discoverCharacteristics(
        _ uuids: [BluetoothUUID]?,
        for service: GATTService
    ) async throws -> [GATTCharacteristic] {
        _ = uuids
        _ = service
        throw BluetoothError.unimplemented("BlueZ GATT characteristic discovery backend")
    }

    func readValue(for characteristic: GATTCharacteristic) async throws -> Data {
        _ = characteristic
        throw BluetoothError.unimplemented("BlueZ GATT readValue backend")
    }

    func writeValue(
        _ value: Data,
        for characteristic: GATTCharacteristic,
        type: GATTWriteType
    ) async throws {
        _ = value
        _ = characteristic
        _ = type
        throw BluetoothError.unimplemented("BlueZ GATT writeValue backend")
    }

    func notifications(
        for characteristic: GATTCharacteristic
    ) async throws -> AsyncThrowingStream<GATTNotification, Error> {
        _ = characteristic
        throw BluetoothError.unimplemented("BlueZ GATT notifications backend")
    }

    func setNotificationsEnabled(
        _ enabled: Bool,
        for characteristic: GATTCharacteristic,
        type: GATTClientSubscriptionType
    ) async throws {
        _ = enabled
        _ = characteristic
        _ = type
        throw BluetoothError.unimplemented("BlueZ GATT setNotificationsEnabled backend")
    }

    func discoverDescriptors(for characteristic: GATTCharacteristic) async throws -> [GATTDescriptor] {
        _ = characteristic
        throw BluetoothError.unimplemented("BlueZ GATT descriptor discovery backend")
    }

    func readValue(for descriptor: GATTDescriptor) async throws -> Data {
        _ = descriptor
        throw BluetoothError.unimplemented("BlueZ GATT read descriptor backend")
    }

    func writeValue(_ value: Data, for descriptor: GATTDescriptor) async throws {
        _ = value
        _ = descriptor
        throw BluetoothError.unimplemented("BlueZ GATT write descriptor backend")
    }

    func readRSSI() async throws -> Int {
        guard let connection else {
            throw BluetoothError.invalidState("BlueZ connection not ready")
        }

        let request = DBusRequest.createMethodCall(
            destination: bluezBusName,
            path: devicePath,
            interface: "org.freedesktop.DBus.Properties",
            method: "Get",
            body: [
                .string("org.bluez.Device1"),
                .string("RSSI")
            ]
        )

        guard let reply = try await connection.send(request), reply.messageType == .methodReturn else {
            throw BluetoothError.invalidState("BlueZ RSSI read failed")
        }

        guard let body = reply.body.first else {
            throw BluetoothError.invalidState("BlueZ RSSI read returned no data")
        }

        let value = unwrapVariant(body)
        guard let rssi = parseInt(value) else {
            throw BluetoothError.invalidState("BlueZ RSSI read returned unsupported type")
        }

        rssiValue = rssi
        return rssi
    }

    func openL2CAPChannel(
        psm: L2CAPPSM,
        parameters: L2CAPChannelParameters
    ) async throws -> any L2CAPChannel {
        _ = psm
        _ = parameters
        throw BluetoothError.unimplemented("BlueZ L2CAP client backend")
    }

    private func runConnection() async {
        do {
            let address = try SocketAddress(unixDomainSocketPath: "/var/run/dbus/system_bus_socket")
            let auth = AuthType.external(userID: String(getuid()))

            try await DBusClient.withConnection(to: address, auth: auth) { connection in
                await self.setConnection(connection)
                await connection.setMessageHandler { [weak self] message in
                    await self?.handleMessage(message)
                }

                try await self.addMatchRules(connection)
                try await self.loadDeviceProperties(connection)

                if !(await self.isConnected()) {
                    if self.verbose {
                        print("[bluez] Connecting to \(self.devicePath)")
                    }
                    try await self.connectDevice(connection)
                    await self.updateState(.connected)
                    try await self.loadDeviceProperties(connection)
                }

                await self.resumeConnectIfNeeded()
                await self.waitForStop()

                if await self.isConnected() {
                    if self.verbose {
                        print("[bluez] Disconnecting from \(self.devicePath)")
                    }
                    try await self.disconnectDevice(connection)
                    await self.updateState(.disconnected(reason: nil))
                }

                await self.setConnection(nil)
            }
        } catch {
            resumeConnectIfNeeded(error: error)
            updateState(.disconnected(reason: String(describing: error)))
            setConnection(nil)
        }

        cleanup()
    }

    private func addMatchRules(_ connection: DBusClient.Connection) async throws {
        let rule = "type='signal',sender='\(bluezBusName)',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path='\(devicePath)'"
        let request = DBusRequest.createMethodCall(
            destination: "org.freedesktop.DBus",
            path: "/org/freedesktop/DBus",
            interface: "org.freedesktop.DBus",
            method: "AddMatch",
            body: [.string(rule)]
        )
        _ = try await connection.send(request)
    }

    private func connectDevice(_ connection: DBusClient.Connection) async throws {
        let request = DBusRequest.createMethodCall(
            destination: bluezBusName,
            path: devicePath,
            interface: "org.bluez.Device1",
            method: "Connect"
        )
        guard let reply = try await connection.send(request) else { return }
        if reply.messageType == .error {
            let name = dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
            throw BluetoothError.invalidState("D-Bus Connect failed: \(name)")
        }
    }

    private func disconnectDevice(_ connection: DBusClient.Connection) async throws {
        let request = DBusRequest.createMethodCall(
            destination: bluezBusName,
            path: devicePath,
            interface: "org.bluez.Device1",
            method: "Disconnect"
        )
        guard let reply = try await connection.send(request) else { return }
        if reply.messageType == .error {
            let name = dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
            if name == "org.bluez.Error.NotConnected" {
                return
            }
            throw BluetoothError.invalidState("D-Bus Disconnect failed: \(name)")
        }
    }

    private func loadDeviceProperties(_ connection: DBusClient.Connection) async throws {
        let request = DBusRequest.createMethodCall(
            destination: bluezBusName,
            path: devicePath,
            interface: "org.freedesktop.DBus.Properties",
            method: "GetAll",
            body: [.string("org.bluez.Device1")]
        )
        guard let reply = try await connection.send(request), reply.messageType == .methodReturn else {
            return
        }
        guard let body = reply.body.first, case .dictionary(let props) = body else {
            return
        }
        handleProperties(props)
    }

    private func handleMessage(_ message: DBusMessage) async {
        guard message.messageType == .signal else { return }
        guard message.interface == "org.freedesktop.DBus.Properties" else { return }
        guard message.member == "PropertiesChanged" else { return }
        guard message.path == devicePath else { return }
        guard message.body.count >= 2 else { return }
        guard case .string(let iface) = message.body[0], iface == "org.bluez.Device1" else { return }
        guard case .dictionary(let props) = message.body[1] else { return }

        handleProperties(props)
    }

    private func handleProperties(_ props: [DBusValue: DBusValue]) {
        for (keyValue, rawValue) in props {
            guard case .string(let key) = keyValue else { continue }
            let value = unwrapVariant(rawValue)

            switch key {
            case "Connected":
                if let connected = value.boolean {
                    updateState(connected ? .connected : .disconnected(reason: nil))
                    if !connected {
                        requestStop()
                    }
                }
            case "MTU":
                if let mtu = parseInt(value) {
                    updateMtu(mtu)
                }
            case "RSSI":
                if let rssi = parseInt(value) {
                    rssiValue = rssi
                }
            default:
                break
            }
        }
    }

    private func updateState(_ newState: PeripheralConnectionState) {
        guard stateValue != newState else { return }
        stateValue = newState
        for continuation in stateContinuations.values {
            continuation.yield(newState)
        }
    }

    private func updateMtu(_ mtu: Int) {
        guard mtuValue != mtu else { return }
        mtuValue = mtu
        for continuation in mtuContinuations.values {
            continuation.yield(mtu)
        }
    }

    private func requestStop() {
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

    private func resumeConnectIfNeeded(error: Error? = nil) {
        guard let continuation = connectContinuation else { return }
        connectContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func isConnected() -> Bool {
        switch stateValue {
        case .connected:
            return true
        case .connecting, .disconnected:
            return false
        }
    }

    private func setConnection(_ connection: DBusClient.Connection?) {
        self.connection = connection
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations[id] = nil
    }

    private func removeMtuContinuation(_ id: UUID) {
        mtuContinuations[id] = nil
    }

    private func cleanup() {
        stopRequested = false
        stopContinuation = nil
        connectContinuation = nil
        task?.cancel()
        task = nil
        connection = nil
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

    private static func extractAddress(from peripheral: Peripheral) -> String? {
        let raw = peripheral.id.rawValue
        guard raw.hasPrefix("addr:") else { return nil }
        return String(raw.dropFirst("addr:".count))
    }
}

#endif
