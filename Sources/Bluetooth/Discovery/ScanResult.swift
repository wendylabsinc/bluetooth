#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct ScanResult: Hashable, Sendable {
    public var peripheral: Peripheral
    public var advertisementData: AdvertisementData
    public var rssi: Int
    public var timestamp: Date

    public init(peripheral: Peripheral, advertisementData: AdvertisementData, rssi: Int, timestamp: Date = .now) {
        self.peripheral = peripheral
        self.advertisementData = advertisementData
        self.rssi = rssi
        self.timestamp = timestamp
    }
}
