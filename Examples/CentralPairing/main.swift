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
struct CentralPairingExample: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "bluetooth-central-pairing-example",
    abstract: "Connect to a peripheral as a central and handle pairing prompts."
  )

  @Option(name: .long, help: "Peripheral Bluetooth address to connect to.")
  var address: String

  @Flag(inversion: .prefixedNo, help: "Require bonding during connect.")
  var requireBonding: Bool = true

  @Option(name: .long, help: "PIN code to respond with if requested during pairing.")
  var pin: String?

  @Option(name: .long, help: "Passkey (0-999999) to respond with if requested during pairing.")
  var passkey: UInt32?

  @Flag(inversion: .prefixedNo, help: "Auto-accept pairing confirmations and authorizations.")
  var autoAccept: Bool = true

  @Option(name: .long, help: "Milliseconds to stay connected before exiting.")
  var time: UInt64?

  @Option(name: .long, help: "Bluetooth adapter (e.g. hci0).")
  var adapter: String?

  mutating func run() async throws {
    let options = BluetoothOptions(adapter: adapter.map(BluetoothAdapter.init))
    let manager = CentralManager(options: options)
    var pairingTask: Task<Void, Never>?

    do {
      let requests = try await manager.pairingRequests()
      pairingTask = Self.startPairingTask(
        requests: requests,
        pin: pin,
        passkey: passkey,
        autoAccept: autoAccept
      )
    } catch {
      print("Warning: failed to start pairing stream: \(error)")
    }

    defer { pairingTask?.cancel() }

    let peripheral = Peripheral(id: .address(BluetoothAddress(address)))
    do {
      let options = ConnectionOptions(requiresBonding: requireBonding)
      let connection = try await manager.connect(to: peripheral, options: options)
      print("Connected to \(address) (bonding: \(requireBonding))")
      print("Pairing state: \(Self.formatPairingState(await connection.pairingState()))")

      let pairingStateTask = Task {
        let updates = await connection.pairingStateUpdates()
        for await state in updates {
          print("Pairing state update: \(Self.formatPairingState(state))")
        }
      }

      if let time {
        let capped = min(time, UInt64.max / 1_000_000)
        print("Staying connected for \(time) ms...")
        try await Task.sleep(nanoseconds: capped * 1_000_000)
      } else {
        print("Connected... press Ctrl+C to stop.")
        await waitForInterrupt()
      }

      print("Disconnecting...")
      await connection.disconnect()
      print("Disconnected.")

      pairingStateTask.cancel()
    } catch {
      print("Failed to connect: \(error)")
      throw ExitCode.failure
    }
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
            pin: pin,
            passkey: passkey,
            autoAccept: autoAccept
          )
        }
      } catch {
        print("Pairing request stream ended: \(error)")
      }
    }
  }

  private static func handlePairingRequest(
    _ request: PairingRequest,
    pin: String?,
    passkey: UInt32?,
    autoAccept: Bool
  ) async {
    switch request {
    case .displayPinCode(let display):
      print(
        "Pairing display PIN \(display.pinCode) for \(peerLabel(central: display.central, peripheral: display.peripheral))"
      )
    case .displayPasskey(let display):
      let entered = display.entered.map { " entered=\($0)" } ?? ""
      print(
        "Pairing display passkey \(display.passkey)\(entered) for \(peerLabel(central: display.central, peripheral: display.peripheral))"
      )
    case .pinCode(let request):
      if let pin {
        print(
          "Pairing responding with PIN for \(peerLabel(central: request.central, peripheral: request.peripheral))"
        )
        await request.respond(pin)
      } else {
        print("Pairing PIN requested but no --pin provided; rejecting.")
        await request.respond(nil)
      }
    case .passkey(let request):
      if let passkey {
        print(
          "Pairing responding with passkey for \(peerLabel(central: request.central, peripheral: request.peripheral))"
        )
        await request.respond(passkey)
      } else {
        print("Pairing passkey requested but no --passkey provided; rejecting.")
        await request.respond(nil)
      }
    case .confirmation(let request):
      print(
        "Pairing confirmation requested for \(peerLabel(central: request.central, peripheral: request.peripheral))"
      )
      await request.respond(autoAccept)
    case .authorization(let request):
      print(
        "Pairing authorization requested for \(peerLabel(central: request.central, peripheral: request.peripheral))"
      )
      await request.respond(autoAccept)
    case .serviceAuthorization(let request):
      let service = request.serviceUUID.map(\.description) ?? "unknown"
      print(
        "Pairing service authorization requested (\(service)) for \(peerLabel(central: request.central, peripheral: request.peripheral))"
      )
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

  private static func formatPairingState(_ state: PairingState) -> String {
    switch state {
    case .unknown:
      return "unknown"
    case .unpaired:
      return "unpaired"
    case .paired:
      return "paired"
    }
  }
}
