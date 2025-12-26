//
//  DeviceDetailPage.swift
//  BluetoothCompanionApp
//

import SwiftUI
import CoreBluetooth

struct DeviceDetailPage: View {
    @Bindable var scanner: BLEScanner
    let device: BLEDevice

    @State private var selectedCharacteristic: CBCharacteristic?
    @State private var writeValue = ""
    @State private var showWriteSheet = false

    var body: some View {
        List {
            deviceInfoSection

            connectionSection

            if scanner.connectionState == .connected {
                servicesSection
            }
        }
        #if os(iOS) || os(visionOS)
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle(device.displayName)
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showWriteSheet) {
            if let characteristic = selectedCharacteristic {
                WriteCharacteristicSheet(
                    characteristic: characteristic,
                    writeValue: $writeValue,
                    onWrite: { data, withResponse in
                        scanner.writeValue(data, for: characteristic, withResponse: withResponse)
                        showWriteSheet = false
                        writeValue = ""
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var deviceInfoSection: some View {
        Section("Device Info") {
            LabeledContent("Name", value: device.displayName)
            LabeledContent("UUID", value: device.id.uuidString)
            LabeledContent("RSSI", value: "\(device.rssi) dBm")

            if let txPower = device.txPowerLevel {
                LabeledContent("TX Power", value: "\(txPower)")
            }

            if device.isConnectable {
                LabeledContent("Connectable", value: "Yes")
            }

            if !device.serviceUUIDs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Advertised Services")
                        .foregroundStyle(.secondary)
                    ForEach(device.serviceUUIDs, id: \.self) { uuid in
                        Text(uuid.uuidString)
                            .font(.caption)
                            .monospaced()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        Section("Connection") {
            HStack {
                Text("Status")
                Spacer()
                Text(scanner.connectionState.description)
                    .foregroundStyle(connectionColor)
            }

            if scanner.connectionState == .disconnected {
                Button("Connect") {
                    scanner.connect(to: device)
                }
                .disabled(!device.isConnectable)
            } else if scanner.connectionState == .connected {
                Button("Disconnect", role: .destructive) {
                    scanner.disconnect()
                }
            } else {
                HStack {
                    ProgressView()
                        .padding(.trailing, 8)
                    Text(scanner.connectionState.description)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var servicesSection: some View {
        if scanner.isDiscoveringServices {
            Section("Services") {
                HStack {
                    ProgressView()
                        .padding(.trailing, 8)
                    Text("Discovering services...")
                        .foregroundStyle(.secondary)
                }
            }
        } else if scanner.discoveredServices.isEmpty {
            Section("Services") {
                Text("No services discovered")
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(scanner.discoveredServices, id: \.uuid) { service in
                serviceSection(service)
            }
        }
    }

    @ViewBuilder
    private func serviceSection(_ service: CBService) -> some View {
        Section {
            if let characteristics = scanner.characteristicsByService[service.uuid], !characteristics.isEmpty {
                ForEach(characteristics, id: \.uuid) { characteristic in
                    characteristicRow(characteristic)
                }
            } else {
                Text("No characteristics")
                    .foregroundStyle(.secondary)
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(serviceName(for: service.uuid))
                    .font(.headline)
                Text(service.uuid.uuidString)
                    .font(.caption)
                    .monospaced()
            }
        }
    }

    @ViewBuilder
    private func characteristicRow(_ characteristic: CBCharacteristic) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(characteristicName(for: characteristic.uuid))
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                characteristicPropertiesView(characteristic.properties)
            }

            Text(characteristic.uuid.uuidString)
                .font(.caption2)
                .monospaced()
                .foregroundStyle(.secondary)

            if let value = scanner.characteristicValues[characteristic.uuid] {
                valueView(value)
            }

            HStack(spacing: 12) {
                if characteristic.properties.contains(.read) {
                    Button("Read") {
                        scanner.readValue(for: characteristic)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {
                    Button("Write") {
                        selectedCharacteristic = characteristic
                        showWriteSheet = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    Button(characteristic.isNotifying ? "Unsubscribe" : "Subscribe") {
                        scanner.setNotifications(enabled: !characteristic.isNotifying, for: characteristic)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func characteristicPropertiesView(_ properties: CBCharacteristicProperties) -> some View {
        HStack(spacing: 4) {
            if properties.contains(.read) {
                propertyBadge("R", color: .blue)
            }
            if properties.contains(.write) {
                propertyBadge("W", color: .green)
            }
            if properties.contains(.writeWithoutResponse) {
                propertyBadge("WNR", color: .orange)
            }
            if properties.contains(.notify) {
                propertyBadge("N", color: .purple)
            }
            if properties.contains(.indicate) {
                propertyBadge("I", color: .pink)
            }
        }
    }

    @ViewBuilder
    private func propertyBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func valueView(_ data: Data) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Value:")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(data.hexString)
                .font(.caption)
                .monospaced()
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            if let string = String(data: data, encoding: .utf8), !string.isEmpty {
                Text("UTF-8: \(string)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var connectionColor: Color {
        switch scanner.connectionState {
        case .disconnected: return .secondary
        case .connecting: return .orange
        case .connected: return .green
        case .disconnecting: return .orange
        }
    }

    private func serviceName(for uuid: CBUUID) -> String {
        knownServices[uuid.uuidString] ?? "Service"
    }

    private func characteristicName(for uuid: CBUUID) -> String {
        knownCharacteristics[uuid.uuidString] ?? "Characteristic"
    }
}

struct WriteCharacteristicSheet: View {
    let characteristic: CBCharacteristic
    @Binding var writeValue: String
    let onWrite: (Data, Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Characteristic") {
                    Text(characteristic.uuid.uuidString)
                        .font(.caption)
                        .monospaced()
                }

                Section("Value (Hex)") {
                    TextField("e.g., 01020304", text: $writeValue)
                        #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .monospaced()
                }

                Section {
                    if characteristic.properties.contains(.write) {
                        Button("Write with Response") {
                            if let data = Data(hexString: writeValue) {
                                onWrite(data, true)
                            }
                        }
                        .disabled(!isValidHex)
                    }

                    if characteristic.properties.contains(.writeWithoutResponse) {
                        Button("Write without Response") {
                            if let data = Data(hexString: writeValue) {
                                onWrite(data, false)
                            }
                        }
                        .disabled(!isValidHex)
                    }
                }
            }
            .navigationTitle("Write Value")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        #if os(iOS) || os(visionOS)
        .presentationDetents([.medium])
        #endif
    }

    private var isValidHex: Bool {
        !writeValue.isEmpty && writeValue.count % 2 == 0 && writeValue.allSatisfy { $0.isHexDigit }
    }
}

// MARK: - Data Extensions

extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    init?(hexString: String) {
        let hex = hexString.replacingOccurrences(of: " ", with: "")
        guard hex.count % 2 == 0 else { return nil }

        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}

// MARK: - Known UUIDs

private let knownServices: [String: String] = [
    "1800": "Generic Access",
    "1801": "Generic Attribute",
    "1802": "Immediate Alert",
    "1803": "Link Loss",
    "1804": "Tx Power",
    "1805": "Current Time",
    "1806": "Reference Time Update",
    "1807": "Next DST Change",
    "1808": "Glucose",
    "1809": "Health Thermometer",
    "180A": "Device Information",
    "180D": "Heart Rate",
    "180E": "Phone Alert Status",
    "180F": "Battery",
    "1810": "Blood Pressure",
    "1811": "Alert Notification",
    "1812": "Human Interface Device",
    "1813": "Scan Parameters",
    "1814": "Running Speed and Cadence",
    "1815": "Automation IO",
    "1816": "Cycling Speed and Cadence",
    "1818": "Cycling Power",
    "1819": "Location and Navigation",
    "181A": "Environmental Sensing",
    "181B": "Body Composition",
    "181C": "User Data",
    "181D": "Weight Scale",
    "181E": "Bond Management",
    "181F": "Continuous Glucose Monitoring",
]

private let knownCharacteristics: [String: String] = [
    "2A00": "Device Name",
    "2A01": "Appearance",
    "2A02": "Peripheral Privacy Flag",
    "2A03": "Reconnection Address",
    "2A04": "Peripheral Preferred Connection Parameters",
    "2A05": "Service Changed",
    "2A06": "Alert Level",
    "2A07": "Tx Power Level",
    "2A19": "Battery Level",
    "2A23": "System ID",
    "2A24": "Model Number String",
    "2A25": "Serial Number String",
    "2A26": "Firmware Revision String",
    "2A27": "Hardware Revision String",
    "2A28": "Software Revision String",
    "2A29": "Manufacturer Name String",
    "2A2A": "IEEE 11073-20601 Regulatory Certification Data List",
    "2A37": "Heart Rate Measurement",
    "2A38": "Body Sensor Location",
    "2A39": "Heart Rate Control Point",
]

// Preview requires a real CBPeripheral which cannot be mocked
// Run on device or simulator to test
