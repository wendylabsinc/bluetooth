import asyncio
import threading
import time
from dataclasses import dataclass
from typing import Callable, Dict, List, Optional

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gdk, GLib, Gtk, Pango  # noqa: E402

from bleak import BleakScanner  # noqa: E402
from bleak.exc import BleakError  # noqa: E402


class BluetoothState:
    UNKNOWN = "unknown"
    READY = "ready"
    DISABLED = "disabled"
    UNSUPPORTED = "unsupported"
    NO_PERMISSION = "no_permission"


@dataclass
class BLEDevice:
    address: str
    name: str
    local_name: Optional[str]
    rssi: int
    service_uuids: List[str]
    tx_power: Optional[int]
    manufacturer_data: Optional[bytes]
    connectable: bool
    discovered_at: float

    @property
    def display_name(self) -> str:
        if self.local_name:
            return self.local_name
        return self.name or "Unknown"

    @property
    def rssi_description(self) -> str:
        if self.rssi >= -50:
            return "Excellent"
        if self.rssi >= -60:
            return "Good"
        if self.rssi >= -70:
            return "Fair"
        return "Weak"

    @property
    def rssi_icon_name(self) -> str:
        if self.rssi >= -50:
            return "network-wireless-signal-excellent-symbolic"
        if self.rssi >= -60:
            return "network-wireless-signal-good-symbolic"
        if self.rssi >= -70:
            return "network-wireless-signal-ok-symbolic"
        if self.rssi >= -80:
            return "network-wireless-signal-weak-symbolic"
        return "network-wireless-signal-none-symbolic"

    @property
    def rssi_color_class(self) -> str:
        if self.rssi >= -50:
            return "rssi-excellent"
        if self.rssi >= -60:
            return "rssi-good"
        if self.rssi >= -70:
            return "rssi-fair"
        return "rssi-weak"

    def matches_fuzzy_search(self, query: str) -> bool:
        if not query:
            return True

        lower_query = query.lower()
        lower_name = self.display_name.lower()

        if lower_query in lower_name:
            return True

        query_index = 0
        for char in lower_name:
            if query_index < len(lower_query) and char == lower_query[query_index]:
                query_index += 1
        if query_index == len(lower_query):
            return True

        for uuid in self.service_uuids:
            if lower_query in uuid.lower():
                return True

        if lower_query in self.address.lower():
            return True

        return False


class AsyncioWorker:
    def __init__(self) -> None:
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self) -> None:
        asyncio.set_event_loop(self.loop)
        self.loop.run_forever()

    def submit(self, coro: asyncio.Future) -> None:
        asyncio.run_coroutine_threadsafe(coro, self.loop)

    def stop(self) -> None:
        self.loop.call_soon_threadsafe(self.loop.stop)


class BLEScanner:
    def __init__(
        self,
        on_device: Callable[[BLEDevice], None],
        on_scan_state: Callable[[bool], None],
        on_error: Callable[[Exception], None],
    ) -> None:
        self.on_device = on_device
        self.on_scan_state = on_scan_state
        self.on_error = on_error
        self.worker = AsyncioWorker()
        self.scanner: Optional[BleakScanner] = None
        self.is_scanning = False

    def start_scan(self) -> None:
        if self.is_scanning:
            return
        self.worker.submit(self._start_scan())

    def stop_scan(self) -> None:
        if not self.is_scanning:
            return
        self.worker.submit(self._stop_scan())

    def toggle_scan(self) -> None:
        if self.is_scanning:
            self.stop_scan()
        else:
            self.start_scan()

    def shutdown(self) -> None:
        self.stop_scan()
        self.worker.stop()

    async def _start_scan(self) -> None:
        try:
            self.scanner = BleakScanner(detection_callback=self._detection_callback)
            await self.scanner.start()
        except Exception as exc:
            self.scanner = None
            GLib.idle_add(self.on_error, exc)
            return

        GLib.idle_add(self._set_scanning, True)

    async def _stop_scan(self) -> None:
        if self.scanner is None:
            return
        try:
            await self.scanner.stop()
        except Exception:
            pass
        self.scanner = None
        GLib.idle_add(self._set_scanning, False)

    def _set_scanning(self, value: bool) -> bool:
        self.is_scanning = value
        self.on_scan_state(value)
        return False

    def _detection_callback(self, device, advertisement_data) -> None:
        name = device.name or ""
        local_name = getattr(advertisement_data, "local_name", None)
        service_uuids = list(getattr(advertisement_data, "service_uuids", []) or [])
        tx_power = getattr(advertisement_data, "tx_power", None)
        connectable = bool(getattr(advertisement_data, "connectable", False))

        manufacturer_data = None
        mfg_dict = getattr(advertisement_data, "manufacturer_data", None)
        if mfg_dict:
            first_key = next(iter(mfg_dict.keys()), None)
            if first_key is not None:
                manufacturer_data = mfg_dict.get(first_key)

        ble_device = BLEDevice(
            address=device.address,
            name=name,
            local_name=local_name,
            rssi=int(getattr(device, "rssi", 0)),
            service_uuids=service_uuids,
            tx_power=tx_power if isinstance(tx_power, int) else None,
            manufacturer_data=manufacturer_data,
            connectable=connectable,
            discovered_at=time.time(),
        )

        GLib.idle_add(self.on_device, ble_device)


class DeviceRow(Gtk.ListBoxRow):
    def __init__(self, device: BLEDevice) -> None:
        super().__init__()
        self.device = device

        container = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        container.set_margin_start(12)
        container.set_margin_end(12)
        container.set_margin_top(8)
        container.set_margin_bottom(8)

        self.rssi_badge = Gtk.Box()
        self.rssi_badge.add_css_class("rssi-badge")
        self.rssi_icon = Gtk.Image.new_from_icon_name(device.rssi_icon_name)
        self.rssi_icon.add_css_class("rssi-icon")
        self.rssi_badge.append(self.rssi_icon)
        container.append(self.rssi_badge)

        info_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        info_box.set_hexpand(True)

        name_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        self.name_label = Gtk.Label(label=device.display_name, xalign=0)
        self.name_label.add_css_class("title-3")
        self.name_label.set_ellipsize(Pango.EllipsizeMode.END)
        self.connectable_icon = Gtk.Image.new_from_icon_name("insert-link-symbolic")
        self.connectable_icon.set_visible(device.connectable)
        name_box.append(self.name_label)
        name_box.append(self.connectable_icon)
        info_box.append(name_box)

        self.service_label = Gtk.Label(label="", xalign=0)
        self.service_label.add_css_class("dim-label")
        self.service_label.set_ellipsize(Pango.EllipsizeMode.END)
        info_box.append(self.service_label)

        self.meta_label = Gtk.Label(label="", xalign=0)
        self.meta_label.add_css_class("dim-label")
        info_box.append(self.meta_label)

        container.append(info_box)

        rssi_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        rssi_box.set_halign(Gtk.Align.END)

        self.rssi_value_label = Gtk.Label(label=str(device.rssi), xalign=1)
        self.rssi_value_label.add_css_class("rssi-value")
        self.rssi_desc_label = Gtk.Label(label=device.rssi_description, xalign=1)
        self.rssi_desc_label.add_css_class("dim-label")
        rssi_box.append(self.rssi_value_label)
        rssi_box.append(self.rssi_desc_label)

        container.append(rssi_box)
        self.set_child(container)

        self.update(device)

    def update(self, device: BLEDevice) -> None:
        self.device = device
        self.name_label.set_label(device.display_name)
        self.connectable_icon.set_visible(device.connectable)

        uuid_text = ", ".join([uuid[:8] for uuid in device.service_uuids])
        self.service_label.set_label(uuid_text)
        self.service_label.set_visible(bool(uuid_text))

        meta_parts = [f"RSSI: {device.rssi} dBm"]
        if device.tx_power is not None:
            meta_parts.append(f"TX: {device.tx_power}")
        if device.manufacturer_data is not None:
            meta_parts.append("MFG")
        self.meta_label.set_label("  ".join(meta_parts))

        self.rssi_value_label.set_label(str(device.rssi))
        self.rssi_desc_label.set_label(device.rssi_description)
        self.rssi_icon.set_from_icon_name(device.rssi_icon_name)

        for css_class in ["rssi-excellent", "rssi-good", "rssi-fair", "rssi-weak"]:
            self.rssi_badge.remove_css_class(css_class)
            self.rssi_value_label.remove_css_class(css_class)
            self.rssi_icon.remove_css_class(css_class)
        self.rssi_badge.add_css_class(device.rssi_color_class)
        self.rssi_value_label.add_css_class(device.rssi_color_class)
        self.rssi_icon.add_css_class(device.rssi_color_class)


class CompanionWindow(Gtk.ApplicationWindow):
    def __init__(self, app: Gtk.Application) -> None:
        super().__init__(application=app)
        self.set_title("BLE Devices")
        self.set_default_size(900, 640)

        self.devices: Dict[str, BLEDevice] = {}
        self.device_rows: Dict[str, DeviceRow] = {}
        self.search_text = ""
        self.bluetooth_state = BluetoothState.UNKNOWN
        self.is_scanning = False
        self.refresh_source: Optional[int] = None

        self.scanner = BLEScanner(
            on_device=self.on_device,
            on_scan_state=self.on_scan_state,
            on_error=self.on_scan_error,
        )

        self.set_titlebar(self._build_header())
        self.set_child(self._build_layout())
        self._apply_css()

        self.connect("close-request", self.on_close_request)
        GLib.idle_add(self.start_scanning)

    def _build_header(self) -> Gtk.HeaderBar:
        header = Gtk.HeaderBar()
        header.set_show_title_buttons(True)

        self.scan_button = Gtk.Button(label="Scan")
        self.scan_button.set_icon_name("network-wireless-signal-excellent-symbolic")
        self.scan_button.connect("clicked", lambda _btn: self.toggle_scanning())
        header.pack_end(self.scan_button)

        self.clear_button = Gtk.Button(label="Clear")
        self.clear_button.set_icon_name("user-trash-symbolic")
        self.clear_button.connect("clicked", lambda _btn: self.clear_devices())
        header.pack_end(self.clear_button)

        return header

    def _build_layout(self) -> Gtk.Widget:
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        root.set_margin_start(12)
        root.set_margin_end(12)
        root.set_margin_top(12)
        root.set_margin_bottom(12)

        self.search_entry = Gtk.SearchEntry()
        self.search_entry.set_placeholder_text("Search devices...")
        self.search_entry.connect("search-changed", self.on_search_changed)
        root.append(self.search_entry)

        self.stack = Gtk.Stack()
        self.stack.set_vexpand(True)

        self.stack.add_named(self._build_unavailable_view(), "unavailable")
        self.stack.add_named(self._build_empty_view(), "empty")
        self.stack.add_named(self._build_list_view(), "list")

        root.append(self.stack)
        return root

    def _build_unavailable_view(self) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        box.set_valign(Gtk.Align.CENTER)
        box.set_halign(Gtk.Align.CENTER)

        self.unavailable_icon = Gtk.Image.new_from_icon_name(
            "bluetooth-disabled-symbolic"
        )
        self.unavailable_icon.set_pixel_size(64)
        box.append(self.unavailable_icon)

        self.unavailable_title = Gtk.Label(label="Bluetooth Unavailable")
        self.unavailable_title.add_css_class("title-2")
        box.append(self.unavailable_title)

        self.unavailable_message = Gtk.Label(
            label="Please enable Bluetooth to scan for devices."
        )
        self.unavailable_message.set_wrap(True)
        self.unavailable_message.set_justify(Gtk.Justification.CENTER)
        self.unavailable_message.add_css_class("dim-label")
        box.append(self.unavailable_message)

        return box

    def _build_empty_view(self) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        box.set_valign(Gtk.Align.CENTER)
        box.set_halign(Gtk.Align.CENTER)

        icon = Gtk.Image.new_from_icon_name("network-wireless-signal-excellent-symbolic")
        icon.set_pixel_size(64)
        box.append(icon)

        title = Gtk.Label(label="No Devices")
        title.add_css_class("title-2")
        box.append(title)

        message = Gtk.Label(label="Start scanning to discover nearby BLE devices.")
        message.add_css_class("dim-label")
        box.append(message)

        action = Gtk.Button(label="Start Scanning")
        action.add_css_class("suggested-action")
        action.connect("clicked", lambda _btn: self.start_scanning())
        box.append(action)

        return box

    def _build_list_view(self) -> Gtk.Widget:
        container = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)

        self.scanning_revealer = Gtk.Revealer()
        self.scanning_revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_DOWN)
        scanning_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        scanning_box.set_margin_top(8)
        scanning_box.set_margin_bottom(8)
        spinner = Gtk.Spinner()
        spinner.start()
        scanning_box.append(spinner)
        scanning_box.append(Gtk.Label(label="Scanning for devices..."))
        self.scanning_revealer.set_child(scanning_box)
        container.append(self.scanning_revealer)

        self.count_label = Gtk.Label(label="")
        self.count_label.add_css_class("dim-label")
        self.count_label.set_halign(Gtk.Align.START)
        container.append(self.count_label)

        self.list_box = Gtk.ListBox()
        self.list_box.set_selection_mode(Gtk.SelectionMode.NONE)

        scroller = Gtk.ScrolledWindow()
        scroller.set_hexpand(True)
        scroller.set_vexpand(True)
        scroller.set_child(self.list_box)

        container.append(scroller)
        return container

    def _apply_css(self) -> None:
        css = """
        .title-2 {
            font-size: 22px;
            font-weight: 600;
        }
        .title-3 {
            font-size: 16px;
            font-weight: 600;
        }
        .dim-label {
            color: @theme_unfocused_fg_color;
        }
        .rssi-badge {
            border-radius: 999px;
            min-width: 44px;
            min-height: 44px;
            padding: 10px;
        }
        .rssi-value {
            font-weight: 600;
        }
        .rssi-icon {
            font-size: 20px;
        }
        .rssi-excellent {
            color: #4caf50;
            background-color: rgba(76, 175, 80, 0.15);
        }
        .rssi-good {
            color: #2196f3;
            background-color: rgba(33, 150, 243, 0.15);
        }
        .rssi-fair {
            color: #ff9800;
            background-color: rgba(255, 152, 0, 0.15);
        }
        .rssi-weak {
            color: #f44336;
            background-color: rgba(244, 67, 54, 0.15);
        }
        """
        provider = Gtk.CssProvider()
        provider.load_from_data(css.encode("utf-8"))
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

    def on_close_request(self, *_args) -> bool:
        self.scanner.shutdown()
        return False

    def on_search_changed(self, entry: Gtk.SearchEntry) -> None:
        self.search_text = entry.get_text().strip()
        self.schedule_refresh()

    def on_device(self, device: BLEDevice) -> bool:
        self.devices[device.address] = device
        self.schedule_refresh()
        return False

    def on_scan_state(self, scanning: bool) -> None:
        self.is_scanning = scanning
        if scanning:
            self.bluetooth_state = BluetoothState.READY
        self.update_scan_button()
        self.update_view()

    def on_scan_error(self, error: Exception) -> bool:
        message = str(error)
        if isinstance(error, BleakError):
            message = str(error)

        if "Permission" in message or "NotAuthorized" in message:
            self.bluetooth_state = BluetoothState.NO_PERMISSION
        elif "NotReady" in message or "NotPowered" in message:
            self.bluetooth_state = BluetoothState.DISABLED
        elif "No adapter" in message or "NotSupported" in message:
            self.bluetooth_state = BluetoothState.UNSUPPORTED
        else:
            self.bluetooth_state = BluetoothState.UNKNOWN

        self.is_scanning = False
        self.update_scan_button()
        self.update_view()
        return False

    def start_scanning(self) -> None:
        if self.bluetooth_state in (BluetoothState.UNSUPPORTED, BluetoothState.NO_PERMISSION):
            return
        self.devices.clear()
        self.schedule_refresh()
        self.scanner.start_scan()

    def stop_scanning(self) -> None:
        self.scanner.stop_scan()

    def toggle_scanning(self) -> None:
        if self.is_scanning:
            self.stop_scanning()
        else:
            self.start_scanning()

    def clear_devices(self) -> None:
        self.devices.clear()
        self.device_rows.clear()
        self.schedule_refresh()

    def update_scan_button(self) -> None:
        if self.is_scanning:
            self.scan_button.set_label("Stop")
            self.scan_button.set_icon_name("media-playback-stop-symbolic")
        else:
            self.scan_button.set_label("Scan")
            self.scan_button.set_icon_name("network-wireless-signal-excellent-symbolic")

    def schedule_refresh(self) -> None:
        if self.refresh_source is None:
            self.refresh_source = GLib.timeout_add(200, self.refresh_list)

    def refresh_list(self) -> bool:
        self.refresh_source = None
        self.update_view()
        if self.stack.get_visible_child_name() != "list":
            return False

        child = self.list_box.get_first_child()
        while child is not None:
            next_child = child.get_next_sibling()
            self.list_box.remove(child)
            child = next_child

        filtered = [
            device
            for device in self.devices.values()
            if device.matches_fuzzy_search(self.search_text)
        ]
        filtered.sort(key=lambda device: device.rssi, reverse=True)

        if not filtered and self.search_text:
            row = Gtk.ListBoxRow()
            label = Gtk.Label(
                label=f"No results for \"{self.search_text}\"",
                xalign=0.0,
            )
            label.set_margin_start(12)
            label.set_margin_top(12)
            label.set_margin_bottom(12)
            row.set_child(label)
            self.list_box.append(row)
        else:
            for device in filtered:
                row = self.device_rows.get(device.address)
                if row is None:
                    row = DeviceRow(device)
                    self.device_rows[device.address] = row
                else:
                    row.update(device)
                self.list_box.append(row)

        count = len(filtered)
        if count:
            self.count_label.set_label(f"{count} device{'s' if count != 1 else ''} found")
        else:
            self.count_label.set_label("")

        return False

    def update_view(self) -> None:
        if self.bluetooth_state in (
            BluetoothState.DISABLED,
            BluetoothState.UNSUPPORTED,
            BluetoothState.NO_PERMISSION,
        ):
            self.stack.set_visible_child_name("unavailable")
            self.update_unavailable_view()
        elif not self.devices and not self.is_scanning:
            self.stack.set_visible_child_name("empty")
        else:
            self.stack.set_visible_child_name("list")

        self.scanning_revealer.set_reveal_child(self.is_scanning)

    def update_unavailable_view(self) -> None:
        if self.bluetooth_state == BluetoothState.NO_PERMISSION:
            self.unavailable_title.set_label("Bluetooth Permission Required")
            self.unavailable_message.set_label(
                "Make sure your user has Bluetooth access and try again."
            )
        elif self.bluetooth_state == BluetoothState.UNSUPPORTED:
            self.unavailable_title.set_label("Bluetooth Unsupported")
            self.unavailable_message.set_label(
                "This system does not appear to support Bluetooth LE."
            )
        else:
            self.unavailable_title.set_label("Bluetooth Disabled")
            self.unavailable_message.set_label(
                "Bluetooth is powered off or unavailable. Enable it and retry."
            )


class CompanionApp(Gtk.Application):
    def __init__(self) -> None:
        super().__init__(application_id="sh.wendy.bluetoothcompanionapp.linux")

    def do_activate(self) -> None:
        window = CompanionWindow(self)
        window.present()


def main() -> None:
    app = CompanionApp()
    app.run(None)


if __name__ == "__main__":
    main()
