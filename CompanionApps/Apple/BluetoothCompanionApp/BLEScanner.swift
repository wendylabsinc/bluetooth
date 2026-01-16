//
//  BLEScanner.swift
//  BluetoothCompanionApp
//

import Combine
import CoreBluetooth
import Foundation

@MainActor
@Observable
final class BLEScanner: NSObject {
  private(set) var devices: [UUID: BLEDevice] = [:]
  private(set) var isScanning = false
  private(set) var bluetoothState: CBManagerState = .unknown

  // Connection state
  private(set) var connectedDevice: BLEDevice?
  private(set) var connectionState: ConnectionState = .disconnected
  private(set) var discoveredServices: [CBService] = []
  private(set) var characteristicsByService: [CBUUID: [CBCharacteristic]] = [:]
  private(set) var characteristicValues: [CBUUID: Data] = [:]
  private(set) var isDiscoveringServices = false

  enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting

    var description: String {
      switch self {
      case .disconnected: return "Disconnected"
      case .connecting: return "Connecting..."
      case .connected: return "Connected"
      case .disconnecting: return "Disconnecting..."
      }
    }
  }

  private var centralManager: CBCentralManager?
  private var connectedPeripheral: CBPeripheral?

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

  // MARK: - Connection

  func connect(to device: BLEDevice) {
    guard let centralManager, connectionState == .disconnected else { return }

    stopScanning()
    connectionState = .connecting
    connectedDevice = device

    device.peripheral.delegate = self
    centralManager.connect(device.peripheral, options: nil)
  }

  func disconnect() {
    guard let centralManager, let peripheral = connectedPeripheral else { return }

    connectionState = .disconnecting
    centralManager.cancelPeripheralConnection(peripheral)
  }

  // MARK: - GATT Operations

  func discoverServices() {
    guard let peripheral = connectedPeripheral, connectionState == .connected else { return }

    isDiscoveringServices = true
    discoveredServices = []
    characteristicsByService = [:]
    peripheral.discoverServices(nil)
  }

  func discoverCharacteristics(for service: CBService) {
    guard let peripheral = connectedPeripheral else { return }
    peripheral.discoverCharacteristics(nil, for: service)
  }

  func readValue(for characteristic: CBCharacteristic) {
    guard let peripheral = connectedPeripheral else { return }
    peripheral.readValue(for: characteristic)
  }

  func writeValue(_ data: Data, for characteristic: CBCharacteristic, withResponse: Bool) {
    guard let peripheral = connectedPeripheral else { return }
    let type: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse
    peripheral.writeValue(data, for: characteristic, type: type)
  }

  func setNotifications(enabled: Bool, for characteristic: CBCharacteristic) {
    guard let peripheral = connectedPeripheral else { return }
    peripheral.setNotifyValue(enabled, for: characteristic)
  }
}

// MARK: - CBCentralManagerDelegate

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

  nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral)
  {
    Task { @MainActor in
      self.connectedPeripheral = peripheral
      self.connectionState = .connected
      // Auto-discover services on connect
      self.discoverServices()
    }
  }

  nonisolated func centralManager(
    _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
  ) {
    Task { @MainActor in
      self.connectionState = .disconnected
      self.connectedDevice = nil
      self.connectedPeripheral = nil
    }
  }

  nonisolated func centralManager(
    _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
  ) {
    Task { @MainActor in
      self.connectionState = .disconnected
      self.connectedDevice = nil
      self.connectedPeripheral = nil
      self.discoveredServices = []
      self.characteristicsByService = [:]
      self.characteristicValues = [:]
    }
  }
}

// MARK: - CBPeripheralDelegate

extension BLEScanner: CBPeripheralDelegate {
  nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    Task { @MainActor in
      self.isDiscoveringServices = false
      if let services = peripheral.services {
        self.discoveredServices = services
        // Auto-discover characteristics for each service
        for service in services {
          peripheral.discoverCharacteristics(nil, for: service)
        }
      }
    }
  }

  nonisolated func peripheral(
    _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
  ) {
    Task { @MainActor in
      if let characteristics = service.characteristics {
        self.characteristicsByService[service.uuid] = characteristics
      }
    }
  }

  nonisolated func peripheral(
    _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
  ) {
    Task { @MainActor in
      if let value = characteristic.value {
        self.characteristicValues[characteristic.uuid] = value
      }
    }
  }

  nonisolated func peripheral(
    _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?
  ) {
    // Handle write confirmation if needed
    Task { @MainActor in
      // Optionally read back the value
      peripheral.readValue(for: characteristic)
    }
  }

  nonisolated func peripheral(
    _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    // Handle notification state change
  }
}
