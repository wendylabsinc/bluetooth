#if os(Linux)
#if canImport(FoundationEssentials)
import FoundationEssentials
import Foundation
#else
import Foundation
#endif

struct BlueZAdapterSelection: Sendable {
    let name: String
    let path: String

    init(options: BluetoothOptions) {
        let env = ProcessInfo.processInfo.environment["BLUETOOTH_BLUEZ_ADAPTER"]
        let raw = options.adapter?.identifier ?? env ?? "hci0"
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            self.name = "hci0"
            self.path = "/org/bluez/hci0"
            return
        }
        if trimmed.hasPrefix("/org/bluez/") {
            self.path = trimmed
            let parts = trimmed.split(separator: "/")
            self.name = parts.last.map(String.init) ?? "hci0"
            return
        }

        let resolved: String
        if trimmed.allSatisfy({ $0.isNumber }) {
            resolved = "hci\(trimmed)"
        } else {
            resolved = trimmed
        }

        self.name = resolved
        self.path = "/org/bluez/\(resolved)"
    }
}

#endif
