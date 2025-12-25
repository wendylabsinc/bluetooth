#if os(Windows)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

actor _WindowsCentralBackend: _CentralBackend {
    var state: BluetoothState { .unknown }

    func stateUpdates() -> AsyncStream<BluetoothState> {
        AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        }
    }

    func stopScan() async {
    }

    func scan(
        filter: ScanFilter?,
        parameters: ScanParameters
    ) async throws -> AsyncThrowingStream<ScanResult, Error> {
        _ = filter
        _ = parameters
        throw BluetoothError.unimplemented("Windows scan backend")
    }

    func connect(
        to peripheral: Peripheral,
        options: ConnectionOptions
    ) async throws -> any _PeripheralConnectionBackend {
        _ = peripheral
        _ = options
        throw BluetoothError.unimplemented("Windows connect backend")
    }
}

actor _WindowsPeripheralBackend: _PeripheralBackend {
    var state: BluetoothState { .unknown }

    func stateUpdates() -> AsyncStream<BluetoothState> {
        AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        }
    }

    func connectionEvents() async throws -> AsyncThrowingStream<PeripheralConnectionEvent, Error> {
        throw BluetoothError.unimplemented("Windows peripheral connection events backend")
    }

    func startAdvertising(advertisingData: AdvertisementData, scanResponseData: AdvertisementData?, parameters: AdvertisingParameters) async throws {
        _ = advertisingData
        _ = scanResponseData
        _ = parameters
        throw BluetoothError.unimplemented("Windows advertising backend")
    }

    func startAdvertisingSet(_ configuration: AdvertisingSetConfiguration) async throws -> AdvertisingSetID {
        _ = configuration
        throw BluetoothError.unimplemented("Windows extended advertising backend")
    }

    func updateAdvertisingSet(_ id: AdvertisingSetID, configuration: AdvertisingSetConfiguration) async throws {
        _ = id
        _ = configuration
        throw BluetoothError.unimplemented("Windows extended advertising update backend")
    }

    func stopAdvertising() async {
    }

    func stopAdvertisingSet(_ id: AdvertisingSetID) async {
        _ = id
    }

    func disconnect(_ central: Central) async throws {
        _ = central
        throw BluetoothError.unimplemented("Windows peripheral disconnect backend")
    }

    func addService(_ service: GATTServiceDefinition) async throws -> GATTServiceRegistration {
        _ = service
        throw BluetoothError.unimplemented("Windows GATT server backend")
    }

    func gattRequests() async throws -> AsyncThrowingStream<GATTServerRequest, Error> {
        throw BluetoothError.unimplemented("Windows GATT request backend")
    }

    func updateValue(_ value: Data, for characteristic: GATTCharacteristic, type: GATTServerUpdateType) async throws {
        _ = value
        _ = characteristic
        _ = type
        throw BluetoothError.unimplemented("Windows GATT updateValue backend")
    }

    func publishL2CAPChannel(parameters: L2CAPChannelParameters) async throws -> L2CAPPSM {
        _ = parameters
        throw BluetoothError.unimplemented("Windows L2CAP server backend")
    }

    func incomingL2CAPChannels(psm: L2CAPPSM) async throws -> AsyncThrowingStream<any L2CAPChannel, Error> {
        _ = psm
        throw BluetoothError.unimplemented("Windows L2CAP incoming backend")
    }
}

#endif
