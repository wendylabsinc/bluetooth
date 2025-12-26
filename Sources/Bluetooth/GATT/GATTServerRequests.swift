#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public enum GATTServerUpdateType: Sendable, Codable, Hashable {
    case notification
    case indication
}

public struct GATTServiceRegistration: Hashable, Sendable, Codable {
    public var service: GATTService
    public var characteristics: [GATTCharacteristic]

    public init(service: GATTService, characteristics: [GATTCharacteristic]) {
        self.service = service
        self.characteristics = characteristics
    }
}

public struct GATTReadRequest: Sendable {
    public var central: Central?
    public var characteristic: GATTCharacteristic
    public var offset: Int
    public var respond: @Sendable (Result<Data, GATTError>) async -> Void

    public init(
        central: Central?,
        characteristic: GATTCharacteristic,
        offset: Int = 0,
        respond: @escaping @Sendable (Result<Data, GATTError>) async -> Void
    ) {
        self.central = central
        self.characteristic = characteristic
        self.offset = offset
        self.respond = respond
    }
}

public struct GATTWriteRequest: Sendable {
    public var central: Central?
    public var characteristic: GATTCharacteristic
    public var value: Data
    public var offset: Int
    public var writeType: GATTWriteType
    public var isPreparedWrite: Bool
    public var respond: @Sendable (Result<Void, GATTError>) async -> Void

    public init(
        central: Central?,
        characteristic: GATTCharacteristic,
        value: Data,
        offset: Int = 0,
        writeType: GATTWriteType = .withResponse,
        isPreparedWrite: Bool = false,
        respond: @escaping @Sendable (Result<Void, GATTError>) async -> Void
    ) {
        self.central = central
        self.characteristic = characteristic
        self.value = value
        self.offset = offset
        self.writeType = writeType
        self.isPreparedWrite = isPreparedWrite
        self.respond = respond
    }
}

public struct GATTDescriptorReadRequest: Sendable {
    public var central: Central?
    public var descriptor: GATTDescriptor
    public var offset: Int
    public var respond: @Sendable (Result<Data, GATTError>) async -> Void

    public init(
        central: Central?,
        descriptor: GATTDescriptor,
        offset: Int = 0,
        respond: @escaping @Sendable (Result<Data, GATTError>) async -> Void
    ) {
        self.central = central
        self.descriptor = descriptor
        self.offset = offset
        self.respond = respond
    }
}

public struct GATTDescriptorWriteRequest: Sendable {
    public var central: Central?
    public var descriptor: GATTDescriptor
    public var value: Data
    public var offset: Int
    public var writeType: GATTWriteType
    public var isPreparedWrite: Bool
    public var respond: @Sendable (Result<Void, GATTError>) async -> Void

    public init(
        central: Central?,
        descriptor: GATTDescriptor,
        value: Data,
        offset: Int = 0,
        writeType: GATTWriteType = .withResponse,
        isPreparedWrite: Bool = false,
        respond: @escaping @Sendable (Result<Void, GATTError>) async -> Void
    ) {
        self.central = central
        self.descriptor = descriptor
        self.value = value
        self.offset = offset
        self.writeType = writeType
        self.isPreparedWrite = isPreparedWrite
        self.respond = respond
    }
}

public struct GATTExecuteWriteRequest: Sendable {
    public var central: Central?
    public var shouldCommit: Bool
    public var respond: @Sendable (Result<Void, GATTError>) async -> Void

    public init(
        central: Central?,
        shouldCommit: Bool,
        respond: @escaping @Sendable (Result<Void, GATTError>) async -> Void
    ) {
        self.central = central
        self.shouldCommit = shouldCommit
        self.respond = respond
    }
}

public enum GATTAuthorizationTarget: Sendable, Hashable {
    case characteristic(GATTCharacteristic)
    case descriptor(GATTDescriptor)
}

public enum GATTAuthorizationType: Sendable, Hashable {
    case read
    case write
}

public struct GATTAuthorizationRequest: Sendable {
    public var central: Central?
    public var target: GATTAuthorizationTarget
    public var type: GATTAuthorizationType
    public var respond: @Sendable (Bool) async -> Void

    public init(
        central: Central?,
        target: GATTAuthorizationTarget,
        type: GATTAuthorizationType,
        respond: @escaping @Sendable (Bool) async -> Void
    ) {
        self.central = central
        self.target = target
        self.type = type
        self.respond = respond
    }
}

public struct GATTSubscription: Hashable, Sendable {
    public var central: Central?
    public var characteristic: GATTCharacteristic
    public var type: GATTClientSubscriptionType

    public init(
        central: Central?,
        characteristic: GATTCharacteristic,
        type: GATTClientSubscriptionType = .notification
    ) {
        self.central = central
        self.characteristic = characteristic
        self.type = type
    }
}

public enum GATTServerRequest: Sendable {
    case read(GATTReadRequest)
    case write(GATTWriteRequest)
    case readDescriptor(GATTDescriptorReadRequest)
    case writeDescriptor(GATTDescriptorWriteRequest)
    case executeWrite(GATTExecuteWriteRequest)
    case authorize(GATTAuthorizationRequest)
    case subscribe(GATTSubscription)
    case unsubscribe(GATTSubscription)
}
