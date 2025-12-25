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
- Linux: BlueZ backend (advertising implemented; scan/GATT/L2CAP pending)
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

The Linux backend uses BlueZ and `bluetoothctl`.

- BlueZ (includes `bluetoothd` and `bluetoothctl`)
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

GATT server (API shape; backend support pending on Linux/Windows):

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

## Examples

Run the advertising example:

```bash
swift run BluetoothAdvertisingExample --name wendyble --verbose
```

Run the GATT example (requires backend support for GATT server):

```bash
swift run BluetoothGATTExample --verbose
```

Optional flags:

- `--connectable` to advertise as connectable (may trigger pairing prompts)
- `--time <ms>` to exit after a duration
- `--verbose` to show BlueZ output
