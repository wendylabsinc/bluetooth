#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public enum PairingState: Sendable, Hashable {
    case unknown
    case unpaired
    case paired
}
