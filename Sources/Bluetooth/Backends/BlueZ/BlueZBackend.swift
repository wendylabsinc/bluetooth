#if os(Linux)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

actor _BlueZCentralBackend: _CentralBackend {
    private let scanController = _BlueZScanController()

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

    func connect(
        to peripheral: Peripheral,
        options: ConnectionOptions
    ) async throws -> any _PeripheralConnectionBackend {
        let backend = try _BlueZPeripheralConnectionBackend(peripheral: peripheral, options: options)
        try await backend.connect()
        return backend
    }
}

actor _BlueZPeripheralBackend: _PeripheralBackend {
    private let advertisingController = _BlueZAdvertisingController()

    var state: BluetoothState { .unknown }

    func stateUpdates() -> AsyncStream<BluetoothState> {
        AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        }
    }

    func connectionEvents() async throws -> AsyncThrowingStream<PeripheralConnectionEvent, Error> {
        throw BluetoothError.unimplemented("BlueZ peripheral connection events backend")
    }

    func startAdvertising(advertisingData: AdvertisementData, scanResponseData: AdvertisementData?, parameters: AdvertisingParameters) async throws {
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
        _ = central
        throw BluetoothError.unimplemented("BlueZ peripheral disconnect backend")
    }

    func addService(_ service: GATTServiceDefinition) async throws -> GATTServiceRegistration {
        _ = service
        throw BluetoothError.unimplemented("BlueZ GATT server backend")
    }

    func gattRequests() async throws -> AsyncThrowingStream<GATTServerRequest, Error> {
        throw BluetoothError.unimplemented("BlueZ GATT request backend")
    }

    func updateValue(_ value: Data, for characteristic: GATTCharacteristic, type: GATTServerUpdateType) async throws {
        _ = value
        _ = characteristic
        _ = type
        throw BluetoothError.unimplemented("BlueZ GATT updateValue backend")
    }

    func publishL2CAPChannel(parameters: L2CAPChannelParameters) async throws -> L2CAPPSM {
        _ = parameters
        throw BluetoothError.unimplemented("BlueZ L2CAP server backend")
    }

    func incomingL2CAPChannels(psm: L2CAPPSM) async throws -> AsyncThrowingStream<any L2CAPChannel, Error> {
        _ = psm
        throw BluetoothError.unimplemented("BlueZ L2CAP incoming backend")
    }
}

#endif
