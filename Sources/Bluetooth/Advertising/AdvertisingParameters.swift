#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public enum BluetoothPHY: String, Sendable, Codable, Hashable {
  case le1M
  case le2M
  case leCoded
}

public struct AdvertisingParameters: Hashable, Sendable, Codable {
  public var interval: TimeInterval?
  public var isConnectable: Bool
  public var isScannable: Bool
  public var isExtended: Bool
  public var primaryPHY: BluetoothPHY?
  public var secondaryPHY: BluetoothPHY?
  public var includeTxPower: Bool

  public init(
    interval: TimeInterval? = nil,
    isConnectable: Bool = true,
    isScannable: Bool = true,
    isExtended: Bool = false,
    primaryPHY: BluetoothPHY? = nil,
    secondaryPHY: BluetoothPHY? = nil,
    includeTxPower: Bool = false
  ) {
    self.interval = interval
    self.isConnectable = isConnectable
    self.isScannable = isScannable
    self.isExtended = isExtended
    self.primaryPHY = primaryPHY
    self.secondaryPHY = secondaryPHY
    self.includeTxPower = includeTxPower
  }
}

public struct PeriodicAdvertisingParameters: Hashable, Sendable, Codable {
  public var interval: TimeInterval?
  public var includeTxPower: Bool

  public init(interval: TimeInterval? = nil, includeTxPower: Bool = false) {
    self.interval = interval
    self.includeTxPower = includeTxPower
  }
}
