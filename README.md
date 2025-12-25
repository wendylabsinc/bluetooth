# Bluetooth

Cross-platform Bluetooth Low Energy (BLE) Swift package.

**Targets**
- Apple platforms: CoreBluetooth backend (iOS 26, macOS 26, tvOS 26, watchOS 26, visionOS 26)
- Linux: BlueZ backend (planned)
- Windows: Windows backend (planned)

This repository currently contains **API and project layout scaffolding** for:
- Advertising (legacy + extended advertising set configuration)
- Discovery (scan parameters/filters + scan results)
- GATT (service/characteristic models + client/server API shape)
- L2CAP (PSM/channel abstractions)

Backends are selected via conditional compilation (`canImport(CoreBluetooth)`, `os(Linux)`, `os(Windows)`) and are currently stubbed with `BluetoothError.unimplemented(...)`.

See `BACKEND_IMPLEMENTATION_GUIDE.md` for how to implement and select a backend (including optional SwiftPM traits).
