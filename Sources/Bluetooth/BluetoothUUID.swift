#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public enum BluetoothUUID: Hashable, Sendable, Codable {
    case bit16(UInt16)
    case bit32(UInt32)
    case bit128(UUID)

    public init(_ uuid: UUID) {
        self = .bit128(uuid)
    }
}

extension BluetoothUUID: CustomStringConvertible {
    public var description: String {
        switch self {
        case .bit16(let value):
            let hex = String(value, radix: 16, uppercase: false)
            return String(repeating: "0", count: max(0, 4 - hex.count)) + hex
        case .bit32(let value):
            let hex = String(value, radix: 16, uppercase: false)
            return String(repeating: "0", count: max(0, 8 - hex.count)) + hex
        case .bit128(let value):
            // BlueZ expects lowercase UUIDs
            return value.uuidString.lowercased()
        }
    }
}
