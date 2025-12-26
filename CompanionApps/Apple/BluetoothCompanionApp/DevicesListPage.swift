//
//  DevicesListPage.swift
//  BluetoothCompanionApp
//

import SwiftUI
import CoreBluetooth

struct DevicesListPage: View {
    @State private var scanner = BLEScanner()
    @State private var searchText = ""

    private var filteredDevices: [BLEDevice] {
        let sorted = scanner.sortedDevices
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { $0.matchesFuzzySearch(searchText) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !scanner.canScan {
                    BluetoothUnavailableView(
                        state: scanner.stateDescription,
                        isUnauthorized: scanner.isUnauthorized
                    )
                } else if scanner.sortedDevices.isEmpty && !scanner.isScanning {
                    EmptyStateView(onStartScan: scanner.startScanning)
                } else {
                    devicesList
                }
            }
            .navigationTitle("BLE Devices")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .searchable(text: $searchText, prompt: "Search devices...")
            .toolbar {
                toolbarContent
            }
            .onAppear {
                if scanner.canScan && !scanner.isScanning {
                    scanner.startScanning()
                }
            }
            .onChange(of: scanner.canScan) { _, canScan in
                if canScan && !scanner.isScanning {
                    scanner.startScanning()
                }
            }
        }
    }

    @ViewBuilder
    private var devicesList: some View {
        List {
            if scanner.isScanning {
                scanningSection
            }

            devicesSection
        }
        #if os(iOS) || os(visionOS)
        .listStyle(.insetGrouped)
        #endif
        .refreshable {
            scanner.clearDevices()
            scanner.startScanning()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    @ViewBuilder
    private var scanningSection: some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text("Scanning for devices...")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var devicesSection: some View {
        Section {
            if filteredDevices.isEmpty && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ForEach(filteredDevices) { device in
                    DeviceRowView(device: device)
                        .transition(.asymmetric(
                            insertion: .scale.combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
        } header: {
            if !filteredDevices.isEmpty {
                Text("\(filteredDevices.count) device\(filteredDevices.count == 1 ? "" : "s") found")
                    .contentTransition(.numericText())
            }
        }
        .animation(.smooth, value: filteredDevices.map(\.id))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(iOS) || os(visionOS)
        ToolbarItem(placement: .primaryAction) {
            scanButton
        }
        ToolbarItem(placement: .secondaryAction) {
            Button("Clear", systemImage: "trash") {
                scanner.clearDevices()
            }
            .disabled(scanner.sortedDevices.isEmpty)
        }
        #else
        ToolbarItem {
            scanButton
        }
        ToolbarItem {
            Button("Clear", systemImage: "trash") {
                scanner.clearDevices()
            }
            .disabled(scanner.sortedDevices.isEmpty)
        }
        #endif
    }

    @ViewBuilder
    private var scanButton: some View {
        Button {
            scanner.toggleScanning()
        } label: {
            if scanner.isScanning {
                Label("Stop", systemImage: "stop.fill")
            } else {
                Label("Scan", systemImage: "antenna.radiowaves.left.and.right")
            }
        }
    }
}

struct DeviceRowView: View {
    let device: BLEDevice

    var body: some View {
        HStack(spacing: 12) {
            rssiIndicator

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(device.displayName)
                        .font(.headline)
                        .lineLimit(1)

                    if device.isConnectable {
                        Image(systemName: "link")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                if !device.serviceUUIDs.isEmpty {
                    Text(device.serviceUUIDs.map(\.uuidString).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Text("RSSI: \(device.rssi) dBm")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if let txPower = device.txPowerLevel {
                        Text("TX: \(txPower)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    if device.manufacturerData != nil {
                        Image(systemName: "building.2")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(device.rssi)")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(rssiColor)
                    .contentTransition(.numericText())
                Text(device.rssiDescription)
                    .font(.caption)
                    .foregroundStyle(rssiColor)
            }
        }
        .padding(.vertical, 4)
        .animation(.smooth(duration: 0.3), value: device.rssi)
    }

    @ViewBuilder
    private var rssiIndicator: some View {
        ZStack {
            Circle()
                .fill(rssiColor.opacity(0.15))
                .frame(width: 44, height: 44)

            Image(systemName: device.rssiIcon)
                .font(.system(size: 20))
                .foregroundStyle(rssiColor)
        }
    }

    private var rssiColor: Color {
        switch device.rssi {
        case -50...0:
            return .green
        case -60..<(-50):
            return .blue
        case -70..<(-60):
            return .orange
        default:
            return .red
        }
    }
}

struct BluetoothUnavailableView: View {
    let state: String
    let isUnauthorized: Bool

    var body: some View {
        ContentUnavailableView {
            Label(
                isUnauthorized ? "Bluetooth Permission Required" : "Bluetooth Unavailable",
                systemImage: isUnauthorized ? "lock.shield" : "antenna.radiowaves.left.and.right.slash"
            )
        } description: {
            if isUnauthorized {
                Text("This app needs Bluetooth permission to discover nearby BLE devices. Please enable Bluetooth access in Settings.")
            } else {
                Text("Bluetooth is \(state.lowercased()). Please enable Bluetooth to scan for devices.")
            }
        } actions: {
            if isUnauthorized {
                Button("Open Settings") {
                    openSettings()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func openSettings() {
        #if os(iOS) || os(visionOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
            NSWorkspace.shared.open(url)
        }
        #elseif os(watchOS)
        // watchOS doesn't support opening Settings directly
        #elseif os(tvOS)
        // tvOS doesn't support opening Settings directly
        #endif
    }
}

struct EmptyStateView: View {
    let onStartScan: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Devices", systemImage: "antenna.radiowaves.left.and.right")
        } description: {
            Text("Start scanning to discover nearby BLE devices.")
        } actions: {
            Button("Start Scanning") {
                onStartScan()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    DevicesListPage()
}
