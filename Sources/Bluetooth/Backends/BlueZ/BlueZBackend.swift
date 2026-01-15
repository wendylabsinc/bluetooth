#if os(Linux)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import DBUS
import NIOCore

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

actor _BlueZCentralBackend: _CentralBackend {
    private let scanController: _BlueZScanController
    private let adapterPath: String

    init(options: BluetoothOptions) {
        let selection = BlueZAdapterSelection(options: options)
        self.adapterPath = selection.path
        self.scanController = _BlueZScanController(adapterPath: selection.path)
    }
    private let agentController = _BlueZAgentControllerShared.shared

    var state: BluetoothState { .unknown }

    func stateUpdates() -> AsyncStream<BluetoothState> {
        AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        }
    }

    func stopScan() async throws {
        await scanController.stopScan()
    }

    func scan(
        filter: ScanFilter?,
        parameters: ScanParameters
    ) async throws -> AsyncThrowingStream<ScanResult, Error> {
        try await scanController.startScan(filter: filter, parameters: parameters)
    }

    func pairingRequests() async throws -> AsyncThrowingStream<PairingRequest, Error> {
        try await agentController.startIfNeeded()
        return try await agentController.pairingRequests()
    }

    func removeBond(for peripheral: Peripheral) async throws {
        guard let address = Self.extractAddress(from: peripheral) else {
            throw BluetoothError.invalidState("BlueZ requires a peripheral address on Linux")
        }
        try await removeDevice(address: address)
    }

    func connect(
        to peripheral: Peripheral,
        options: ConnectionOptions
    ) async throws -> any _PeripheralConnectionBackend {
        let backend = try _BlueZPeripheralConnectionBackend(
            peripheral: peripheral,
            options: options,
            agentController: agentController,
            adapterPath: adapterPath
        )
        try await backend.connect()
        return backend
    }

    private static func extractAddress(from peripheral: Peripheral) -> String? {
        let raw = peripheral.id.rawValue
        guard raw.hasPrefix("addr:") else { return nil }
        return String(raw.dropFirst("addr:".count))
    }

    private func removeDevice(address: String) async throws {
        let devicePath = "\(adapterPath)/dev_" + address.uppercased().replacingOccurrences(of: ":", with: "_")
        let socket = try SocketAddress(unixDomainSocketPath: "/var/run/dbus/system_bus_socket")
        let auth = AuthType.external(userID: String(getuid()))
        let adapterPath = self.adapterPath

        try await DBusClient.withConnection(to: socket, auth: auth) { connection in
            let request = DBusRequest.createMethodCall(
                destination: "org.bluez",
                path: adapterPath,
                interface: "org.bluez.Adapter1",
                method: "RemoveDevice",
                body: [.objectPath(devicePath)]
            )

            guard let reply = try await connection.send(request) else { return }
            if reply.messageType == .error {
                let name = Self.dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
                if name == "org.bluez.Error.DoesNotExist" {
                    return
                }
                throw BluetoothError.invalidState("D-Bus RemoveDevice failed: \(name)")
            }
        }
    }

    private static func dbusErrorName(_ message: DBusMessage) -> String? {
        guard
            let field = message.headerFields.first(where: { $0.code == .errorName }),
            case .string(let name) = field.variant.value
        else {
            return nil
        }
        return name
    }
}

actor _BlueZPeripheralBackend: _PeripheralBackend {
    private let advertisingController: _BlueZAdvertisingController
    private let connectionEventsController: _BlueZPeripheralConnectionEventsController
    private let gattServerController: _BlueZGATTServerController
    private let agentController = _BlueZAgentControllerShared.shared
    private struct L2CAPListenerState {
        var listener: BlueZL2CAP.Listener
        var isAccepting: Bool
    }

    private let adapterPath: String
    private var l2capListeners: [L2CAPPSM: L2CAPListenerState] = [:]

    init(options: BluetoothOptions) {
        let selection = BlueZAdapterSelection(options: options)
        self.adapterPath = selection.path
        self.advertisingController = _BlueZAdvertisingController(adapterPath: selection.path)
        self.connectionEventsController = _BlueZPeripheralConnectionEventsController(adapterPath: selection.path)
        self.gattServerController = _BlueZGATTServerController(adapterPath: selection.path)
    }

    var state: BluetoothState { .unknown }

    func stateUpdates() -> AsyncStream<BluetoothState> {
        AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        }
    }

    func connectionEvents() async throws -> AsyncThrowingStream<PeripheralConnectionEvent, Error> {
        try await connectionEventsController.start()
    }

    func pairingRequests() async throws -> AsyncThrowingStream<PairingRequest, Error> {
        try await agentController.startIfNeeded()
        return try await agentController.pairingRequests()
    }

    func startAdvertising(advertisingData: AdvertisementData, scanResponseData: AdvertisementData?, parameters: AdvertisingParameters) async throws {
        try await agentController.startIfNeeded()
        try await advertisingController.startAdvertising(
            advertisingData: advertisingData,
            scanResponseData: scanResponseData,
            parameters: parameters
        )
    }

    func startAdvertisingSet(_ configuration: AdvertisingSetConfiguration) async throws -> AdvertisingSetID {
        _ = configuration
        throw BluetoothError.unimplemented("BlueZ extended advertising backend")
    }

    func updateAdvertisingSet(_ id: AdvertisingSetID, configuration: AdvertisingSetConfiguration) async throws {
        _ = id
        _ = configuration
        throw BluetoothError.unimplemented("BlueZ extended advertising update backend")
    }

    func stopAdvertising() async {
        await advertisingController.stopAdvertising()
    }

    func stopAdvertisingSet(_ id: AdvertisingSetID) async {
        _ = id
    }

    func disconnect(_ central: Central) async throws {
        guard let address = Self.extractAddress(from: central) else {
            throw BluetoothError.invalidState("BlueZ requires a central address on Linux")
        }

        let devicePath = "\(adapterPath)/dev_" + address.uppercased().replacingOccurrences(of: ":", with: "_")
        let socket = try SocketAddress(unixDomainSocketPath: "/var/run/dbus/system_bus_socket")
        let auth = AuthType.external(userID: String(getuid()))

        try await DBusClient.withConnection(to: socket, auth: auth) { connection in
            let request = DBusRequest.createMethodCall(
                destination: "org.bluez",
                path: devicePath,
                interface: "org.bluez.Device1",
                method: "Disconnect"
            )

            guard let reply = try await connection.send(request) else { return }
            if reply.messageType == .error {
                let name = Self.dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
                if name == "org.bluez.Error.DoesNotExist" {
                    return
                }
                throw BluetoothError.invalidState("D-Bus Disconnect failed: \(name)")
            }
        }
    }

    func removeBond(for central: Central) async throws {
        guard let address = Self.extractAddress(from: central) else {
            throw BluetoothError.invalidState("BlueZ requires a central address on Linux")
        }

        let devicePath = "\(adapterPath)/dev_" + address.uppercased().replacingOccurrences(of: ":", with: "_")
        let socket = try SocketAddress(unixDomainSocketPath: "/var/run/dbus/system_bus_socket")
        let auth = AuthType.external(userID: String(getuid()))
        let adapterPath = self.adapterPath

        try await DBusClient.withConnection(to: socket, auth: auth) { connection in
            let request = DBusRequest.createMethodCall(
                destination: "org.bluez",
                path: adapterPath,
                interface: "org.bluez.Adapter1",
                method: "RemoveDevice",
                body: [.objectPath(devicePath)]
            )

            guard let reply = try await connection.send(request) else { return }
            if reply.messageType == .error {
                let name = Self.dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
                if name == "org.bluez.Error.DoesNotExist" {
                    return
                }
                throw BluetoothError.invalidState("D-Bus RemoveDevice failed: \(name)")
            }
        }
    }

    func addService(_ service: GATTServiceDefinition) async throws -> GATTServiceRegistration {
        try await agentController.startIfNeeded()
        return try await gattServerController.addService(service)
    }

    func removeService(_ registration: GATTServiceRegistration) async throws {
        try await gattServerController.removeService(registration)
    }

    func gattRequests() async throws -> AsyncThrowingStream<GATTServerRequest, Error> {
        try await agentController.startIfNeeded()
        return try await gattServerController.requests()
    }

    func updateValue(_ value: Data, for characteristic: GATTCharacteristic, type: GATTServerUpdateType) async throws {
        try await gattServerController.updateValue(value, for: characteristic, type: type)
    }

    func publishL2CAPChannel(parameters: L2CAPChannelParameters) async throws -> L2CAPPSM {
        let listener = try BlueZL2CAP.createListener(parameters: parameters)
        l2capListeners[listener.psm] = L2CAPListenerState(listener: listener, isAccepting: false)
        return listener.psm
    }

    func incomingL2CAPChannels(psm: L2CAPPSM) async throws -> AsyncThrowingStream<any L2CAPChannel, Error> {
        guard var state = l2capListeners[psm] else {
            throw BluetoothError.invalidState("No L2CAP listener published for PSM 0x\(String(psm.rawValue, radix: 16))")
        }
        if state.isAccepting {
            throw BluetoothError.invalidState("L2CAP incoming stream already active for PSM 0x\(String(psm.rawValue, radix: 16))")
        }

        state.isAccepting = true
        l2capListeners[psm] = state

        let listener = state.listener
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { await self?.stopL2CAPListener(psm: psm) }
            }
            Task.detached {
                BlueZL2CAP.acceptLoop(listener: listener, continuation: continuation)
            }
        }
    }

    private func stopL2CAPListener(psm: L2CAPPSM) {
        guard let state = l2capListeners.removeValue(forKey: psm) else { return }
        BlueZL2CAP.closeListener(state.listener)
    }

    private static func extractAddress(from central: Central) -> String? {
        let raw = central.id.rawValue
        guard raw.hasPrefix("addr:") else { return nil }
        return String(raw.dropFirst("addr:".count))
    }

    private static func dbusErrorName(_ message: DBusMessage) -> String? {
        guard
            let field = message.headerFields.first(where: { $0.code == .errorName }),
            case .string(let name) = field.variant.value
        else {
            return nil
        }
        return name
    }
}

#endif
