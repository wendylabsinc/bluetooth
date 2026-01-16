public struct ScanFilter: Hashable, Sendable, Codable {
  public var serviceUUIDs: [BluetoothUUID]
  public var namePrefix: String?

  public init(serviceUUIDs: [BluetoothUUID] = [], namePrefix: String? = nil) {
    self.serviceUUIDs = serviceUUIDs
    self.namePrefix = namePrefix
  }
}
