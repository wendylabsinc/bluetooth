#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct ManufacturerData: Hashable, Sendable, Codable {
    public var companyIdentifier: UInt16
    public var data: Data

    public init(companyIdentifier: UInt16, data: Data) {
        self.companyIdentifier = companyIdentifier
        self.data = data
    }
}

public struct AdvertisementData: Hashable, Sendable, Codable {
    public var localName: String?
    public var serviceUUIDs: [BluetoothUUID]
    public var serviceData: [BluetoothUUID: Data]
    public var manufacturerData: ManufacturerData?
    public var txPowerLevel: Int?

    public init(
        localName: String? = nil,
        serviceUUIDs: [BluetoothUUID] = [],
        serviceData: [BluetoothUUID: Data] = [:],
        manufacturerData: ManufacturerData? = nil,
        txPowerLevel: Int? = nil
    ) {
        self.localName = localName
        self.serviceUUIDs = serviceUUIDs
        self.serviceData = serviceData
        self.manufacturerData = manufacturerData
        self.txPowerLevel = txPowerLevel
    }
}
