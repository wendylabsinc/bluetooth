#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public struct ScanParameters: Hashable, Sendable, Codable {
  public var allowDuplicates: Bool
  public var active: Bool
  public var interval: TimeInterval?
  public var window: TimeInterval?

  public init(
    allowDuplicates: Bool = false,
    active: Bool = true,
    interval: TimeInterval? = nil,
    window: TimeInterval? = nil
  ) {
    self.allowDuplicates = allowDuplicates
    self.active = active
    self.interval = interval
    self.window = window
  }
}
