# Backend Implementation Guide

This package exposes a cross-platform BLE API (`CentralManager`, `PeripheralManager`, `PeripheralConnection`) and hides platform-specific details behind internal backend protocols.

Backends are selected at runtime via `_BackendFactory` using conditional compilation, with optional SwiftPM **traits** to force a specific backend. `CentralManager` / `PeripheralManager` pass `BluetoothOptions` (for example adapter selection) into `_BackendFactory`.

## Where Things Live

- Public API
  - `Sources/Bluetooth/CentralManager.swift`
  - `Sources/Bluetooth/PeripheralManager.swift`
  - `Sources/Bluetooth/PeripheralConnection.swift`
  - `Sources/Bluetooth/BluetoothOptions.swift`
- Backend protocols + factory
  - `Sources/Bluetooth/Internal/Backends/BackendProtocols.swift`
  - `Sources/Bluetooth/Internal/Backends/BackendFactory.swift`
- Backend implementations (stubs today)
  - `Sources/Bluetooth/Backends/CoreBluetooth/`
  - `Sources/Bluetooth/Backends/BlueZ/`
  - `Sources/Bluetooth/Backends/Windows/`

## Backend Selection

### Automatic (conditional compilation)

`Sources/Bluetooth/Internal/Backends/BackendFactory.swift` chooses a backend using:

- `#if canImport(CoreBluetooth)` → CoreBluetooth (Apple platforms)
- `#elseif os(Linux)` → BlueZ (Linux)
- `#elseif os(Windows)` → Windows backend
- `#else` → Unsupported stub

This is the default behavior when no traits are enabled.

### Forcing a backend (SwiftPM traits)

`Package.swift` defines these package traits:

- `backend_corebluetooth`
- `backend_bluez`
- `backend_windows`

When enabled, they set one of these compilation defines on the `Bluetooth` target:

- `BLUETOOTH_BACKEND_FORCE_COREBLUETOOTH`
- `BLUETOOTH_BACKEND_FORCE_BLUEZ`
- `BLUETOOTH_BACKEND_FORCE_WINDOWS`

`_BackendFactory` checks those defines first and falls back to automatic selection if none are enabled.

**Enable traits when building this package directly**

```bash
swift build --traits backend_bluez
```

**Enable traits from a dependent package**

```swift
// In your Package.swift
.package(url: "https://github.com/wendylabsinc/bluetooth.git", from: "0.1.0", traits: ["backend_bluez"])
```

Notes:
- Trait names must be valid Swift identifiers (letters, numbers, underscore; no hyphens).
- Traits are intended to be additive; forcing a backend should not change the public API surface.

## Implementing a Backend

There are three internal protocols:

- `_CentralBackend` (scan + connect)
- `_PeripheralBackend` (advertising + GATT server + L2CAP server)
- `_PeripheralConnectionBackend` (GATT client + L2CAP client + connection lifecycle)

All backends are `actor`s to make it easy to safely bridge callback-based platform APIs into Swift Concurrency.

### Concurrency + Streams

The public API uses `AsyncStream` / `AsyncThrowingStream` for continuous event flows:

- Bluetooth power/state changes: `stateUpdates()`
- Scanning results: `scan(...) -> AsyncThrowingStream<ScanResult, Error>`
- GATT server requests: `gattRequests() -> AsyncThrowingStream<GATTServerRequest, Error>`
- Incoming L2CAP channels: `incomingL2CAPChannels(psm:) -> AsyncThrowingStream<any L2CAPChannel, Error>`
- Connection state: `stateUpdates() -> AsyncStream<PeripheralConnectionState>`

Backend implementations should:

- Yield events on the backend actor (not from random callback threads).
- Implement cancellation by wiring `AsyncStream` / `AsyncThrowingStream` termination handlers to stop native operations (stop scanning, unregister watchers, close sockets, etc.).
- Finish streams when the operation is stopped or the backend is torn down.

### Error model

Public API is stable and backend-specific features should surface as:

- `BluetoothError.notSupported("...")` when the platform cannot do it
- `BluetoothError.invalidState("...")` when called in the wrong state
- regular thrown errors (wrapped/mapped as appropriate) for runtime failures

## Backend Notes

### CoreBluetooth (Apple platforms)

Guard the backend file with:

```swift
#if canImport(CoreBluetooth)
import CoreBluetooth
// ...
#endif
```

Typical mappings:

- Central:
  - `CBCentralManager` → `_CentralBackend`
  - scan: `scanForPeripherals(withServices:options:)` → yield `ScanResult`
  - connect: `connect(_:options:)` → return a `_PeripheralConnectionBackend`
- GATT client:
  - `discoverServices`, `discoverCharacteristics`, `discoverDescriptors`
  - `readValue`, `writeValue`, `setNotifyValue`
- Peripheral:
  - `CBPeripheralManager` → `_PeripheralBackend`
  - advertising: `startAdvertising(_:)` (legacy), extended advertising is newer OS-dependent
  - GATT server: `add(_:)`, handle read/write requests in delegate callbacks
- L2CAP:
  - `openL2CAPChannel(_:)` / `publishL2CAPChannel(withEncryption:)` where available

### BlueZ (Linux)

Guard the backend file with:

```swift
#if os(Linux)
// ...
#endif
```

Typical mappings:

- Discovery / connections / GATT (client + server) are commonly driven via BlueZ D-Bus APIs (`org.bluez`):
  - `Adapter1`, `Device1`
  - `GattService1`, `GattCharacteristic1`, `GattDescriptor1`
  - `LEAdvertisingManager1`, `GattManager1`
- L2CAP LE CoC is often best implemented with Linux `AF_BLUETOOTH` sockets (kernel APIs), with D-Bus used for higher-level device management.

Adapter selection:

- `BluetoothOptions(adapter: BluetoothAdapter("hci1"))`
- or `BLUETOOTH_BLUEZ_ADAPTER=hci1` environment variable

### Windows

Guard the backend file with:

```swift
#if os(Windows)
// ...
#endif
```

Typical mappings:

- WinRT (`Windows.Devices.Bluetooth.*`) is usually the most ergonomic for BLE:
  - scanning: `BluetoothLEAdvertisementWatcher`
  - GATT client: `GattDeviceService`, `GattCharacteristic`, `GattDescriptor`
  - advertising + GATT server: `BluetoothLEAdvertisementPublisher`, `GattServiceProvider`
- L2CAP support may require lower-level Win32 APIs depending on your Windows target and required BLE features.

## Adding a New Backend

1. Add a new folder under `Sources/Bluetooth/Backends/<YourBackend>/`.
2. Implement one or more of `_CentralBackend`, `_PeripheralBackend`, `_PeripheralConnectionBackend` as `actor`s.
3. Add selection logic in `Sources/Bluetooth/Internal/Backends/BackendFactory.swift` (and optionally a new package trait + `SwiftSetting.define` in `Package.swift`).
4. Keep the public API stable; add new capabilities behind existing methods, returning `BluetoothError.notSupported` where appropriate.
