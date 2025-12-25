public struct BluetoothAddress: Hashable, Sendable, Codable {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

extension BluetoothAddress: CustomStringConvertible {
    public var description: String { rawValue }
}

