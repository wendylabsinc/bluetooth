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

    @Option(name: .long, help: "Bluetooth adapter (e.g. hci0).")
    var adapter: String?

    @Option(name: .long, help: "Optional central Bluetooth address to connect to for bonding test.")
    var connectAddress: String?

    @Flag(name: .long, help: "Require bonding when connecting as a central (used with --connect-address).")
    var requireBonding: Bool = false

    @Flag(name: .long, help: "Enable pairing request handling.")
    var pairing: Bool = false

    @Option(name: .long, help: "PIN code to respond with if requested during pairing.")
    var pairingPin: String?

    @Option(name: .long, help: "Passkey (0-999999) to respond with if requested during pairing.")
    var pairingPasskey: UInt32?

    @Flag(inversion: .prefixedNo, help: "Auto-accept pairing confirmations and authorizations.")
    var pairingAutoAccept: Bool = true

    mutating func run() async throws {
        var pairingTask: Task<Void, Never>?

        let options = BluetoothOptions(adapter: adapter.map(BluetoothAdapter.init))

        if let connectAddress {
            let manager = CentralManager(options: options)

            if pairing {
                do {
                    let requests = try await manager.pairingRequests()
                    pairingTask = Self.startPairingTask(
                        role: "central",
                        requests: requests,
                        pin: pairingPin,
                        passkey: pairingPasskey,
                        autoAccept: pairingAutoAccept
                    )
                } catch {
                    print("Warning: failed to start central pairing stream: \(error)")
                }
            }

            let peripheral = Peripheral(id: .address(BluetoothAddress(connectAddress)))
            do {
                let options = ConnectionOptions(requiresBonding: requireBonding)
                _ = try await manager.connect(to: peripheral, options: options)
                print("Connected to \(connectAddress) (bonding: \(requireBonding))")
            } catch {
                print("Failed to connect for bonding test: \(error)")
            }
        }

        let manager = PeripheralManager(options: options)
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
        let registration: GATTServiceRegistration
        do {
            registration = try await manager.addService(service)
        } catch {
            print("Failed to add GATT service: \(error)")
            throw ExitCode.failure
        }

        if pairing {
            if connectAddress == nil {
                do {
                    let requests = try await manager.pairingRequests()
                    pairingTask = Self.startPairingTask(
                        role: "peripheral",
                        requests: requests,
                        pin: pairingPin,
                        passkey: pairingPasskey,
                        autoAccept: pairingAutoAccept
                    )
                } catch {
                    print("Warning: failed to start peripheral pairing stream: \(error)")
                }
            } else {
                print("Pairing handling is already active for the central role; peripheral prompts will use environment defaults.")
            }
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
        do {
            try await manager.removeService(registration)
        } catch {
            print("Warning: failed to remove GATT service: \(error)")
        }
        print("Stopped.")

        pairingTask?.cancel()
        _ = await pairingTask?.value
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

    private static func startPairingTask(
        role: String,
        requests: AsyncThrowingStream<PairingRequest, Error>,
        pin: String?,
        passkey: UInt32?,
        autoAccept: Bool
    ) -> Task<Void, Never> {
        Task {
            do {
                for try await request in requests {
                    await handlePairingRequest(
                        request,
                        role: role,
                        pin: pin,
                        passkey: passkey,
                        autoAccept: autoAccept
                    )
                }
            } catch {
                print("Pairing request stream ended (\(role)): \(error)")
            }
        }
    }

    private static func handlePairingRequest(
        _ request: PairingRequest,
        role: String,
        pin: String?,
        passkey: UInt32?,
        autoAccept: Bool
    ) async {
        switch request {
        case .displayPinCode(let display):
            print("Pairing (\(role)) display PIN \(display.pinCode) for \(peerLabel(central: display.central, peripheral: display.peripheral))")
        case .displayPasskey(let display):
            let entered = display.entered.map { " entered=\($0)" } ?? ""
            print("Pairing (\(role)) display passkey \(display.passkey)\(entered) for \(peerLabel(central: display.central, peripheral: display.peripheral))")
        case .pinCode(let request):
            if let pin {
                print("Pairing (\(role)) responding with PIN for \(peerLabel(central: request.central, peripheral: request.peripheral))")
                await request.respond(pin)
            } else {
                print("Pairing (\(role)) PIN requested but no --pairing-pin provided; rejecting.")
                await request.respond(nil)
            }
        case .passkey(let request):
            if let passkey {
                print("Pairing (\(role)) responding with passkey for \(peerLabel(central: request.central, peripheral: request.peripheral))")
                await request.respond(passkey)
            } else {
                print("Pairing (\(role)) passkey requested but no --pairing-passkey provided; rejecting.")
                await request.respond(nil)
            }
        case .confirmation(let request):
            print("Pairing (\(role)) confirmation requested for \(peerLabel(central: request.central, peripheral: request.peripheral))")
            await request.respond(autoAccept)
        case .authorization(let request):
            print("Pairing (\(role)) authorization requested for \(peerLabel(central: request.central, peripheral: request.peripheral))")
            await request.respond(autoAccept)
        case .serviceAuthorization(let request):
            let service = request.serviceUUID.map(\.description) ?? "unknown"
            print("Pairing (\(role)) service authorization requested (\(service)) for \(peerLabel(central: request.central, peripheral: request.peripheral))")
            await request.respond(autoAccept)
        }
    }

    private static func peerLabel(central: Central?, peripheral: Peripheral?) -> String {
        if let peripheral {
            return "peripheral \(peripheral.id)"
        }
        if let central {
            return "central \(central.id)"
        }
        return "peer"
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
        case .authorize(let authorization):
            await authorization.respond(true)
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
