#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public enum GATTErrorCode: UInt8, Sendable, Codable, Hashable {
    case invalidHandle = 0x01
    case readNotPermitted = 0x02
    case writeNotPermitted = 0x03
    case invalidPdu = 0x04
    case insufficientAuthentication = 0x05
    case requestNotSupported = 0x06
    case invalidOffset = 0x07
    case insufficientAuthorization = 0x08
    case prepareQueueFull = 0x09
    case attributeNotFound = 0x0A
    case attributeNotLong = 0x0B
    case insufficientEncryptionKeySize = 0x0C
    case invalidAttributeValueLength = 0x0D
    case unlikelyError = 0x0E
    case insufficientEncryption = 0x0F
    case unsupportedGroupType = 0x10
    case insufficientResources = 0x11
}

public enum GATTError: Error, Sendable, Hashable {
    case att(GATTErrorCode)
    case other(String)
}
