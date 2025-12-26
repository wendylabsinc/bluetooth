[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%20|%20macOS%20|%20tvOS%20|%20watchOS%20|%20visionOS%20|%20Linux%20|%20Windows-blue.svg)](https://swift.org)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)
[![macOS](https://img.shields.io/github/actions/workflow/status/wendylabsinc/bluetooth/swift.yml?branch=main&label=macOS)](https://github.com/wendylabsinc/bluetooth/actions/workflows/swift.yml)
[![Linux](https://img.shields.io/github/actions/workflow/status/wendylabsinc/bluetooth/swift.yml?branch=main&label=Linux)](https://github.com/wendylabsinc/bluetooth/actions/workflows/swift.yml)
[![Windows](https://img.shields.io/github/actions/workflow/status/wendylabsinc/bluetooth/swift.yml?branch=main&label=Windows)](https://github.com/wendylabsinc/bluetooth/actions/workflows/swift.yml)
[![Documentation](https://img.shields.io/badge/Documentation-DocC-blue)](https://swiftpackageindex.com/wendylabsinc/bluetooth/documentation)

# Bluetooth

Cross-platform Bluetooth Low Energy (BLE) Swift package.

**Targets**
- Apple platforms: CoreBluetooth backend (iOS 26, macOS 26, tvOS 26, watchOS 26, visionOS 26)
- Linux: BlueZ backend (advertising + discovery + central connection + GATT client + GATT server registration/requests/update + L2CAP CoC)
- Windows: Windows backend (planned)

This repository currently contains **API and project layout scaffolding** for:
- Advertising (legacy + extended advertising set configuration)
- Discovery (scan parameters/filters + scan results)
- GATT (service/characteristic models + client/server API shape)
- L2CAP (PSM/channel abstractions)

Backends are selected via conditional compilation (`canImport(CoreBluetooth)`, `os(Linux)`, `os(Windows)`). Most backends are currently stubbed with `BluetoothError.unimplemented(...)`.

See `BACKEND_IMPLEMENTATION_GUIDE.md` for how to implement and select a backend (including optional SwiftPM traits).

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/wendylabsinc/bluetooth.git", from: "0.0.2")
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "Bluetooth", package: "bluetooth")
        ]
    )
]
```

## Linux Requirements

The Linux backend uses BlueZ over D-Bus.

- BlueZ (includes `bluetoothd`)
- D-Bus (system bus) with the Bluetooth service running
- A user with permissions to access Bluetooth (often the `bluetooth` group)

Ubuntu/Debian:

```bash
sudo apt install bluez
sudo systemctl enable --now bluetooth
```

Optional for debugging (requires root): `btmon` for sniffing HCI traffic.

`btmon` listens at the HCI layer and can confirm that advertising commands were issued and that packets are going out. It needs root or the appropriate capabilities (`CAP_NET_ADMIN`), for example:

```bash
sudo btmon
```

Common filters while advertising:

```bash
sudo btmon | rg -i "LE Set Advertising|LE Advertising Report|Advertising"
```

Note: most controllers do not loop back their own advertisements, so a local scan on the same adapter may not show your own packets even when advertising is active.

## Usage

Advertising a local name:

```swift
import Bluetooth

@main
struct Demo {
    static func main() async throws {
        let manager = PeripheralManager()
        let data = AdvertisementData(localName: "wendyble")
        let params = AdvertisingParameters(isConnectable: false, isScannable: false)
        try await manager.startAdvertising(advertisingData: data, parameters: params)
        try await Task.sleep(nanoseconds: 5_000_000_000)
        await manager.stopAdvertising()
    }
}
```

GATT server (Linux BlueZ backend supported; other backends pending):

```swift
import Bluetooth

let manager = PeripheralManager()
let service = GATTServiceDefinition(
    uuid: .bit16(0x180A),
    characteristics: [
        GATTCharacteristicDefinition(
            uuid: .bit16(0x2A29),
            properties: [.read, .notify],
            permissions: [.readable],
            initialValue: Data("wendylabsinc".utf8)
        )
    ]
)

_ = try await manager.addService(service)
let requests = try await manager.gattRequests()

for try await request in requests {
    switch request {
    case .read(let read):
        await read.respond(.success(Data("wendylabsinc".utf8)))
    case .write(let write):
        await write.respond(.failure(.att(.writeNotPermitted)))
    default:
        break
    }
}
```

Use `removeService(_:)` to unregister a service when you no longer need it.

L2CAP server (Linux BlueZ backend supported; Windows pending):

```swift
import Bluetooth

let manager = PeripheralManager()
let psm = try await manager.publishL2CAPChannel()
let incoming = try await manager.incomingL2CAPChannels(psm: psm)

for try await channel in incoming {
    for try await data in channel.incoming() {
        try await channel.send(data) // echo
    }
}
```

L2CAP client (Linux BlueZ backend supported):

```swift
import Bluetooth

let manager = CentralManager()
let peripheral = Peripheral(id: .address(BluetoothAddress("AA:BB:CC:DD:EE:FF")))
let connection = try await manager.connect(to: peripheral)
let channel = try await connection.openL2CAPChannel(psm: L2CAPPSM(rawValue: 0x0080))

try await channel.send(Data("hello".utf8))
for try await data in channel.incoming() {
    print("Received: \(data)")
}
```

## Examples

Run the advertising example:

```bash
swift run BluetoothAdvertisingExample --name wendyble --verbose
```

Run the discovery example:

```bash
swift run BluetoothDiscoveryExample --time 10000 --verbose
```

Run the GATT example (Linux BlueZ backend supported):

```bash
swift run BluetoothGATTExample --verbose
```

Run the L2CAP example (Linux BlueZ backend supported):

```bash
swift run BluetoothL2CAPExample --verbose
```

Run the L2CAP client example (requires a known address + PSM):

```bash
swift run BluetoothL2CAPClientExample --address AA:BB:CC:DD:EE:FF --psm 0x0080 --verbose
```

Run the central pairing example (Linux BlueZ backend supported):

```bash
swift run BluetoothCentralPairingExample --address AA:BB:CC:DD:EE:FF --verbose
```

Optional flags:

- `--connectable` to advertise as connectable (may trigger pairing prompts)
- `--time <ms>` to exit after a duration (advertising/discovery)
- `--uuid <uuid>` to filter discovery by a service UUID (repeatable)
- `--name-prefix <prefix>` to filter discovery by local name prefix
- `--duplicates` to allow duplicate discovery results
- `--adapter <name>` to select a BlueZ adapter (for example `hci1`)
- `--verbose` to show BlueZ output

## Companion Apps

Use the companion apps to test BLE functionality from a mobile device or desktop:

- **Apple** (`CompanionApps/Apple/`): iOS, macOS, tvOS, watchOS, visionOS
  - Open `BluetoothCompanionApp.xcodeproj` in Xcode and run on your target device
- **Android** (`CompanionApps/Android/`): Android 12+ (API 31+)
  - Open in Android Studio and run on your device or emulator

Both apps provide BLE scanning and device discovery for testing against the library examples.

## Adapter Selection (Linux BlueZ)

Select a specific adapter by name:

```swift
let options = BluetoothOptions(adapter: BluetoothAdapter("hci1"))
let central = CentralManager(options: options)
let peripheral = PeripheralManager(options: options)
```

Or use an environment variable:

```bash
export BLUETOOTH_BLUEZ_ADAPTER=hci1
```

## Pairing (Linux BlueZ)

The Linux backend uses a BlueZ Agent to handle pairing and authorization prompts.
You can configure the agent using environment variables:

- `BLUETOOTH_BLUEZ_AGENT_CAPABILITY` (default `NoInputNoOutput`)
  - Supported values: `DisplayOnly`, `DisplayYesNo`, `KeyboardOnly`, `NoInputNoOutput`, `KeyboardDisplay`, `External`
- `BLUETOOTH_BLUEZ_AGENT_PIN` (string PIN to return for `RequestPinCode`)
- `BLUETOOTH_BLUEZ_AGENT_PASSKEY` (numeric passkey for `RequestPasskey`)
- `BLUETOOTH_BLUEZ_AGENT_AUTO_ACCEPT` (default `true`; set to `false` to reject confirmations/authorizations)

Example:

```bash
export BLUETOOTH_BLUEZ_AGENT_CAPABILITY=DisplayYesNo
export BLUETOOTH_BLUEZ_AGENT_AUTO_ACCEPT=false
swift run BluetoothGATTExample --verbose
```

Programmatic pairing handling (peripheral + central roles):

- Peripheral role: `PeripheralManager().pairingRequests()`
- Central role: `CentralManager().pairingRequests()`
- Requests include `central` or `peripheral` depending on the local role.

```swift
let manager = PeripheralManager()
let requests = try await manager.pairingRequests()

Task {
    for try await request in requests {
        switch request {
        case .confirmation(let confirmation):
            await confirmation.respond(true)
        case .authorization(let authorization):
            await authorization.respond(true)
        case .serviceAuthorization(let service):
            await service.respond(true)
        case .pinCode(let pin):
            await pin.respond("0000")
        case .passkey(let passkey):
            await passkey.respond(123456)
        case .displayPinCode(let display):
            print("PIN: \(display.pinCode)")
        case .displayPasskey(let display):
            print("Passkey: \(display.passkey)")
        }
    }
}
```

Remove bonding (Linux BlueZ):

```swift
let centralManager = CentralManager()
try await centralManager.removeBond(for: peripheral)

let peripheralManager = PeripheralManager()
try await peripheralManager.removeBond(for: central)
```

## Connection Tuning (API Surface)

The API includes connection parameter + PHY update calls, but Linux BlueZ support is not yet implemented:

```swift
try await connection.updateConnectionParameters(
    ConnectionParameters(minIntervalMs: 15, maxIntervalMs: 30, latency: 0, supervisionTimeoutMs: 2000)
)
try await connection.updatePHY(PHYPreference(tx: .le2M, rx: .le2M))
```
