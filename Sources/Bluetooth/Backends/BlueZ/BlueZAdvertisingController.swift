#if os(Linux)
import Foundation

actor _BlueZAdvertisingController {
    private var process: Process?
    private var stdin: FileHandle?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    var isAdvertising: Bool {
        process?.isRunning ?? false
    }

    func startAdvertising(
        advertisingData: AdvertisementData,
        scanResponseData: AdvertisementData?,
        parameters: AdvertisingParameters
    ) async throws {
        if isAdvertising {
            throw BluetoothError.invalidState("BlueZ advertising already in progress")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bluetoothctl")
        let inputPipe = Pipe()
        process.standardInput = inputPipe

        let verbose = ProcessInfo.processInfo.environment["BLUETOOTH_BLUEZ_VERBOSE"] == "1"
        if verbose {
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            attachOutput(pipe: stdoutPipe, prefix: "[bluez] ")
            attachOutput(pipe: stderrPipe, prefix: "[bluez] ")
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        process.terminationHandler = { [weak self] _ in
            Task {
                await self?.cleanup()
            }
        }

        try process.run()
        self.process = process
        self.stdin = inputPipe.fileHandleForWriting

        try await Task.sleep(nanoseconds: 500_000_000)

        var commands: [String] = []
        commands.append("power on")
        commands.append("menu advertise")
        commands.append("clear")
        commands.append("discoverable on")
        commands.append("discoverable-timeout 0")

        if let name = advertisingData.localName, !name.isEmpty {
            commands.append("name \(name)")
        } else {
            commands.append("name on")
        }

        if !advertisingData.serviceUUIDs.isEmpty {
            let uuids = advertisingData.serviceUUIDs.map(\.description).joined(separator: " ")
            commands.append("uuids \(uuids)")
        }

        if let manufacturer = advertisingData.manufacturerData {
            let hex = hexString(manufacturer.data)
            commands.append("manufacturer \(hexIdentifier(manufacturer.companyIdentifier)) \(hex)")
        }

        if !advertisingData.serviceData.isEmpty {
            for (uuid, data) in advertisingData.serviceData {
                let hex = hexString(data)
                commands.append("service \(uuid) \(hex)")
            }
        }

        if let scanResponseData, parameters.isScannable {
            if !scanResponseData.serviceUUIDs.isEmpty {
                let uuids = scanResponseData.serviceUUIDs.map(\.description).joined(separator: " ")
                commands.append("sr-uuids \(uuids)")
            }

            if let manufacturer = scanResponseData.manufacturerData {
                let hex = hexString(manufacturer.data)
                commands.append("sr-manufacturer \(hexIdentifier(manufacturer.companyIdentifier)) \(hex)")
            }

            if !scanResponseData.serviceData.isEmpty {
                for (uuid, data) in scanResponseData.serviceData {
                    let hex = hexString(data)
                    commands.append("sr-service \(uuid) \(hex)")
                }
            }
        }

        if parameters.includeTxPower {
            commands.append("tx-power on")
        }

        if let interval = parameters.interval {
            let milliseconds = max(20, Int(interval * 1000))
            commands.append("interval \(milliseconds) \(milliseconds)")
        }

        let needsExtended = parameters.isExtended
            || requiresExtendedAdvertising(advertisingData: advertisingData, scanResponseData: scanResponseData)

        if let secondary = parameters.secondaryPHY {
            switch secondary {
            case .le1M:
                commands.append("secondary 1M")
            case .le2M:
                commands.append("secondary 2M")
            case .leCoded:
                commands.append("secondary Coded")
            }
        } else if needsExtended {
            commands.append("secondary 1M")
        }

        commands.append("back")
        let advertiseType = parameters.isConnectable ? "peripheral" : "broadcast"
        commands.append("advertise \(advertiseType)")

        try write(commands)
    }

    func stopAdvertising() {
        guard isAdvertising else {
            cleanup()
            return
        }

        do {
            try write(["advertise off", "quit"])
        } catch {
        }

        process?.terminate()
        cleanup()
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

    private func hexString(_ data: Data) -> String {
        data.map { byte in
            let hex = String(byte, radix: 16, uppercase: true)
            return hex.count == 1 ? "0\(hex)" : hex
        }.joined(separator: " ")
    }

    private func hexIdentifier(_ value: UInt16) -> String {
        let hex = String(value, radix: 16, uppercase: true)
        let padded = String(repeating: "0", count: max(0, 4 - hex.count)) + hex
        return "0x" + padded
    }

    private func cleanup() {
        stdin?.closeFile()
        stdin = nil
        stdoutPipe?.fileHandleForReading.closeFile()
        stderrPipe?.fileHandleForReading.closeFile()
        stdoutPipe = nil
        stderrPipe = nil
        process = nil
    }

    private func attachOutput(pipe: Pipe, prefix: String) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    print(prefix + line)
                }
            }
        }
    }

    private func requiresExtendedAdvertising(
        advertisingData: AdvertisementData,
        scanResponseData: AdvertisementData?
    ) -> Bool {
        let advBytes = estimatedLegacyPayloadBytes(for: advertisingData, includeFlags: true)
        let scanBytes = scanResponseData.map { estimatedLegacyPayloadBytes(for: $0, includeFlags: false) } ?? 0
        return advBytes > 31 || scanBytes > 31
    }

    private func estimatedLegacyPayloadBytes(
        for data: AdvertisementData,
        includeFlags: Bool
    ) -> Int {
        var total = includeFlags ? 3 : 0

        if let name = data.localName {
            total += name.utf8.count + 2
        }

        if !data.serviceUUIDs.isEmpty {
            let uuidBytes = data.serviceUUIDs.reduce(0) { $0 + $1.byteCount }
            total += uuidBytes + 2
        }

        if let manufacturer = data.manufacturerData {
            total += manufacturer.data.count + 4
        }

        if !data.serviceData.isEmpty {
            for (uuid, payload) in data.serviceData {
                total += payload.count + uuid.byteCount + 2
            }
        }

        if data.txPowerLevel != nil {
            total += 3
        }

        return total
    }
}

private extension BluetoothUUID {
    var byteCount: Int {
        switch self {
        case .bit16:
            return 2
        case .bit32:
            return 4
        case .bit128:
            return 16
        }
    }
}

#endif
