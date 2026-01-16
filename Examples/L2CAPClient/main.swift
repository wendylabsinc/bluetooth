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
struct L2CAPClientExample: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bluetooth-l2cap-client-example",
        abstract: "Connect to a peripheral and open an L2CAP CoC channel."
    )

    @Option(name: .long, help: "Peripheral Bluetooth address (e.g. AA:BB:CC:DD:EE:FF).")
    var address: String

    @Option(name: .long, help: "L2CAP PSM (decimal or 0x-prefixed hex).")
    var psm: String

    @Option(name: .long, help: "Message to send after connecting.")
    var message: String = "hello from bluetooth-l2cap-client-example"

    @Option(name: .long, help: "Milliseconds to stay connected before exiting.")
    var time: UInt64?

    @Option(name: .long, help: "Bluetooth adapter (e.g. hci0).")
    var adapter: String?

    mutating func run() async throws {
        let parsedPSM = try parsePSM(psm)
        let options = BluetoothOptions(adapter: adapter.map(BluetoothAdapter.init))
        let manager = CentralManager(options: options)
        let peripheral = Peripheral(id: .address(BluetoothAddress(address)))

        print("Connecting to \(address)...")
        let connection: PeripheralConnection
        do {
            connection = try await manager.connect(to: peripheral)
        } catch {
            print("Failed to connect: \(error)")
            throw ExitCode.failure
        }

        let channel: any L2CAPChannel
        do {
            channel = try await connection.openL2CAPChannel(psm: parsedPSM)
        } catch {
            print("Failed to open L2CAP channel: \(error)")
            await connection.disconnect()
            throw ExitCode.failure
        }

        print("L2CAP channel opened (PSM 0x\(String(parsedPSM.rawValue, radix: 16, uppercase: true)))")
        print("Outgoing MTU: \(channel.mtu)")

        if !message.isEmpty {
            do {
                try await channel.send(Data(message.utf8))
                print("Sent: \(message)")
            } catch {
                print("Send failed: \(error)")
            }
        }

        let receiveTask = Task {
            do {
                for try await data in channel.incoming() {
                    if Task.isCancelled {
                        break
                    }
                    print("Received: \(Self.describe(data))")
                }
            } catch {
                if !Task.isCancelled {
                    print("Receive error: \(error)")
                }
            }
        }

        if let time {
            print("Connected for \(time) ms...")
            try await Task.sleep(nanoseconds: time * 1_000_000)
        } else {
            print("Connected... press Ctrl+C to stop.")
            await Self.waitForInterrupt()
        }

        receiveTask.cancel()
        await channel.close()
        await connection.disconnect()
        print("Disconnected.")
    }

    private func parsePSM(_ value: String) throws -> L2CAPPSM {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parsed: UInt16?
        if trimmed.hasPrefix("0x") {
            parsed = UInt16(trimmed.dropFirst(2), radix: 16)
        } else if trimmed.contains(where: { $0.isLetter }) {
            parsed = UInt16(trimmed, radix: 16)
        } else {
            parsed = UInt16(trimmed, radix: 10)
        }

        guard let psmValue = parsed else {
            throw ValidationError("Invalid PSM value: \(value)")
        }
        return L2CAPPSM(rawValue: psmValue)
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

    private static func waitForInterrupt() async {
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
