import Logging

/// Internal logging infrastructure for the Bluetooth module.
/// Uses swift-log with subsystem labels for structured logging.
enum BluetoothLogger {
  /// Logger for advertising operations (registration, unregistration, retries)
  static let advertising = Logger(label: "com.wendylabs.bluetooth.advertising")

  /// Logger for scanning/discovery operations
  static let scanning = Logger(label: "com.wendylabs.bluetooth.scanning")

  /// Logger for connection lifecycle (connect, disconnect, state changes)
  static let connection = Logger(label: "com.wendylabs.bluetooth.connection")

  /// Logger for GATT operations (services, characteristics, read/write)
  static let gatt = Logger(label: "com.wendylabs.bluetooth.gatt")

  /// Logger for pairing/agent operations (PIN codes, passkeys, confirmations)
  static let pairing = Logger(label: "com.wendylabs.bluetooth.pairing")

  /// Logger for L2CAP channel operations
  static let l2cap = Logger(label: "com.wendylabs.bluetooth.l2cap")

  /// Logger for D-Bus communication (BlueZ-specific)
  static let dbus = Logger(label: "com.wendylabs.bluetooth.dbus")

  /// Logger for general backend operations
  static let backend = Logger(label: "com.wendylabs.bluetooth.backend")
}

/// Metadata keys used across the logging system for consistent structured logging
enum BluetoothLogMetadata {
  static let devicePath = "devicePath"
  static let deviceAddress = "address"
  static let adapterPath = "adapterPath"
  static let advertisementPath = "advertisementPath"
  static let agentPath = "agentPath"
  static let serviceUUID = "serviceUUID"
  static let characteristicUUID = "characteristicUUID"
  static let psm = "psm"
  static let error = "error"
  static let attempt = "attempt"
  static let maxAttempts = "maxAttempts"
  static let duration = "durationMs"
  static let bytesCount = "bytes"
}
