#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct GATTServiceDefinition: Hashable, Sendable, Codable {
    public var uuid: BluetoothUUID
    public var isPrimary: Bool
    public var characteristics: [GATTCharacteristicDefinition]

    public init(uuid: BluetoothUUID, isPrimary: Bool = true, characteristics: [GATTCharacteristicDefinition] = []) {
        self.uuid = uuid
        self.isPrimary = isPrimary
        self.characteristics = characteristics
    }
}

public struct GATTCharacteristicDefinition: Hashable, Sendable, Codable {
    public var uuid: BluetoothUUID
    public var properties: GATTCharacteristicProperties
    public var permissions: GATTAttributePermissions
    public var initialValue: Data?

    public init(
        uuid: BluetoothUUID,
        properties: GATTCharacteristicProperties,
        permissions: GATTAttributePermissions = [],
        initialValue: Data? = nil
    ) {
        self.uuid = uuid
        self.properties = properties
        self.permissions = permissions
        self.initialValue = initialValue
    }
}
