#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public enum PairingRequest: Sendable {
    case displayPinCode(PairingDisplayPinCode)
    case displayPasskey(PairingDisplayPasskey)
    case pinCode(PairingPinCodeRequest)
    case passkey(PairingPasskeyRequest)
    case confirmation(PairingConfirmationRequest)
    case authorization(PairingAuthorizationRequest)
    case serviceAuthorization(PairingServiceAuthorizationRequest)
}

public struct PairingDisplayPinCode: Sendable {
    public var central: Central?
    public var peripheral: Peripheral?
    public var pinCode: String

    public init(central: Central?, pinCode: String, peripheral: Peripheral? = nil) {
        self.central = central
        self.peripheral = peripheral
        self.pinCode = pinCode
    }
}

public struct PairingDisplayPasskey: Sendable {
    public var central: Central?
    public var peripheral: Peripheral?
    public var passkey: UInt32
    public var entered: UInt16?

    public init(
        central: Central?,
        passkey: UInt32,
        entered: UInt16? = nil,
        peripheral: Peripheral? = nil
    ) {
        self.central = central
        self.peripheral = peripheral
        self.passkey = passkey
        self.entered = entered
    }
}

public struct PairingPinCodeRequest: Sendable {
    public var central: Central?
    public var peripheral: Peripheral?
    public var respond: @Sendable (String?) async -> Void

    public init(
        central: Central?,
        peripheral: Peripheral? = nil,
        respond: @escaping @Sendable (String?) async -> Void
    ) {
        self.central = central
        self.peripheral = peripheral
        self.respond = respond
    }
}

public struct PairingPasskeyRequest: Sendable {
    public var central: Central?
    public var peripheral: Peripheral?
    public var respond: @Sendable (UInt32?) async -> Void

    public init(
        central: Central?,
        peripheral: Peripheral? = nil,
        respond: @escaping @Sendable (UInt32?) async -> Void
    ) {
        self.central = central
        self.peripheral = peripheral
        self.respond = respond
    }
}

public struct PairingConfirmationRequest: Sendable {
    public var central: Central?
    public var peripheral: Peripheral?
    public var passkey: UInt32
    public var respond: @Sendable (Bool) async -> Void

    public init(
        central: Central?,
        passkey: UInt32,
        peripheral: Peripheral? = nil,
        respond: @escaping @Sendable (Bool) async -> Void
    ) {
        self.central = central
        self.peripheral = peripheral
        self.passkey = passkey
        self.respond = respond
    }
}

public struct PairingAuthorizationRequest: Sendable {
    public var central: Central?
    public var peripheral: Peripheral?
    public var respond: @Sendable (Bool) async -> Void

    public init(
        central: Central?,
        peripheral: Peripheral? = nil,
        respond: @escaping @Sendable (Bool) async -> Void
    ) {
        self.central = central
        self.peripheral = peripheral
        self.respond = respond
    }
}

public struct PairingServiceAuthorizationRequest: Sendable {
    public var central: Central?
    public var peripheral: Peripheral?
    public var serviceUUID: BluetoothUUID?
    public var respond: @Sendable (Bool) async -> Void

    public init(
        central: Central?,
        serviceUUID: BluetoothUUID?,
        peripheral: Peripheral? = nil,
        respond: @escaping @Sendable (Bool) async -> Void
    ) {
        self.central = central
        self.peripheral = peripheral
        self.serviceUUID = serviceUUID
        self.respond = respond
    }
}
