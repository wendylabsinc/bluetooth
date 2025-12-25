#if canImport(CoreBluetooth)
import CoreBluetooth
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

actor _CoreBluetoothCentralBackend: _CentralBackend {
    var state: BluetoothState { .unknown }

    func stateUpdates() -> AsyncStream<BluetoothState> {
        AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        }
    }

    func scan(
        filter: ScanFilter?,
        parameters: ScanParameters
    ) async throws -> AsyncThrowingStream<ScanResult, Error> {
        _ = filter
        _ = parameters
        throw BluetoothError.unimplemented("CoreBluetooth scan backend")
    }

    func connect(
        to peripheral: Peripheral,
        options: ConnectionOptions
    ) async throws -> any _PeripheralConnectionBackend {
        _ = peripheral
        _ = options
        throw BluetoothError.unimplemented("CoreBluetooth connect backend")
    }
}

actor _CoreBluetoothPeripheralBackend: _PeripheralBackend {
    var state: BluetoothState { .unknown }

    func stateUpdates() -> AsyncStream<BluetoothState> {
        AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        }
    }

    func connectionEvents() async throws -> AsyncThrowingStream<PeripheralConnectionEvent, Error> {
        throw BluetoothError.unimplemented("CoreBluetooth peripheral connection events backend")
    }

    func startAdvertising(advertisingData: AdvertisementData, scanResponseData: AdvertisementData?, parameters: AdvertisingParameters) async throws {
        _ = advertisingData
        _ = scanResponseData
        _ = parameters
        throw BluetoothError.unimplemented("CoreBluetooth advertising backend")
    }

    func startAdvertisingSet(_ configuration: AdvertisingSetConfiguration) async throws -> AdvertisingSetID {
        _ = configuration
        throw BluetoothError.unimplemented("CoreBluetooth extended advertising backend")
    }

    func updateAdvertisingSet(_ id: AdvertisingSetID, configuration: AdvertisingSetConfiguration) async throws {
        _ = id
        _ = configuration
        throw BluetoothError.unimplemented("CoreBluetooth extended advertising update backend")
    }

    func stopAdvertising() async {
    }

    func stopAdvertisingSet(_ id: AdvertisingSetID) async {
        _ = id
    }

    func addService(_ service: GATTServiceDefinition) async throws -> GATTServiceRegistration {
        _ = service
        throw BluetoothError.unimplemented("CoreBluetooth GATT server backend")
    }

    func gattRequests() async throws -> AsyncThrowingStream<GATTServerRequest, Error> {
        throw BluetoothError.unimplemented("CoreBluetooth GATT request backend")
    }

    func updateValue(_ value: Data, for characteristic: GATTCharacteristic, type: GATTServerUpdateType) async throws {
        _ = value
        _ = characteristic
        _ = type
        throw BluetoothError.unimplemented("CoreBluetooth GATT updateValue backend")
    }

    func publishL2CAPChannel(parameters: L2CAPChannelParameters) async throws -> L2CAPPSM {
        _ = parameters
        throw BluetoothError.unimplemented("CoreBluetooth L2CAP server backend")
    }

    func incomingL2CAPChannels(psm: L2CAPPSM) async throws -> AsyncThrowingStream<any L2CAPChannel, Error> {
        _ = psm
        throw BluetoothError.unimplemented("CoreBluetooth L2CAP incoming backend")
    }
}

#endif
