#if canImport(CoreBluetooth)
  import CoreBluetooth
#endif
#if canImport(Foundation)
  import Foundation
#endif

enum _BackendFactory {
  #if canImport(CoreBluetooth)
    /// Checks if CoreBluetooth is accessible in the current context.
    /// On macOS, apps running in terminals without Bluetooth entitlements will crash
    /// when instantiating CBCentralManager/CBPeripheralManager. This check prevents that.
    private static var isCoreBluetoothAccessible: Bool {
      #if os(macOS)
        // On macOS, check authorization before attempting to use CoreBluetooth.
        // Apps without proper entitlements (e.g., CLI apps in Warp) will have .denied or .restricted.
        let authorization = CBCentralManager.authorization
        switch authorization {
        case .allowedAlways:
          return true
        case .notDetermined:
          // CLI apps without an app bundle cannot prompt for Bluetooth permission
          // and will crash with a TCC privacy violation. Only allow .notDetermined
          // if we're running in an app bundle that can show the permission dialog.
          let isAppBundle = Bundle.main.bundleIdentifier != nil
          return isAppBundle
        case .denied, .restricted:
          return false
        @unknown default:
          return true
        }
      #else
        // On iOS/tvOS/watchOS/visionOS, authorization is handled differently
        // and won't crash on initialization
        return true
      #endif
    }
  #endif

  static func makeCentral(options: BluetoothOptions) -> any _CentralBackend {
    #if BLUETOOTH_BACKEND_FORCE_COREBLUETOOTH
      #if canImport(CoreBluetooth)
        guard isCoreBluetoothAccessible else {
          return _UnsupportedCentralBackend()
        }
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
      guard isCoreBluetoothAccessible else {
        return _UnsupportedCentralBackend()
      }
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
        guard isCoreBluetoothAccessible else {
          return _UnsupportedPeripheralBackend()
        }
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
      guard isCoreBluetoothAccessible else {
        return _UnsupportedPeripheralBackend()
      }
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
