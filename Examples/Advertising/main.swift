import ArgumentParser
import Bluetooth
import Dispatch

#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#elseif os(Windows)
// Windows doesn't provide Darwin/Glibc.
#else
import Darwin
#endif

@main
struct AdvertisingExample: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bluetooth-advertising-example",
        abstract: "Advertise a BLE local name using the Bluetooth package."
    )

    @Option(name: .long, help: "Milliseconds to advertise before exiting.")
    var time: UInt64?

    @Option(name: .long, help: "Local name to advertise.")
    var name: String = "wendylabsinc/bluetooth-advertising-example"

    @Flag(name: .long, help: "Advertise as connectable (may trigger pairing prompts).")
    var connectable: Bool = false

    @Option(name: .long, help: "Bluetooth adapter (e.g. hci0).")
    var adapter: String?

    mutating func run() async throws {
        let options = BluetoothOptions(adapter: adapter.map(BluetoothAdapter.init))
        let manager = PeripheralManager(options: options)
        let advertisingData = AdvertisementData(localName: name)

        if name.count > 26 {
            print("Warning: local name is long; legacy BLE advertising may truncate it.")
        }

        let parameters = AdvertisingParameters(
            isConnectable: connectable,
            isScannable: connectable
        )
        let connectableLabel = connectable ? "connectable" : "non-connectable"
        print("Starting BLE advertising (\(connectableLabel)) as \"\(name)\"")
        try await manager.startAdvertising(advertisingData: advertisingData, parameters: parameters)

        if let time {
            print("Advertising for \(time) ms...")
            try await Task.sleep(nanoseconds: time * 1_000_000)
        } else {
            print("Advertising... press Ctrl+C to stop.")
            await waitForInterrupt()
        }

        print("Stopping advertising...")
        await manager.stopAdvertising()
        print("Stopped.")
    }

    private func waitForInterrupt() async {
        #if os(Windows)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        }
        #else
        await withCheckedContinuation { continuation in
            let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            signal(SIGINT, SIG_IGN)
            signalSource.setEventHandler {
                signalSource.cancel()
                continuation.resume()
            }
            signalSource.resume()
        }
        #endif
    }
}
