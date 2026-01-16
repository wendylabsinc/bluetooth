import ArgumentParser
import Bluetooth
import Dispatch
import Foundation

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
struct L2CAPExample: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bluetooth-l2cap-example",
        abstract: "Advertise and host a simple L2CAP echo channel using the Bluetooth package."
    )

    @Option(name: .long, help: "Milliseconds to advertise before exiting.")
    var time: UInt64?

    @Option(name: .long, help: "Local name to advertise.")
    var name: String = "wendylabsinc/bluetooth-l2cap-example"

    @Flag(inversion: .prefixedNo, help: "Advertise as connectable (required for L2CAP).")
    var connectable: Bool = true

    @Option(name: .long, help: "Bluetooth adapter (e.g. hci0).")
    var adapter: String?

    mutating func run() async throws {
        let options = BluetoothOptions(adapter: adapter.map(BluetoothAdapter.init))
        let manager = PeripheralManager(options: options)
        let parameters = AdvertisingParameters(isConnectable: connectable, isScannable: connectable)

        if !connectable {
            print("Warning: advertising as non-connectable; L2CAP clients will not be able to connect.")
        }

        print("Publishing L2CAP channel...")
        let psm: L2CAPPSM
        do {
            psm = try await manager.publishL2CAPChannel()
        } catch {
            print("Failed to publish L2CAP channel: \(error)")
            throw ExitCode.failure
        }

        print("L2CAP PSM: 0x\(String(psm.rawValue, radix: 16, uppercase: true))")

        let channelTask: Task<Void, Never>
        do {
            let incoming = try await manager.incomingL2CAPChannels(psm: psm)
            channelTask = Task { await Self.handleIncomingChannels(incoming) }
        } catch {
            print("Failed to open incoming L2CAP channel stream: \(error)")
            throw ExitCode.failure
        }

        let advertisingData = AdvertisementData(localName: name)
        print("Starting L2CAP advertising as \"\(name)\"")
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
        channelTask.cancel()
        print("Stopped.")
    }

    private static func handleIncomingChannels(
        _ incoming: AsyncThrowingStream<any L2CAPChannel, Error>
    ) async {
        do {
            for try await channel in incoming {
                if Task.isCancelled {
                    break
                }
                Task {
                    await handle(channel)
                }
            }
        } catch {
            if !Task.isCancelled {
                print("L2CAP incoming stream error: \(error)")
            }
        }
    }

    private static func handle(_ channel: any L2CAPChannel) async {
        print("L2CAP channel opened (PSM 0x\(String(channel.psm.rawValue, radix: 16, uppercase: true)))")
        do {
            for try await data in channel.incoming() {
                if Task.isCancelled {
                    break
                }
                let message = describe(data)
                print("Received: \(message)")
                do {
                    try await channel.send(data)
                } catch {
                    print("Send failed: \(error)")
                }
            }
        } catch {
            if !Task.isCancelled {
                print("Channel receive error: \(error)")
            }
        }
        await channel.close()
    }

    private static func describe(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        return data.map { byte in
            let hex = String(byte, radix: 16, uppercase: true)
            return hex.count == 1 ? "0\(hex)" : hex
        }.joined(separator: " ")
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
