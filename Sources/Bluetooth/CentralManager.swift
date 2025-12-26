public struct ConnectionOptions: Hashable, Sendable, Codable {
    public var requiresBonding: Bool

    public init(requiresBonding: Bool = false) {
        self.requiresBonding = requiresBonding
    }
}

public actor CentralManager {
    private let backend: any _CentralBackend

    public init(options: BluetoothOptions = .init()) {
        self.backend = _BackendFactory.makeCentral(options: options)
    }

    init(backend: any _CentralBackend) {
        self.backend = backend
    }

    public func state() async -> BluetoothState {
        await backend.state
    }

    public func stateUpdates() async -> AsyncStream<BluetoothState> {
        await backend.stateUpdates()
    }

    public func scan(
        filter: ScanFilter? = nil,
        parameters: ScanParameters = .init()
    ) async throws -> AsyncThrowingStream<ScanResult, Error> {
        try await backend.scan(filter: filter, parameters: parameters)
    }

    public func stopScan() async throws {
        try await backend.stopScan()
    }

    public func pairingRequests() async throws -> AsyncThrowingStream<PairingRequest, Error> {
        try await backend.pairingRequests()
    }

    public func removeBond(for peripheral: Peripheral) async throws {
        try await backend.removeBond(for: peripheral)
    }

    public func connect(
        to peripheral: Peripheral,
        options: ConnectionOptions = .init()
    ) async throws -> PeripheralConnection {
        let connectionBackend = try await backend.connect(to: peripheral, options: options)
        return PeripheralConnection(peripheral: peripheral, backend: connectionBackend)
    }
}
