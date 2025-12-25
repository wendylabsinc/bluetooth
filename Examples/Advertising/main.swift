import ArgumentParser
import Bluetooth
import Dispatch

#if os(Linux)
import Glibc
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

    @Flag(name: .long, help: "Enable BlueZ backend verbose logging.")
    var verbose: Bool = false

    @Flag(name: .long, help: "Advertise as connectable (may trigger pairing prompts).")
    var connectable: Bool = false

    mutating func run() async throws {
        if verbose {
            setenv("BLUETOOTH_BLUEZ_VERBOSE", "1", 1)
        }

        let manager = PeripheralManager()
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
        await withCheckedContinuation { continuation in
            let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            signal(SIGINT, SIG_IGN)
            signalSource.setEventHandler {
                signalSource.cancel()
                continuation.resume()
            }
            signalSource.resume()
        }
    }
}
