//
//  BLEScanner.swift
//  BluetoothCompanionApp
//

import Foundation
import CoreBluetooth
import Combine

@MainActor
@Observable
final class BLEScanner: NSObject {
    private(set) var devices: [UUID: BLEDevice] = [:]
    private(set) var isScanning = false
    private(set) var bluetoothState: CBManagerState = .unknown

    private var centralManager: CBCentralManager?

    var sortedDevices: [BLEDevice] {
        devices.values.sorted { $0.rssi > $1.rssi }
    }

    var stateDescription: String {
        switch bluetoothState {
        case .unknown:
            return "Unknown"
        case .resetting:
            return "Resetting"
        case .unsupported:
            return "Unsupported"
        case .unauthorized:
            return "Unauthorized"
        case .poweredOff:
            return "Powered Off"
        case .poweredOn:
            return "Powered On"
        @unknown default:
            return "Unknown"
        }
    }

    var canScan: Bool {
        bluetoothState == .poweredOn
    }

    var isUnauthorized: Bool {
        bluetoothState == .unauthorized
    }

    var authorizationStatus: CBManagerAuthorization {
        CBManager.authorization
    }

    override init() {
        super.init()
        Task { @MainActor in
            self.centralManager = CBCentralManager(delegate: self, queue: nil)
        }
    }

    func startScanning() {
        guard let centralManager, bluetoothState == .poweredOn else { return }

        devices.removeAll()
        isScanning = true

        centralManager.scanForPeripherals(
            withServices: nil,
            options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: true
            ]
        )
    }

    func stopScanning() {
        centralManager?.stopScan()
        isScanning = false
    }

    func toggleScanning() {
        if isScanning {
            stopScanning()
        } else {
            startScanning()
        }
    }

    func clearDevices() {
        devices.removeAll()
    }
}

extension BLEScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            self.bluetoothState = central.state
            if central.state != .poweredOn {
                self.stopScanning()
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let device = BLEDevice(
            id: peripheral.identifier,
            peripheral: peripheral,
            name: peripheral.name ?? "Unknown",
            rssi: RSSI.intValue,
            advertisementData: advertisementData,
            discoveredAt: Date()
        )

        Task { @MainActor in
            self.devices[peripheral.identifier] = device
        }
    }
}
