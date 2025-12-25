import ArgumentParser
import Bluetooth
import Dispatch
import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

@main
struct GATTExample: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bluetooth-gatt-example",
        abstract: "Advertise and host a simple GATT service using the Bluetooth package."
    )

    @Option(name: .long, help: "Milliseconds to advertise before exiting.")
    var time: UInt64?

    @Option(name: .long, help: "Local name to advertise.")
    var name: String = "wendylabsinc/bluetooth-gatt-example"

    @Flag(inversion: .prefixedNo, help: "Advertise as connectable (required for GATT connections).")
    var connectable: Bool = true

    @Flag(name: .long, help: "Enable BlueZ backend verbose logging.")
    var verbose: Bool = false

    mutating func run() async throws {
        if verbose {
            setenv("BLUETOOTH_BLUEZ_VERBOSE", "1", 1)
        }

        let manager = PeripheralManager()
        let serviceUUID = BluetoothUUID(UUID(uuidString: "0E73C5E9-2E2B-4A9E-9C48-9B7FE930ABED")!)
        let characteristicUUID = BluetoothUUID(UUID(uuidString: "7F0B8B1F-EDB4-4E1F-A04E-CE88B0E8C1A3")!)

        let characteristic = GATTCharacteristicDefinition(
            uuid: characteristicUUID,
            properties: [.read, .write, .notify],
            permissions: [.readable, .writeable],
            initialValue: Data("hello".utf8),
            descriptors: [
                GATTDescriptorDefinition(
                    uuid: .bit16(0x2901),
                    permissions: [.readable],
                    initialValue: Data("Demo Characteristic".utf8)
                )
            ]
        )
        let service = GATTServiceDefinition(uuid: serviceUUID, characteristics: [characteristic])

        print("Registering GATT service...")
        do {
            _ = try await manager.addService(service)
        } catch {
            print("Failed to add GATT service: \(error)")
            throw ExitCode.failure
        }

        do {
            let requests = try await manager.gattRequests()
            let store = GATTValueStore()
            Task {
                do {
                    for try await request in requests {
                        await Self.handle(request, store: store)
                    }
                } catch {
                    print("GATT request stream ended: \(error)")
                }
            }
        } catch {
            print("Warning: failed to open GATT request stream: \(error)")
        }

        let advertisingData = AdvertisementData(localName: name, serviceUUIDs: [serviceUUID])
        let parameters = AdvertisingParameters(
            isConnectable: connectable,
            isScannable: connectable
        )

        if !connectable {
            print("Warning: advertising as non-connectable; GATT clients will not be able to connect.")
        }

        print("Starting GATT advertising as \"\(name)\"")
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

    private static func handle(_ request: GATTServerRequest, store: GATTValueStore) async {
        switch request {
        case .read(let read):
            let value = await store.read()
            await read.respond(.success(value))
        case .write(let write):
            if write.isPreparedWrite {
                await write.respond(.failure(.att(.requestNotSupported)))
            } else {
                await store.write(write.value)
                await write.respond(.success(()))
            }
        case .readDescriptor(let read):
            let value = await store.descriptor()
            await read.respond(.success(value))
        case .writeDescriptor(let write):
            await write.respond(.failure(.att(.writeNotPermitted)))
        case .executeWrite(let execute):
            await execute.respond(.failure(.att(.requestNotSupported)))
        case .subscribe(let subscription):
            print("Central subscribed (\(subscription.type))")
        case .unsubscribe(let subscription):
            print("Central unsubscribed (\(subscription.type))")
        }
    }
}

actor GATTValueStore {
    private var value: Data = Data("hello".utf8)
    private let descriptorValue: Data = Data("Demo Characteristic".utf8)

    func read() -> Data {
        value
    }

    func write(_ data: Data) {
        value = data
    }

    func descriptor() -> Data {
        descriptorValue
    }
}
