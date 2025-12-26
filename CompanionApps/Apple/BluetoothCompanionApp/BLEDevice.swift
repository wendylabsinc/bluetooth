//
//  BLEDevice.swift
//  BluetoothCompanionApp
//

import Foundation
import CoreBluetooth

struct BLEDevice: Identifiable, Hashable {
    let id: UUID
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
    let advertisementData: [String: Any]
    let discoveredAt: Date

    var serviceUUIDs: [CBUUID] {
        advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
    }

    var localName: String? {
        advertisementData[CBAdvertisementDataLocalNameKey] as? String
    }

    var isConnectable: Bool {
        advertisementData[CBAdvertisementDataIsConnectable] as? Bool ?? false
    }

    var txPowerLevel: Int? {
        advertisementData[CBAdvertisementDataTxPowerLevelKey] as? Int
    }

    var manufacturerData: Data? {
        advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
    }

    var displayName: String {
        localName ?? name
    }

    var rssiDescription: String {
        switch rssi {
        case -50...0:
            return "Excellent"
        case -60..<(-50):
            return "Good"
        case -70..<(-60):
            return "Fair"
        default:
            return "Weak"
        }
    }

    var rssiIcon: String {
        switch rssi {
        case -50...0:
            return "wifi"
        case -60..<(-50):
            return "wifi"
        case -70..<(-60):
            return "wifi.exclamationmark"
        default:
            return "wifi.slash"
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: BLEDevice, rhs: BLEDevice) -> Bool {
        lhs.id == rhs.id
    }

    func matchesFuzzySearch(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }

        let lowercasedQuery = query.lowercased()
        let lowercasedName = displayName.lowercased()

        // Exact substring match
        if lowercasedName.contains(lowercasedQuery) {
            return true
        }

        // Fuzzy match: check if all characters appear in order
        var queryIndex = lowercasedQuery.startIndex
        for char in lowercasedName {
            if queryIndex < lowercasedQuery.endIndex && char == lowercasedQuery[queryIndex] {
                queryIndex = lowercasedQuery.index(after: queryIndex)
            }
        }

        if queryIndex == lowercasedQuery.endIndex {
            return true
        }

        // Also search in service UUIDs
        for uuid in serviceUUIDs {
            if uuid.uuidString.lowercased().contains(lowercasedQuery) {
                return true
            }
        }

        return false
    }
}
