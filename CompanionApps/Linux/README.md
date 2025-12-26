# Bluetooth Companion App (Linux)

This desktop app mirrors the Apple companion app: it scans for nearby BLE devices, shows signal strength and metadata, supports fuzzy search, and lets you start/stop scanning or clear results.

## Features

- Live BLE scan with start/stop toggle
- Fuzzy search (name, UUIDs, address)
- RSSI strength + quality label
- Connectable indicator
- Service UUID list, TX power, manufacturer marker
- Empty state + Bluetooth unavailable state

## Requirements

- Linux with BlueZ (`bluetoothd` running)
- Python 3.10+
- GTK 4 + PyGObject
- `bleak` (installed via `uv`)

On Ubuntu/Kubuntu:

```bash
sudo apt-get install -y libcairo2-dev libgirepository-2.0-dev libgtk-4-dev gir1.2-gtk-4.0
```

On Fedora:

```bash
sudo dnf install -y cairo-devel gobject-introspection-devel gtk4-devel
```

On Arch:

```bash
sudo pacman -S cairo gobject-introspection gtk4
```

## Run (with uv)

Install `uv` if you don't already have it: https://astral.sh/uv

```bash
uv venv .venv
uv pip install -r requirements.txt
uv run -- python bluetooth_companion_app.py
```

## Troubleshooting

- If Bluetooth is powered off:
  - `bluetoothctl power on`
- If no adapter is found:
  - Check `bluetoothctl list` and confirm your adapter is present.
