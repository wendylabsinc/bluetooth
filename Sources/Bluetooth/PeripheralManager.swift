#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public actor PeripheralManager {
    private let backend: any _PeripheralBackend

    public init() {
        self.backend = _BackendFactory.makePeripheral()
    }

    init(backend: any _PeripheralBackend) {
        self.backend = backend
    }

    public func state() async -> BluetoothState {
        await backend.state
    }

    public func stateUpdates() async -> AsyncStream<BluetoothState> {
        await backend.stateUpdates()
    }

    public func startAdvertising(
        _ advertisingData: AdvertisementData,
        parameters: AdvertisingParameters = .init()
    ) async throws {
        try await startAdvertising(advertisingData: advertisingData, scanResponseData: nil, parameters: parameters)
    }

    public func startAdvertising(
        advertisingData: AdvertisementData,
        scanResponseData: AdvertisementData? = nil,
        parameters: AdvertisingParameters = .init()
    ) async throws {
        try await backend.startAdvertising(
            advertisingData: advertisingData,
            scanResponseData: scanResponseData,
            parameters: parameters
        )
    }

    public func startAdvertisingSet(_ configuration: AdvertisingSetConfiguration) async throws -> AdvertisingSetID {
        try await backend.startAdvertisingSet(configuration)
    }

    public func updateAdvertisingSet(_ id: AdvertisingSetID, configuration: AdvertisingSetConfiguration) async throws {
        try await backend.updateAdvertisingSet(id, configuration: configuration)
    }

    public func stopAdvertising() async {
        await backend.stopAdvertising()
    }

    public func stopAdvertisingSet(_ id: AdvertisingSetID) async {
        await backend.stopAdvertisingSet(id)
    }

    public func addService(_ service: GATTServiceDefinition) async throws -> GATTServiceRegistration {
        try await backend.addService(service)
    }

    public func gattRequests() async throws -> AsyncThrowingStream<GATTServerRequest, Error> {
        try await backend.gattRequests()
    }

    public func updateValue(
        _ value: Data,
        for characteristic: GATTCharacteristic,
        type: GATTServerUpdateType = .notification
    ) async throws {
        try await backend.updateValue(value, for: characteristic, type: type)
    }

    public func publishL2CAPChannel(
        parameters: L2CAPChannelParameters = .init()
    ) async throws -> L2CAPPSM {
        try await backend.publishL2CAPChannel(parameters: parameters)
    }

    public func incomingL2CAPChannels(
        psm: L2CAPPSM
    ) async throws -> AsyncThrowingStream<any L2CAPChannel, Error> {
        try await backend.incomingL2CAPChannels(psm: psm)
    }
}
