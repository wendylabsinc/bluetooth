#if os(Linux)
#if canImport(FoundationEssentials)
import FoundationEssentials
import Foundation
#else
import Foundation
#endif

actor _BlueZScanController {
    private var isScanning = false
    private var allowDuplicates = false
    private var scanFilter: ScanFilter?
    private var continuation: AsyncThrowingStream<ScanResult, Error>.Continuation?
    private var process: Process?
    private var stdin: FileHandle?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var lineBuffer = ""
    private var devices: [String: DeviceState] = [:]
    private var emitted: Set<String> = []
    private var pendingHexDevice: String?
    private var pendingHexKind: PendingHexKind?
    private var pendingHex: [UInt8] = []

    func startScan(
        filter: ScanFilter?,
        parameters: ScanParameters
    ) async throws -> AsyncThrowingStream<ScanResult, Error> {
        if isScanning {
            throw BluetoothError.invalidState("BlueZ scan already in progress")
        }

        isScanning = true
        allowDuplicates = parameters.allowDuplicates
        scanFilter = filter
        emitted.removeAll()
        devices.removeAll()

        try startProcess(parameters: parameters)

        return AsyncThrowingStream { continuation in
            self.attach(continuation)
        }
    }

    func stopScan() {
        guard isScanning else { return }
        flushPendingHex()
        do {
            try write(["scan off", "quit"])
        } catch {
        }
        process?.terminate()
        finish()
    }

    func emit(_ result: ScanResult) {
        continuation?.yield(result)
    }

    func finish(error: Error? = nil) {
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }

        cleanup()
    }

    private func attach(_ continuation: AsyncThrowingStream<ScanResult, Error>.Continuation) {
        self.continuation = continuation
        continuation.onTermination = { @Sendable _ in
            Task {
                await self.cleanup()
            }
        }
    }

    private func startProcess(parameters: ScanParameters) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bluetoothctl")
        let inputPipe = Pipe()
        process.standardInput = inputPipe

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let verbose = ProcessInfo.processInfo.environment["BLUETOOTH_BLUEZ_VERBOSE"] == "1"
        attachOutput(pipe: stdoutPipe, verbose: verbose)
        attachOutput(pipe: stderrPipe, verbose: verbose)

        process.terminationHandler = { [weak self] _ in
            Task {
                await self?.cleanup()
            }
        }

        try process.run()

        self.process = process
        self.stdin = inputPipe.fileHandleForWriting
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe

        let dupSetting = parameters.allowDuplicates ? "on" : "off"
        let activeSetting = parameters.active ? "on" : "off"
        let commands = [
            "power on",
            "menu scan",
            "transport le",
            "dup \(dupSetting)",
            "active \(activeSetting)",
            "back",
            "scan on",
        ]
        try write(commands)
    }

    private func cleanup() {
        isScanning = false
        allowDuplicates = false
        scanFilter = nil
        continuation = nil
        stdin?.closeFile()
        stdin = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe?.fileHandleForReading.closeFile()
        stderrPipe?.fileHandleForReading.closeFile()
        stdoutPipe = nil
        stderrPipe = nil
        process = nil
        lineBuffer = ""
        devices.removeAll()
        emitted.removeAll()
        pendingHexDevice = nil
        pendingHexKind = nil
        pendingHex.removeAll()
    }

    private func write(_ commands: [String]) throws {
        guard let stdin else {
            return
        }

        for command in commands {
            let line = command + "\n"
            if let data = line.data(using: .utf8) {
                try stdin.write(contentsOf: data)
            }
        }
    }

    private func attachOutput(pipe: Pipe, verbose: Bool) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            Task {
                await self?.handleOutput(data, verbose: verbose)
            }
        }
    }

    private func handleOutput(_ data: Data, verbose: Bool) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return
        }

        lineBuffer += text
        while let range = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[..<range.lowerBound])
            lineBuffer = String(lineBuffer[range.upperBound...])
            handleLine(line, verbose: verbose)
        }
    }

    private func handleLine(_ rawLine: String, verbose: Bool) {
        let line = stripAnsi(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }

        if let hexBytes = parseHexBytes(line) {
            pendingHex.append(contentsOf: hexBytes)
            return
        }

        flushPendingHex()

        guard let (address, payload) = parseDeviceLine(line) else { return }

        if verbose {
            print("[bluez-scan] \(line)")
        }

        if payload.isEmpty {
            ensureDevice(address: address)
            emitIfNeeded(address: address)
            return
        }

        if payload.hasPrefix("RSSI:") {
            updateRSSI(address: address, payload: payload)
        } else if payload.hasPrefix("TxPower:") {
            updateTxPower(address: address, payload: payload)
        } else if payload.hasPrefix("Name:") || payload.hasPrefix("Alias:") {
            let name = payload.replacingOccurrences(of: "Name:", with: "")
                .replacingOccurrences(of: "Alias:", with: "")
                .trimmingCharacters(in: .whitespaces)
            updateName(address: address, name: name)
        } else if payload.hasPrefix("ManufacturerData.Key:") {
            updateManufacturerKey(address: address, payload: payload)
        } else if payload.hasPrefix("ManufacturerData.Value:") {
            pendingHexDevice = address
            pendingHexKind = .manufacturer
        } else if payload.hasPrefix("ServiceData.Key:") {
            updateServiceDataKey(address: address, payload: payload)
        } else if payload.hasPrefix("ServiceData.Value:") {
            pendingHexDevice = address
            if let key = devices[address]?.pendingServiceDataKey {
                pendingHexKind = .service(key)
            }
        } else if payload.hasPrefix("UUIDs:") {
            updateServiceUUIDs(address: address, payload: payload)
        } else if payload.contains(":") {
            // Unknown property; ignore.
        } else {
            updateName(address: address, name: payload)
        }

        emitIfNeeded(address: address)
    }

    private func ensureDevice(address: String) {
        if devices[address] != nil { return }
        let peripheral = Peripheral(id: .address(BluetoothAddress(address)))
        devices[address] = DeviceState(peripheral: peripheral, advertisementData: AdvertisementData())
    }

    private func updateName(address: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let lower = trimmed.lowercased()
        if lower == "n/a" || lower == "unknown" || lower == "na" {
            return
        }

        ensureDevice(address: address)
        var state = devices[address]!
        state.peripheral.name = trimmed
        state.advertisementData.localName = trimmed
        devices[address] = state
    }

    private func updateRSSI(address: String, payload: String) {
        guard let value = parseNumberInParens(payload) else { return }
        ensureDevice(address: address)
        var state = devices[address]!
        state.rssi = value
        devices[address] = state
    }

    private func updateTxPower(address: String, payload: String) {
        guard let value = parseNumberInParens(payload) else { return }
        ensureDevice(address: address)
        var state = devices[address]!
        state.advertisementData.txPowerLevel = value
        devices[address] = state
    }

    private func updateManufacturerKey(address: String, payload: String) {
        guard let key = parseHexValue(payload) else { return }
        ensureDevice(address: address)
        var state = devices[address]!
        state.pendingManufacturerKey = key
        devices[address] = state
    }

    private func updateServiceDataKey(address: String, payload: String) {
        guard let uuid = parseUUIDValue(payload) else { return }
        ensureDevice(address: address)
        var state = devices[address]!
        state.pendingServiceDataKey = uuid
        devices[address] = state
    }

    private func updateServiceUUIDs(address: String, payload: String) {
        ensureDevice(address: address)
        var state = devices[address]!
        let values = payload.replacingOccurrences(of: "UUIDs:", with: "")
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ")
        for value in values {
            if let uuid = parseBluetoothUUID(String(value)) {
                if !state.advertisementData.serviceUUIDs.contains(uuid) {
                    state.advertisementData.serviceUUIDs.append(uuid)
                }
            }
        }
        devices[address] = state
    }

    private func emitIfNeeded(address: String) {
        guard let state = devices[address], matchesFilter(state) else { return }
        if allowDuplicates || !emitted.contains(address) {
            let rssi = state.rssi ?? 0
            emit(ScanResult(peripheral: state.peripheral, advertisementData: state.advertisementData, rssi: rssi))
            emitted.insert(address)
        }
    }

    private func matchesFilter(_ state: DeviceState) -> Bool {
        guard let filter = scanFilter else { return true }

        if let prefix = filter.namePrefix {
            let name = state.peripheral.name ?? state.advertisementData.localName
            guard let name, name.lowercased().hasPrefix(prefix.lowercased()) else {
                return false
            }
        }

        if !filter.serviceUUIDs.isEmpty {
            let advertised = Set(state.advertisementData.serviceUUIDs)
            if advertised.intersection(filter.serviceUUIDs).isEmpty {
                return false
            }
        }

        return true
    }

    private func flushPendingHex() {
        guard let address = pendingHexDevice, let kind = pendingHexKind, !pendingHex.isEmpty else {
            pendingHexDevice = nil
            pendingHexKind = nil
            pendingHex.removeAll()
            return
        }

        ensureDevice(address: address)
        var state = devices[address]!
        let data = Data(pendingHex)
        switch kind {
        case .manufacturer:
            if let key = state.pendingManufacturerKey {
                state.advertisementData.manufacturerData = ManufacturerData(companyIdentifier: key, data: data)
            }
        case .service(let uuid):
            state.advertisementData.serviceData[uuid] = data
        }
        devices[address] = state

        pendingHexDevice = nil
        pendingHexKind = nil
        pendingHex.removeAll()
    }

    private func parseDeviceLine(_ line: String) -> (String, String)? {
        guard let range = line.range(of: "Device ") else { return nil }
        let rest = line[range.upperBound...]
        let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let address = parts.first else { return nil }
        let payload = parts.count > 1 ? String(parts[1]) : ""
        return (String(address), payload)
    }

    private func parseHexBytes(_ line: String) -> [UInt8]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var bytes: [UInt8] = []
        for token in trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            guard token.count == 2, let value = UInt8(token, radix: 16) else {
                break
            }
            bytes.append(value)
        }
        return bytes.isEmpty ? nil : bytes
    }

    private func parseNumberInParens(_ payload: String) -> Int? {
        guard let start = payload.firstIndex(of: "("),
              let end = payload.firstIndex(of: ")"),
              start < end
        else { return nil }
        let number = payload[payload.index(after: start)..<end]
        return Int(number.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func parseHexValue(_ payload: String) -> UInt16? {
        guard let range = payload.range(of: "0x") else { return nil }
        let valueStart = range.upperBound
        let hex = payload[valueStart...]
            .split(whereSeparator: { $0 == " " || $0 == "(" })
            .first ?? ""
        return UInt16(hex, radix: 16)
    }

    private func parseUUIDValue(_ payload: String) -> BluetoothUUID? {
        let cleaned = payload
            .replacingOccurrences(of: "ServiceData.Key:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return parseBluetoothUUID(cleaned)
    }

    private func parseBluetoothUUID(_ value: String) -> BluetoothUUID? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let noPrefix = trimmed.hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
        if noPrefix.contains("-"), let uuid = UUID(uuidString: noPrefix) {
            return .bit128(uuid)
        }
        if noPrefix.count <= 4, let short = UInt16(noPrefix, radix: 16) {
            return .bit16(short)
        }
        if noPrefix.count <= 8, let mid = UInt32(noPrefix, radix: 16) {
            return .bit32(mid)
        }
        return nil
    }

    private func stripAnsi(_ value: String) -> String {
        value.replacingOccurrences(of: "\\u001B\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    private struct DeviceState {
        var peripheral: Peripheral
        var advertisementData: AdvertisementData
        var rssi: Int?
        var pendingManufacturerKey: UInt16?
        var pendingServiceDataKey: BluetoothUUID?
    }

    private enum PendingHexKind {
        case manufacturer
        case service(BluetoothUUID)
    }
}

#endif
