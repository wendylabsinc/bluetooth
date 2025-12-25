enum _BackendFactory {
    static func makeCentral() -> any _CentralBackend {
#if BLUETOOTH_BACKEND_FORCE_COREBLUETOOTH
#if canImport(CoreBluetooth)
        return _CoreBluetoothCentralBackend()
#else
        return _UnsupportedCentralBackend()
#endif
#elseif BLUETOOTH_BACKEND_FORCE_BLUEZ
#if os(Linux)
        return _BlueZCentralBackend()
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
        return _BlueZCentralBackend()
#elseif os(Windows)
        return _WindowsCentralBackend()
#else
        return _UnsupportedCentralBackend()
#endif
    }

    static func makePeripheral() -> any _PeripheralBackend {
#if BLUETOOTH_BACKEND_FORCE_COREBLUETOOTH
#if canImport(CoreBluetooth)
        return _CoreBluetoothPeripheralBackend()
#else
        return _UnsupportedPeripheralBackend()
#endif
#elseif BLUETOOTH_BACKEND_FORCE_BLUEZ
#if os(Linux)
        return _BlueZPeripheralBackend()
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
        return _BlueZPeripheralBackend()
#elseif os(Windows)
        return _WindowsPeripheralBackend()
#else
        return _UnsupportedPeripheralBackend()
#endif
    }
}
