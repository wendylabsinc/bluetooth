#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public struct BluetoothAdapter: Hashable, Sendable, Codable {
  public var identifier: String

  public init(_ identifier: String) {
    self.identifier = identifier
  }
}

public struct BluetoothOptions: Hashable, Sendable, Codable {
  public var adapter: BluetoothAdapter?

  public init(adapter: BluetoothAdapter? = nil) {
    self.adapter = adapter
  }
}
