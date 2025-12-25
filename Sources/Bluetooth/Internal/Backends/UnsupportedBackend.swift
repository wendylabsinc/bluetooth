#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

actor _UnsupportedCentralBackend: _CentralBackend {
    var state: BluetoothState { .unsupported }

    func stateUpdates() -> AsyncStream<BluetoothState> {
        AsyncStream { continuation in
            continuation.yield(.unsupported)
            continuation.finish()
        }
    }

    func stopScan() async throws {
        throw BluetoothError.backendUnavailable
    }

    func scan(
        filter: ScanFilter?,
        parameters: ScanParameters
    ) async throws -> AsyncThrowingStream<ScanResult, Error> {
        _ = filter
        _ = parameters
        throw BluetoothError.backendUnavailable
    }

    func connect(
        to peripheral: Peripheral,
        options: ConnectionOptions
    ) async throws -> any _PeripheralConnectionBackend {
        _ = peripheral
        _ = options
        throw BluetoothError.backendUnavailable
    }
}

actor _UnsupportedPeripheralBackend: _PeripheralBackend {
    var state: BluetoothState { .unsupported }

    func stateUpdates() -> AsyncStream<BluetoothState> {
        AsyncStream { continuation in
            continuation.yield(.unsupported)
            continuation.finish()
        }
    }

    func connectionEvents() async throws -> AsyncThrowingStream<PeripheralConnectionEvent, Error> {
        throw BluetoothError.backendUnavailable
    }

    func startAdvertising(advertisingData: AdvertisementData, scanResponseData: AdvertisementData?, parameters: AdvertisingParameters) async throws {
        _ = advertisingData
        _ = scanResponseData
        _ = parameters
        throw BluetoothError.backendUnavailable
    }

    func startAdvertisingSet(_ configuration: AdvertisingSetConfiguration) async throws -> AdvertisingSetID {
        _ = configuration
        throw BluetoothError.backendUnavailable
    }

    func updateAdvertisingSet(_ id: AdvertisingSetID, configuration: AdvertisingSetConfiguration) async throws {
        _ = id
        _ = configuration
        throw BluetoothError.backendUnavailable
    }

    func stopAdvertising() async {
    }

    func stopAdvertisingSet(_ id: AdvertisingSetID) async {
        _ = id
    }

    func disconnect(_ central: Central) async throws {
        _ = central
        throw BluetoothError.backendUnavailable
    }

    func addService(_ service: GATTServiceDefinition) async throws -> GATTServiceRegistration {
        _ = service
        throw BluetoothError.backendUnavailable
    }

    func gattRequests() async throws -> AsyncThrowingStream<GATTServerRequest, Error> {
        throw BluetoothError.backendUnavailable
    }

    func updateValue(_ value: Data, for characteristic: GATTCharacteristic, type: GATTServerUpdateType) async throws {
        _ = value
        _ = characteristic
        _ = type
        throw BluetoothError.backendUnavailable
    }

    func publishL2CAPChannel(parameters: L2CAPChannelParameters) async throws -> L2CAPPSM {
        _ = parameters
        throw BluetoothError.backendUnavailable
    }

    func incomingL2CAPChannels(psm: L2CAPPSM) async throws -> AsyncThrowingStream<any L2CAPChannel, Error> {
        _ = psm
        throw BluetoothError.backendUnavailable
    }
}
