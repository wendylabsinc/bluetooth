#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

protocol _CentralBackend: Actor {
    var state: BluetoothState { get }
    func stateUpdates() -> AsyncStream<BluetoothState>

    func scan(
        filter: ScanFilter?,
        parameters: ScanParameters
    ) async throws -> AsyncThrowingStream<ScanResult, Error>

    func connect(
        to peripheral: Peripheral,
        options: ConnectionOptions
    ) async throws -> any _PeripheralConnectionBackend
}

protocol _PeripheralBackend: Actor {
    var state: BluetoothState { get }
    func stateUpdates() -> AsyncStream<BluetoothState>

    func startAdvertising(
        advertisingData: AdvertisementData,
        scanResponseData: AdvertisementData?,
        parameters: AdvertisingParameters
    ) async throws

    func startAdvertisingSet(_ configuration: AdvertisingSetConfiguration) async throws -> AdvertisingSetID
    func updateAdvertisingSet(_ id: AdvertisingSetID, configuration: AdvertisingSetConfiguration) async throws

    func stopAdvertising() async
    func stopAdvertisingSet(_ id: AdvertisingSetID) async

    func addService(_ service: GATTServiceDefinition) async throws -> GATTServiceRegistration

    func gattRequests() async throws -> AsyncThrowingStream<GATTServerRequest, Error>
    func updateValue(_ value: Data, for characteristic: GATTCharacteristic, type: GATTServerUpdateType) async throws

    func publishL2CAPChannel(parameters: L2CAPChannelParameters) async throws -> L2CAPPSM
    func incomingL2CAPChannels(psm: L2CAPPSM) async throws -> AsyncThrowingStream<any L2CAPChannel, Error>
}

protocol _PeripheralConnectionBackend: Actor {
    var state: PeripheralConnectionState { get }
    func stateUpdates() -> AsyncStream<PeripheralConnectionState>

    func disconnect() async

    func discoverServices(_ uuids: [BluetoothUUID]?) async throws -> [GATTService]

    func discoverCharacteristics(
        _ uuids: [BluetoothUUID]?,
        for service: GATTService
    ) async throws -> [GATTCharacteristic]

    func readValue(for characteristic: GATTCharacteristic) async throws -> Data

    func writeValue(
        _ value: Data,
        for characteristic: GATTCharacteristic,
        type: GATTWriteType
    ) async throws

    func notifications(
        for characteristic: GATTCharacteristic
    ) async throws -> AsyncThrowingStream<GATTNotification, Error>

    func discoverDescriptors(for characteristic: GATTCharacteristic) async throws -> [GATTDescriptor]

    func readValue(for descriptor: GATTDescriptor) async throws -> Data

    func writeValue(_ value: Data, for descriptor: GATTDescriptor) async throws

    func readRSSI() async throws -> Int

    func openL2CAPChannel(
        psm: L2CAPPSM,
        parameters: L2CAPChannelParameters
    ) async throws -> any L2CAPChannel
}
