enum _BackendFactory {
  static func makeCentral(options: BluetoothOptions) -> any _CentralBackend {
    #if BLUETOOTH_BACKEND_FORCE_COREBLUETOOTH
      #if canImport(CoreBluetooth)
        return _CoreBluetoothCentralBackend()
      #else
        return _UnsupportedCentralBackend()
      #endif
    #elseif BLUETOOTH_BACKEND_FORCE_BLUEZ
      #if os(Linux)
        return _BlueZCentralBackend(options: options)
      #else
        return _UnsupportedCentralBackend()
      #endif
    #elseif BLUETOOTH_BACKEND_FORCE_WINDOWS
      #if os(Windows)
        return _WindowsCentralBackend()
      #else
        return _UnsupportedCentralBackend()
      #endif
    #elseif canImport(CoreBluetooth)
      return _CoreBluetoothCentralBackend()
    #elseif os(Linux)
      return _BlueZCentralBackend(options: options)
    #elseif os(Windows)
      return _WindowsCentralBackend()
    #else
      return _UnsupportedCentralBackend()
    #endif
  }

  static func makePeripheral(options: BluetoothOptions) -> any _PeripheralBackend {
    #if BLUETOOTH_BACKEND_FORCE_COREBLUETOOTH
      #if canImport(CoreBluetooth)
        return _CoreBluetoothPeripheralBackend()
      #else
        return _UnsupportedPeripheralBackend()
      #endif
    #elseif BLUETOOTH_BACKEND_FORCE_BLUEZ
      #if os(Linux)
        return _BlueZPeripheralBackend(options: options)
      #else
        return _UnsupportedPeripheralBackend()
      #endif
    #elseif BLUETOOTH_BACKEND_FORCE_WINDOWS
      #if os(Windows)
        return _WindowsPeripheralBackend()
      #else
        return _UnsupportedPeripheralBackend()
      #endif
    #elseif canImport(CoreBluetooth)
      return _CoreBluetoothPeripheralBackend()
    #elseif os(Linux)
      return _BlueZPeripheralBackend(options: options)
    #elseif os(Windows)
      return _WindowsPeripheralBackend()
    #else
      return _UnsupportedPeripheralBackend()
    #endif
  }
}
