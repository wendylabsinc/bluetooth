import ArgumentParser
import Bluetooth
import Dispatch

#if os(Windows)
  import Foundation
#elseif canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

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
struct DiscoveryExample: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "bluetooth-discovery-example",
    abstract: "Scan for BLE advertisements using the Bluetooth package."
  )

  @Option(name: .long, help: "Milliseconds to scan before exiting.")
  var time: UInt64?

  @Option(name: .long, help: "Filter by local name prefix.")
  var namePrefix: String?

  @Option(name: .customLong("uuid"), help: "Service UUID filter (repeatable).")
  var serviceUUIDs: [String] = []

  @Flag(name: .long, help: "Allow duplicate advertisements.")
  var duplicates: Bool = false

  @Option(name: .long, help: "Bluetooth adapter (e.g. hci0).")
  var adapter: String?

  mutating func run() async throws {
    let uuids = try serviceUUIDs.map { value in
      guard let parsed = Self.parseBluetoothUUID(value) else {
        throw ValidationError("Invalid UUID: \(value)")
      }
      return parsed
    }

    let filter: ScanFilter? =
      (namePrefix != nil || !uuids.isEmpty)
      ? ScanFilter(serviceUUIDs: uuids, namePrefix: namePrefix)
      : nil

    let options = BluetoothOptions(adapter: adapter.map(BluetoothAdapter.init))
    let manager = CentralManager(options: options)
    let parameters = ScanParameters(allowDuplicates: duplicates)

    print("Starting BLE scan...")
    let stream = try await manager.scan(filter: filter, parameters: parameters)

    let printer = Task {
      do {
        for try await result in stream {
          print(Self.format(result))
        }
      } catch {
        print("Scan stream ended with error: \(error)")
      }
    }

    if let time {
      let capped = min(time, UInt64.max / 1_000_000)
      print("Scanning for \(time) ms...")
      try await Task.sleep(nanoseconds: capped * 1_000_000)
    } else {
      print("Scanning... press Ctrl+C to stop.")
      await waitForInterrupt()
    }

    do {
      try await manager.stopScan()
    } catch {
      print("Stop scan failed: \(error)")
    }

    _ = await printer.value
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

  private static func format(_ result: ScanResult) -> String {
    var fields: [String] = []
    fields.append(result.peripheral.id.description)

    if let name = result.peripheral.name ?? result.advertisementData.localName {
      fields.append("name=\(name)")
    }

    fields.append("rssi=\(result.rssi)")

    if let txPower = result.advertisementData.txPowerLevel {
      fields.append("tx=\(txPower)")
    }

    if !result.advertisementData.serviceUUIDs.isEmpty {
      let uuids = result.advertisementData.serviceUUIDs.map(\.description).joined(separator: ",")
      fields.append("uuids=\(uuids)")
    }

    if let manufacturer = result.advertisementData.manufacturerData {
      fields.append("mfg=0x\(hex(manufacturer.companyIdentifier, width: 4))")
    }

    if !result.advertisementData.serviceData.isEmpty {
      fields.append("serviceData=\(result.advertisementData.serviceData.count)")
    }

    return fields.joined(separator: " ")
  }

  private static func parseBluetoothUUID(_ value: String) -> BluetoothUUID? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let noPrefix: String
    if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
      noPrefix = String(trimmed.dropFirst(2))
    } else {
      noPrefix = trimmed
    }

    if noPrefix.contains("-"), let uuid = UUID(uuidString: noPrefix) {
      return .bit128(uuid)
    }

    let upper = noPrefix.uppercased()
    if upper.count == 32 {
      let formatted = [
        upper.prefix(8),
        upper.dropFirst(8).prefix(4),
        upper.dropFirst(12).prefix(4),
        upper.dropFirst(16).prefix(4),
        upper.dropFirst(20).prefix(12),
      ].map(String.init).joined(separator: "-")
      if let uuid = UUID(uuidString: formatted) {
        return .bit128(uuid)
      }
    }

    if upper.count <= 4, let short = UInt16(upper, radix: 16) {
      return .bit16(short)
    }

    if upper.count <= 8, let mid = UInt32(upper, radix: 16) {
      return .bit32(mid)
    }

    return nil
  }

  private static func hex(_ value: UInt16, width: Int) -> String {
    let raw = String(value, radix: 16, uppercase: true)
    if raw.count >= width { return raw }
    return String(repeating: "0", count: width - raw.count) + raw
  }
}
