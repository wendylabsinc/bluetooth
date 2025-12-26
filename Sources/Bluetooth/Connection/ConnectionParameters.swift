#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct ConnectionParameters: Hashable, Sendable, Codable {
    public var minIntervalMs: UInt16?
    public var maxIntervalMs: UInt16?
    public var latency: UInt16?
    public var supervisionTimeoutMs: UInt16?

    public init(
        minIntervalMs: UInt16? = nil,
        maxIntervalMs: UInt16? = nil,
        latency: UInt16? = nil,
        supervisionTimeoutMs: UInt16? = nil
    ) {
        self.minIntervalMs = minIntervalMs
        self.maxIntervalMs = maxIntervalMs
        self.latency = latency
        self.supervisionTimeoutMs = supervisionTimeoutMs
    }
}

public struct PHYPreference: Hashable, Sendable, Codable {
    public var tx: BluetoothPHY?
    public var rx: BluetoothPHY?

    public init(tx: BluetoothPHY? = nil, rx: BluetoothPHY? = nil) {
        self.tx = tx
        self.rx = rx
    }
}
