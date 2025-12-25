#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct GATTService: Hashable, Sendable, Codable {
    public var uuid: BluetoothUUID
    public var isPrimary: Bool
    public var instanceID: UInt32?

    public init(uuid: BluetoothUUID, isPrimary: Bool = true, instanceID: UInt32? = nil) {
        self.uuid = uuid
        self.isPrimary = isPrimary
        self.instanceID = instanceID
    }
}

public struct GATTCharacteristic: Hashable, Sendable, Codable {
    public var uuid: BluetoothUUID
    public var properties: GATTCharacteristicProperties
    public var instanceID: UInt32?
    public var service: GATTService

    public init(
        uuid: BluetoothUUID,
        properties: GATTCharacteristicProperties = [],
        instanceID: UInt32? = nil,
        service: GATTService
    ) {
        self.uuid = uuid
        self.properties = properties
        self.instanceID = instanceID
        self.service = service
    }
}

public struct GATTDescriptor: Hashable, Sendable, Codable {
    public var uuid: BluetoothUUID
    public var characteristic: GATTCharacteristic

    public init(uuid: BluetoothUUID, characteristic: GATTCharacteristic) {
        self.uuid = uuid
        self.characteristic = characteristic
    }
}

public struct GATTCharacteristicProperties: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let broadcast = Self(rawValue: 1 << 0)
    public static let read = Self(rawValue: 1 << 1)
    public static let writeWithoutResponse = Self(rawValue: 1 << 2)
    public static let write = Self(rawValue: 1 << 3)
    public static let notify = Self(rawValue: 1 << 4)
    public static let indicate = Self(rawValue: 1 << 5)
    public static let authenticatedSignedWrites = Self(rawValue: 1 << 6)
    public static let extendedProperties = Self(rawValue: 1 << 7)
}

public struct GATTAttributePermissions: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let readable = Self(rawValue: 1 << 0)
    public static let writeable = Self(rawValue: 1 << 1)
    public static let readEncryptionRequired = Self(rawValue: 1 << 2)
    public static let writeEncryptionRequired = Self(rawValue: 1 << 3)
}

public enum GATTWriteType: Sendable, Codable, Hashable {
    case withResponse
    case withoutResponse
}

public enum GATTNotification: Sendable, Hashable {
    case notification(Data)
    case indication(Data)
}

public enum GATTClientSubscriptionType: Sendable, Codable, Hashable {
    case notification
    case indication
}
