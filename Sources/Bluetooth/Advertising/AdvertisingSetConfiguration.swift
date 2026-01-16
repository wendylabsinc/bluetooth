public struct PeriodicAdvertisingConfiguration: Hashable, Sendable, Codable {
  public var advertisingData: AdvertisementData
  public var parameters: PeriodicAdvertisingParameters

  public init(
    advertisingData: AdvertisementData, parameters: PeriodicAdvertisingParameters = .init()
  ) {
    self.advertisingData = advertisingData
    self.parameters = parameters
  }
}

public struct AdvertisingSetConfiguration: Hashable, Sendable, Codable {
  public var advertisingData: AdvertisementData
  public var scanResponseData: AdvertisementData?
  public var parameters: AdvertisingParameters
  public var periodic: PeriodicAdvertisingConfiguration?

  public init(
    advertisingData: AdvertisementData,
    scanResponseData: AdvertisementData? = nil,
    parameters: AdvertisingParameters = .init(),
    periodic: PeriodicAdvertisingConfiguration? = nil
  ) {
    self.advertisingData = advertisingData
    self.scanResponseData = scanResponseData
    self.parameters = parameters
    self.periodic = periodic
  }
}

public struct AdvertisingSetID: Hashable, Sendable, Codable {
  public var rawValue: UInt64

  public init(_ rawValue: UInt64) {
    self.rawValue = rawValue
  }
}
