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
    public var respond: @Sendable (Result<Data, Error>) async -> Void

    public init(
        central: Central?,
        characteristic: GATTCharacteristic,
        offset: Int = 0,
        respond: @escaping @Sendable (Result<Data, Error>) async -> Void
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
    public var respond: @Sendable (Result<Void, Error>) async -> Void

    public init(
        central: Central?,
        characteristic: GATTCharacteristic,
        value: Data,
        offset: Int = 0,
        respond: @escaping @Sendable (Result<Void, Error>) async -> Void
    ) {
        self.central = central
        self.characteristic = characteristic
        self.value = value
        self.offset = offset
        self.respond = respond
    }
}

public struct GATTSubscription: Hashable, Sendable {
    public var central: Central?
    public var characteristic: GATTCharacteristic

    public init(central: Central?, characteristic: GATTCharacteristic) {
        self.central = central
        self.characteristic = characteristic
    }
}

public enum GATTServerRequest: Sendable {
    case read(GATTReadRequest)
    case write(GATTWriteRequest)
    case subscribe(GATTSubscription)
    case unsubscribe(GATTSubscription)
}

