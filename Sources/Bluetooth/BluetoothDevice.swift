#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public struct BluetoothDeviceID: Hashable, Sendable, Codable {
  public var rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public static func uuid(_ uuid: UUID) -> Self {
    Self("uuid:\(uuid.uuidString.lowercased())")
  }

  public static func address(_ address: BluetoothAddress) -> Self {
    Self("addr:\(address.rawValue.lowercased())")
  }
}

extension BluetoothDeviceID: CustomStringConvertible {
  public var description: String { rawValue }
}

public struct Peripheral: Hashable, Sendable {
  public var id: BluetoothDeviceID
  public var name: String?

  public init(id: BluetoothDeviceID, name: String? = nil) {
    self.id = id
    self.name = name
  }
}

public struct Central: Hashable, Sendable {
  public var id: BluetoothDeviceID
  public var name: String?

  public init(id: BluetoothDeviceID, name: String? = nil) {
    self.id = id
    self.name = name
  }
}
