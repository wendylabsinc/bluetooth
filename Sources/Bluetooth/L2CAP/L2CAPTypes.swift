#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public struct L2CAPPSM: RawRepresentable, Hashable, Sendable, Codable {
  public var rawValue: UInt16

  public init(rawValue: UInt16) {
    self.rawValue = rawValue
  }
}

public struct L2CAPChannelParameters: Hashable, Sendable, Codable {
  public var requiresEncryption: Bool

  public init(requiresEncryption: Bool = false) {
    self.requiresEncryption = requiresEncryption
  }
}

public protocol L2CAPChannel: Sendable {
  var psm: L2CAPPSM { get }
  var mtu: Int { get }

  func send(_ data: Data) async throws
  func incoming() -> AsyncThrowingStream<Data, Error>
  func close() async
}
