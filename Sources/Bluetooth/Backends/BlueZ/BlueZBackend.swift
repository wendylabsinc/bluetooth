#if os(Linux)
#if canImport(FoundationEssentials)
import FoundationEssentials
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

struct _BlueZCentralBackend: _CentralBackend {
    let client: BlueZClient
    let scanController: _BlueZScanController
    let adapterPath: String
    let agentController: _BlueZPeripheralAgentController

    private var logger: Logger {
        var logger = BluetoothLogger.backend
        logger[metadataKey: BluetoothLogMetadata.adapterPath] = "\(adapterPath)"
        return logger
    }

    init(options: BluetoothOptions) {
        let selection = BlueZAdapterSelection(options: options)
        let client = BlueZClient()
        self.client = client
        self.adapterPath = selection.path
        self.scanController = _BlueZScanController(client: client, adapterPath: selection.path)
        self.agentController = _BlueZPeripheralAgentController(client: client)

        BluetoothLogger.backend.info("BlueZ central backend initialized", metadata: [
            BluetoothLogMetadata.adapterPath: "\(selection.path)"
        ])
    }

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
            client: client,
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

        let request = DBusRequest.createMethodCall(
            destination: client.busName,
            path: adapterPath,
            interface: "org.bluez.Adapter1",
            method: "RemoveDevice",
            body: [.objectPath(devicePath)]
        )

        guard let reply = try await client.send(request) else { return }
        if reply.messageType == .error {
            let name = client.dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
            if name == "org.bluez.Error.DoesNotExist" {
                return
            }
            throw BluetoothError.invalidState("D-Bus RemoveDevice failed: \(name)")
        }
    }
}

private actor _BlueZL2CAPListenerManager {
    private struct ListenerState {
        var listener: BlueZL2CAP.Listener
        var isAccepting: Bool
    }

    private var listeners: [L2CAPPSM: ListenerState] = [:]

    func publish(parameters: L2CAPChannelParameters) throws -> L2CAPPSM {
        let listener = try BlueZL2CAP.createListener(parameters: parameters)
        listeners[listener.psm] = ListenerState(listener: listener, isAccepting: false)
        return listener.psm
    }

    func startAccepting(psm: L2CAPPSM) throws -> BlueZL2CAP.Listener {
        guard var state = listeners[psm] else {
            throw BluetoothError.invalidState("No L2CAP listener published for PSM 0x\(String(psm.rawValue, radix: 16))")
        }
        if state.isAccepting {
            throw BluetoothError.invalidState("L2CAP incoming stream already active for PSM 0x\(String(psm.rawValue, radix: 16))")
        }
        state.isAccepting = true
        listeners[psm] = state
        return state.listener
    }

    func stop(psm: L2CAPPSM) {
        guard let state = listeners.removeValue(forKey: psm) else { return }
        BlueZL2CAP.closeListener(state.listener)
    }
}

struct _BlueZPeripheralBackend: _PeripheralBackend {
    let client: BlueZClient
    let advertisingController: _BlueZAdvertisingController
    let connectionEventsController: _BlueZPeripheralConnectionEventsController
    let gattServerController: _BlueZGATTServerController
    let agentController: _BlueZPeripheralAgentController
    let adapterPath: String
    private let l2capManager = _BlueZL2CAPListenerManager()

    private var logger: Logger {
        var logger = BluetoothLogger.backend
        logger[metadataKey: BluetoothLogMetadata.adapterPath] = "\(adapterPath)"
        return logger
    }

    init(options: BluetoothOptions) {
        let selection = BlueZAdapterSelection(options: options)
        let client = BlueZClient()
        self.client = client
        self.adapterPath = selection.path
        self.advertisingController = _BlueZAdvertisingController(client: client, adapterPath: selection.path)
        self.connectionEventsController = _BlueZPeripheralConnectionEventsController(client: client, adapterPath: selection.path)
        self.gattServerController = _BlueZGATTServerController(client: client, adapterPath: selection.path)
        self.agentController = _BlueZPeripheralAgentController(client: client)

        BluetoothLogger.backend.info("BlueZ peripheral backend initialized", metadata: [
            BluetoothLogMetadata.adapterPath: "\(selection.path)"
        ])
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

        let request = DBusRequest.createMethodCall(
            destination: client.busName,
            path: devicePath,
            interface: "org.bluez.Device1",
            method: "Disconnect"
        )

        guard let reply = try await client.send(request) else { return }
        if reply.messageType == .error {
            let name = client.dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
            if name == "org.bluez.Error.DoesNotExist" {
                return
            }
            throw BluetoothError.invalidState("D-Bus Disconnect failed: \(name)")
        }
    }

    func removeBond(for central: Central) async throws {
        guard let address = Self.extractAddress(from: central) else {
            throw BluetoothError.invalidState("BlueZ requires a central address on Linux")
        }

        let devicePath = "\(adapterPath)/dev_" + address.uppercased().replacingOccurrences(of: ":", with: "_")

        let request = DBusRequest.createMethodCall(
            destination: client.busName,
            path: adapterPath,
            interface: "org.bluez.Adapter1",
            method: "RemoveDevice",
            body: [.objectPath(devicePath)]
        )

        guard let reply = try await client.send(request) else { return }
        if reply.messageType == .error {
            let name = client.dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
            if name == "org.bluez.Error.DoesNotExist" {
                return
            }
            throw BluetoothError.invalidState("D-Bus RemoveDevice failed: \(name)")
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
        try await l2capManager.publish(parameters: parameters)
    }

    func incomingL2CAPChannels(psm: L2CAPPSM) async throws -> AsyncThrowingStream<any L2CAPChannel, Error> {
        let listener = try await l2capManager.startAccepting(psm: psm)
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in
                Task { await l2capManager.stop(psm: psm) }
            }
            Task.detached {
                BlueZL2CAP.acceptLoop(listener: listener, continuation: continuation)
            }
        }
    }

    private static func extractAddress(from central: Central) -> String? {
        let raw = central.id.rawValue
        guard raw.hasPrefix("addr:") else { return nil }
        return String(raw.dropFirst("addr:".count))
    }
}

#endif
