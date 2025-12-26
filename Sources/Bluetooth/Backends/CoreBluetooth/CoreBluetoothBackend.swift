#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - BluetoothUUID Extensions

extension BluetoothUUID {
    var cbuuid: CBUUID {
        switch self {
        case .bit16(let value):
            return CBUUID(string: String(format: "%04X", value))
        case .bit32(let value):
            return CBUUID(string: String(format: "%08X", value))
        case .bit128(let uuid):
            return CBUUID(nsuuid: uuid)
        }
    }

    init(_ cbuuid: CBUUID) {
        let uuidString = cbuuid.uuidString
        if uuidString.count == 4 {
            self = .bit16(UInt16(uuidString, radix: 16) ?? 0)
        } else if uuidString.count == 8 {
            self = .bit32(UInt32(uuidString, radix: 16) ?? 0)
        } else {
            self = .bit128(UUID(uuidString: uuidString) ?? UUID())
        }
    }
}

// MARK: - BluetoothState Extensions

extension BluetoothState {
    init(_ cbState: CBManagerState) {
        switch cbState {
        case .unknown: self = .unknown
        case .resetting: self = .resetting
        case .unsupported: self = .unsupported
        case .unauthorized: self = .unauthorized
        case .poweredOff: self = .poweredOff
        case .poweredOn: self = .poweredOn
        @unknown default: self = .unknown
        }
    }
}

// MARK: - GATTCharacteristicProperties Extensions

extension GATTCharacteristicProperties {
    var cbProperties: CBCharacteristicProperties {
        var props: CBCharacteristicProperties = []
        if contains(.broadcast) { props.insert(.broadcast) }
        if contains(.read) { props.insert(.read) }
        if contains(.writeWithoutResponse) { props.insert(.writeWithoutResponse) }
        if contains(.write) { props.insert(.write) }
        if contains(.notify) { props.insert(.notify) }
        if contains(.indicate) { props.insert(.indicate) }
        if contains(.authenticatedSignedWrites) { props.insert(.authenticatedSignedWrites) }
        if contains(.extendedProperties) { props.insert(.extendedProperties) }
        return props
    }

    init(_ cbProperties: CBCharacteristicProperties) {
        var props = GATTCharacteristicProperties()
        if cbProperties.contains(.broadcast) { props.insert(.broadcast) }
        if cbProperties.contains(.read) { props.insert(.read) }
        if cbProperties.contains(.writeWithoutResponse) { props.insert(.writeWithoutResponse) }
        if cbProperties.contains(.write) { props.insert(.write) }
        if cbProperties.contains(.notify) { props.insert(.notify) }
        if cbProperties.contains(.indicate) { props.insert(.indicate) }
        if cbProperties.contains(.authenticatedSignedWrites) { props.insert(.authenticatedSignedWrites) }
        if cbProperties.contains(.extendedProperties) { props.insert(.extendedProperties) }
        self = props
    }
}

// MARK: - GATTAttributePermissions Extensions

extension GATTAttributePermissions {
    var cbPermissions: CBAttributePermissions {
        var perms: CBAttributePermissions = []
        if contains(.readable) { perms.insert(.readable) }
        if contains(.writeable) { perms.insert(.writeable) }
        if contains(.readEncryptionRequired) { perms.insert(.readEncryptionRequired) }
        if contains(.writeEncryptionRequired) { perms.insert(.writeEncryptionRequired) }
        return perms
    }
}

// MARK: - Sendable Wrappers for CoreBluetooth Types

/// Wrapper to make CBPeripheral sendable across actor boundaries
/// Safety: CoreBluetooth objects are thread-safe when accessed from their designated queue
@usableFromInline
struct SendablePeripheral: @unchecked Sendable {
    let peripheral: CBPeripheral
    init(_ peripheral: CBPeripheral) { self.peripheral = peripheral }
}

/// Wrapper to make CBService sendable across actor boundaries
@usableFromInline
struct SendableService: @unchecked Sendable {
    let service: CBService
    init(_ service: CBService) { self.service = service }
}

/// Wrapper to make CBCharacteristic sendable across actor boundaries
@usableFromInline
struct SendableCharacteristic: @unchecked Sendable {
    let characteristic: CBCharacteristic
    init(_ characteristic: CBCharacteristic) { self.characteristic = characteristic }
}

/// Wrapper to make CBDescriptor sendable across actor boundaries
@usableFromInline
struct SendableDescriptor: @unchecked Sendable {
    let descriptor: CBDescriptor
    init(_ descriptor: CBDescriptor) { self.descriptor = descriptor }
}

/// Wrapper to make CBL2CAPChannel sendable across actor boundaries
@usableFromInline
struct SendableL2CAPChannel: @unchecked Sendable {
    let channel: CBL2CAPChannel
    init(_ channel: CBL2CAPChannel) { self.channel = channel }
}

/// Wrapper to make CBATTRequest sendable across actor boundaries
@usableFromInline
struct SendableATTRequest: @unchecked Sendable {
    let request: CBATTRequest
    init(_ request: CBATTRequest) { self.request = request }
}

/// Wrapper to make CBCentral sendable across actor boundaries
@usableFromInline
struct SendableCentral: @unchecked Sendable {
    let central: CBCentral
    init(_ central: CBCentral) { self.central = central }
}

/// Sendable struct for advertisement data extracted from CoreBluetooth
struct SendableAdvertisementData: Sendable {
    let localName: String?
    let serviceUUIDs: [String]
    let serviceData: [String: Data]
    let manufacturerData: Data?
    let txPowerLevel: Int?
    let peripheralName: String?
    let peripheralId: UUID

    init(peripheral: CBPeripheral, advertisementData: [String: Any]) {
        self.peripheralId = peripheral.identifier
        self.peripheralName = peripheral.name
        self.localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        self.serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map { $0.uuidString } ?? []
        self.serviceData = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data])?.reduce(into: [String: Data]()) { result, pair in
            result[pair.key.uuidString] = pair.value
        } ?? [:]
        self.manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        self.txPowerLevel = advertisementData[CBAdvertisementDataTxPowerLevelKey] as? Int
    }
}

// MARK: - Central Manager Backend

actor _CoreBluetoothCentralBackend: _CentralBackend {
    private let delegate: CentralManagerDelegate
    private nonisolated(unsafe) let centralManager: CBCentralManager
    private var stateUpdatesContinuation: AsyncStream<BluetoothState>.Continuation?
    private var scanContinuation: AsyncThrowingStream<ScanResult, Error>.Continuation?
    private var currentFilter: ScanFilter?
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var pendingConnections: [UUID: CheckedContinuation<any _PeripheralConnectionBackend, Error>] = [:]

    nonisolated var state: BluetoothState {
        BluetoothState(centralManager.state)
    }

    init() {
        let delegate = CentralManagerDelegate()
        self.delegate = delegate
        self.centralManager = CBCentralManager(delegate: delegate, queue: .main)
        Task { await setupDelegateCallbacks() }
    }

    private func setupDelegateCallbacks() {
        delegate.onStateUpdate = { [weak self] state in
            guard let self else { return }
            Task { await self.handleStateUpdate(state) }
        }

        delegate.onDiscover = { [weak self] peripheral, advertisementData, rssi in
            guard let self else { return }
            let wrapped = SendablePeripheral(peripheral)
            let advData = SendableAdvertisementData(peripheral: peripheral, advertisementData: advertisementData)
            let rssiValue = rssi.intValue
            Task { await self.handleDiscovery(wrapped, advData, rssiValue) }
        }

        delegate.onConnect = { [weak self] peripheral in
            guard let self else { return }
            let wrapped = SendablePeripheral(peripheral)
            Task { await self.handleConnect(wrapped) }
        }

        delegate.onFailToConnect = { [weak self] peripheral, error in
            guard let self else { return }
            let peripheralId = peripheral.identifier
            let errorMsg = error?.localizedDescription
            Task { await self.handleFailToConnect(peripheralId, errorMsg) }
        }

        delegate.onDisconnect = { [weak self] peripheral, error in
            guard let self else { return }
            let peripheralId = peripheral.identifier
            Task { await self.handleDisconnect(peripheralId) }
        }
    }

    private func handleStateUpdate(_ cbState: CBManagerState) {
        stateUpdatesContinuation?.yield(BluetoothState(cbState))
    }

    private func handleDiscovery(_ wrapped: SendablePeripheral, _ sendableAdvData: SendableAdvertisementData, _ rssi: Int) {
        let peripheral = wrapped.peripheral
        discoveredPeripherals[sendableAdvData.peripheralId] = peripheral

        let serviceUUIDs = sendableAdvData.serviceUUIDs.compactMap { uuidString -> BluetoothUUID? in
            if uuidString.count == 4 {
                return .bit16(UInt16(uuidString, radix: 16) ?? 0)
            } else if uuidString.count == 8 {
                return .bit32(UInt32(uuidString, radix: 16) ?? 0)
            } else if let uuid = UUID(uuidString: uuidString) {
                return .bit128(uuid)
            }
            return nil
        }

        let serviceData = sendableAdvData.serviceData.reduce(into: [BluetoothUUID: Data]()) { result, pair in
            if pair.key.count == 4 {
                if let val = UInt16(pair.key, radix: 16) {
                    result[.bit16(val)] = pair.value
                }
            } else if pair.key.count == 8 {
                if let val = UInt32(pair.key, radix: 16) {
                    result[.bit32(val)] = pair.value
                }
            } else if let uuid = UUID(uuidString: pair.key) {
                result[.bit128(uuid)] = pair.value
            }
        }

        var manufacturerData: ManufacturerData?
        if let mfgData = sendableAdvData.manufacturerData, mfgData.count >= 2 {
            let companyId = UInt16(mfgData[0]) | (UInt16(mfgData[1]) << 8)
            manufacturerData = ManufacturerData(companyIdentifier: companyId, data: mfgData.dropFirst(2))
        }

        let advData = AdvertisementData(
            localName: sendableAdvData.localName,
            serviceUUIDs: serviceUUIDs,
            serviceData: serviceData,
            manufacturerData: manufacturerData,
            txPowerLevel: sendableAdvData.txPowerLevel
        )

        if let prefix = currentFilter?.namePrefix {
            let name = sendableAdvData.localName ?? sendableAdvData.peripheralName ?? ""
            if !name.hasPrefix(prefix) {
                return
            }
        }

        let peripheralDevice = Peripheral(
            id: .uuid(sendableAdvData.peripheralId),
            name: sendableAdvData.localName ?? sendableAdvData.peripheralName
        )

        let result = ScanResult(
            peripheral: peripheralDevice,
            advertisementData: advData,
            rssi: rssi
        )

        scanContinuation?.yield(result)
    }

    private func handleConnect(_ wrapped: SendablePeripheral) {
        let peripheral = wrapped.peripheral
        if let continuation = pendingConnections.removeValue(forKey: peripheral.identifier) {
            let connectionBackend = _CoreBluetoothPeripheralConnectionBackend(peripheral: peripheral, centralManager: centralManager)
            continuation.resume(returning: connectionBackend)
        }
    }

    private func handleFailToConnect(_ peripheralId: UUID, _ errorMsg: String?) {
        if let continuation = pendingConnections.removeValue(forKey: peripheralId) {
            continuation.resume(throwing: BluetoothError.connectionFailed(errorMsg ?? "Unknown error"))
        }
    }

    private func handleDisconnect(_ peripheralId: UUID) {
        // Connection backend handles its own disconnect notifications
    }

    func stateUpdates() -> AsyncStream<BluetoothState> {
        AsyncStream { continuation in
            self.stateUpdatesContinuation = continuation
            continuation.yield(BluetoothState(centralManager.state))

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.clearStateUpdatesContinuation() }
            }
        }
    }

    private func clearStateUpdatesContinuation() {
        stateUpdatesContinuation = nil
    }

    func stopScan() async throws {
        centralManager.stopScan()
        scanContinuation?.finish()
        scanContinuation = nil
    }

    func pairingRequests() async throws -> AsyncThrowingStream<PairingRequest, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func removeBond(for peripheral: Peripheral) async throws {
        throw BluetoothError.unimplemented("Bond removal not available in CoreBluetooth - use system Settings")
    }

    func scan(
        filter: ScanFilter?,
        parameters: ScanParameters
    ) async throws -> AsyncThrowingStream<ScanResult, Error> {
        guard centralManager.state == .poweredOn else {
            throw BluetoothError.notReady("Bluetooth is not powered on")
        }

        currentFilter = filter

        let serviceUUIDs: [CBUUID]? = filter?.serviceUUIDs.isEmpty == false
            ? filter?.serviceUUIDs.map { $0.cbuuid }
            : nil

        var options: [String: Any] = [:]
        options[CBCentralManagerScanOptionAllowDuplicatesKey] = parameters.allowDuplicates

        return AsyncThrowingStream { continuation in
            self.scanContinuation = continuation

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.handleScanTermination() }
            }

            self.centralManager.scanForPeripherals(withServices: serviceUUIDs, options: options)
        }
    }

    private func handleScanTermination() {
        centralManager.stopScan()
        scanContinuation = nil
    }

    func connect(
        to peripheral: Peripheral,
        options: ConnectionOptions
    ) async throws -> any _PeripheralConnectionBackend {
        guard centralManager.state == .poweredOn else {
            throw BluetoothError.notReady("Bluetooth is not powered on")
        }

        guard let uuid = extractUUID(from: peripheral.id) else {
            throw BluetoothError.invalidPeripheral("Invalid peripheral ID format")
        }

        guard let cbPeripheral = discoveredPeripherals[uuid] ?? centralManager.retrievePeripherals(withIdentifiers: [uuid]).first else {
            throw BluetoothError.invalidPeripheral("Peripheral not found")
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.pendingConnections[uuid] = continuation
            self.centralManager.connect(cbPeripheral, options: nil)
        }
    }

    private nonisolated func extractUUID(from id: BluetoothDeviceID) -> UUID? {
        let rawValue = id.rawValue
        if rawValue.hasPrefix("uuid:") {
            let uuidString = String(rawValue.dropFirst(5))
            return UUID(uuidString: uuidString)
        }
        return nil
    }
}

// MARK: - Central Manager Delegate

private final class CentralManagerDelegate: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    var onStateUpdate: (@Sendable (CBManagerState) -> Void)?
    var onDiscover: (@Sendable (CBPeripheral, [String: Any], NSNumber) -> Void)?
    var onConnect: (@Sendable (CBPeripheral) -> Void)?
    var onFailToConnect: (@Sendable (CBPeripheral, Error?) -> Void)?
    var onDisconnect: (@Sendable (CBPeripheral, Error?) -> Void)?

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onStateUpdate?(central.state)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        onDiscover?(peripheral, advertisementData, RSSI)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onConnect?(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        onFailToConnect?(peripheral, error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        onDisconnect?(peripheral, error)
    }
}

// MARK: - Peripheral Connection Backend

actor _CoreBluetoothPeripheralConnectionBackend: _PeripheralConnectionBackend {
    private nonisolated(unsafe) let peripheral: CBPeripheral
    private nonisolated(unsafe) let centralManager: CBCentralManager
    private let delegate: PeripheralDelegate

    private var stateUpdatesContinuation: AsyncStream<PeripheralConnectionState>.Continuation?
    private var mtuUpdatesContinuation: AsyncStream<Int>.Continuation?
    private var pairingStateUpdatesContinuation: AsyncStream<PairingState>.Continuation?

    private var discoveredServices: [CBUUID: CBService] = [:]
    private var discoveredCharacteristics: [CBUUID: CBCharacteristic] = [:]
    private var characteristicsByService: [CBUUID: [CBCharacteristic]] = [:]

    private var serviceDiscoveryContinuation: CheckedContinuation<Void, Error>?
    private var lastDiscoveredServices: [CBService] = []
    private var characteristicDiscoveryContinuations: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var descriptorDiscoveryContinuations: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var lastDiscoveredDescriptors: [CBUUID: [CBDescriptor]] = [:]

    private var readValueContinuations: [CBUUID: CheckedContinuation<Data, Error>] = [:]
    private var writeValueContinuations: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var readDescriptorContinuations: [String: CheckedContinuation<Data, Error>] = [:]
    private var writeDescriptorContinuations: [String: CheckedContinuation<Void, Error>] = [:]
    private var rssiContinuation: CheckedContinuation<Int, Error>?

    private var notificationContinuations: [CBUUID: AsyncThrowingStream<GATTNotification, Error>.Continuation] = [:]
    private var setNotifyContinuations: [CBUUID: CheckedContinuation<Void, Error>] = [:]

    private var l2capChannelContinuation: CheckedContinuation<any L2CAPChannel, Error>?

    nonisolated var state: PeripheralConnectionState {
        switch peripheral.state {
        case .disconnected: return .disconnected(reason: nil)
        case .connecting: return .connecting
        case .connected: return .connected
        case .disconnecting: return .disconnected(reason: "Disconnecting")
        @unknown default: return .disconnected(reason: nil)
        }
    }

    nonisolated var mtu: Int {
        peripheral.maximumWriteValueLength(for: .withoutResponse) + 3
    }

    nonisolated var pairingState: PairingState {
        peripheral.state == .connected ? .paired : .unknown
    }

    init(peripheral: CBPeripheral, centralManager: CBCentralManager) {
        let delegate = PeripheralDelegate()
        self.peripheral = peripheral
        self.centralManager = centralManager
        self.delegate = delegate
        peripheral.delegate = delegate
        Task { await setupDelegateCallbacks() }
    }

    private func setupDelegateCallbacks() {
        delegate.onServicesDiscovered = { [weak self] services, error in
            guard let self else { return }
            let wrapped = services?.map { SendableService($0) }
            Task { await self.handleServicesDiscovered(wrapped, error) }
        }

        delegate.onCharacteristicsDiscovered = { [weak self] service, error in
            guard let self else { return }
            let wrapped = SendableService(service)
            Task { await self.handleCharacteristicsDiscovered(wrapped, error) }
        }

        delegate.onDescriptorsDiscovered = { [weak self] characteristic, error in
            guard let self else { return }
            let wrapped = SendableCharacteristic(characteristic)
            Task { await self.handleDescriptorsDiscovered(wrapped, error) }
        }

        delegate.onCharacteristicValueUpdated = { [weak self] characteristic, error in
            guard let self else { return }
            let uuid = characteristic.uuid
            let value = characteristic.value ?? Data()
            let isIndicate = characteristic.properties.contains(.indicate)
            Task { await self.handleCharacteristicValueUpdated(uuid, value, isIndicate, error) }
        }

        delegate.onCharacteristicWritten = { [weak self] characteristic, error in
            guard let self else { return }
            let uuid = characteristic.uuid
            Task { await self.handleCharacteristicWritten(uuid, error) }
        }

        delegate.onDescriptorValueUpdated = { [weak self] descriptor, error in
            guard let self else { return }
            let wrapped = SendableDescriptor(descriptor)
            Task { await self.handleDescriptorValueUpdated(wrapped, error) }
        }

        delegate.onDescriptorWritten = { [weak self] descriptor, error in
            guard let self else { return }
            let wrapped = SendableDescriptor(descriptor)
            Task { await self.handleDescriptorWritten(wrapped, error) }
        }

        delegate.onNotificationStateChanged = { [weak self] characteristic, error in
            guard let self else { return }
            let uuid = characteristic.uuid
            Task { await self.handleNotificationStateChanged(uuid, error) }
        }

        delegate.onRSSIRead = { [weak self] rssi, error in
            guard let self else { return }
            let value = rssi.intValue
            Task { await self.handleRSSIRead(value, error) }
        }

        delegate.onL2CAPChannelOpened = { [weak self] channel, error in
            guard let self else { return }
            let wrapped = channel.map { SendableL2CAPChannel($0) }
            Task { await self.handleL2CAPChannelOpened(wrapped, error) }
        }
    }

    private func handleServicesDiscovered(_ wrappedServices: [SendableService]?, _ error: Error?) {
        if let error {
            serviceDiscoveryContinuation?.resume(throwing: error)
        } else {
            let services = wrappedServices?.map { $0.service } ?? []
            lastDiscoveredServices = services
            for service in services {
                discoveredServices[service.uuid] = service
            }
            serviceDiscoveryContinuation?.resume(returning: ())
        }
        serviceDiscoveryContinuation = nil
    }

    private func handleCharacteristicsDiscovered(_ wrapped: SendableService, _ error: Error?) {
        let service = wrapped.service
        if let error {
            characteristicDiscoveryContinuations[service.uuid]?.resume(throwing: error)
        } else {
            let characteristics = service.characteristics ?? []
            characteristicsByService[service.uuid] = characteristics
            for char in characteristics {
                discoveredCharacteristics[char.uuid] = char
            }
            characteristicDiscoveryContinuations[service.uuid]?.resume(returning: ())
        }
        characteristicDiscoveryContinuations[service.uuid] = nil
    }

    private func handleDescriptorsDiscovered(_ wrapped: SendableCharacteristic, _ error: Error?) {
        let characteristic = wrapped.characteristic
        if let error {
            descriptorDiscoveryContinuations[characteristic.uuid]?.resume(throwing: error)
        } else {
            lastDiscoveredDescriptors[characteristic.uuid] = characteristic.descriptors ?? []
            descriptorDiscoveryContinuations[characteristic.uuid]?.resume(returning: ())
        }
        descriptorDiscoveryContinuations[characteristic.uuid] = nil
    }

    private func handleCharacteristicValueUpdated(_ uuid: CBUUID, _ value: Data, _ isIndicate: Bool, _ error: Error?) {
        // Check if this is a notification/indication
        if let continuation = notificationContinuations[uuid] {
            if let error {
                continuation.finish(throwing: error)
                notificationContinuations[uuid] = nil
            } else {
                let notification: GATTNotification = isIndicate ? .indication(value) : .notification(value)
                continuation.yield(notification)
            }
        }

        // Check if this is a read response
        if let continuation = readValueContinuations[uuid] {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: value)
            }
            readValueContinuations[uuid] = nil
        }
    }

    private func handleCharacteristicWritten(_ uuid: CBUUID, _ error: Error?) {
        if let continuation = writeValueContinuations[uuid] {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: ())
            }
            writeValueContinuations[uuid] = nil
        }
    }

    private func handleDescriptorValueUpdated(_ wrapped: SendableDescriptor, _ error: Error?) {
        let descriptor = wrapped.descriptor
        let key = descriptorKey(descriptor)
        if let continuation = readDescriptorContinuations[key] {
            if let error {
                continuation.resume(throwing: error)
            } else if let value = descriptor.value {
                if let data = value as? Data {
                    continuation.resume(returning: data)
                } else if let string = value as? String {
                    continuation.resume(returning: Data(string.utf8))
                } else if let number = value as? NSNumber {
                    var intValue = number.intValue
                    continuation.resume(returning: Data(bytes: &intValue, count: MemoryLayout<Int>.size))
                } else {
                    continuation.resume(returning: Data())
                }
            } else {
                continuation.resume(returning: Data())
            }
            readDescriptorContinuations[key] = nil
        }
    }

    private func handleDescriptorWritten(_ wrapped: SendableDescriptor, _ error: Error?) {
        let descriptor = wrapped.descriptor
        let key = descriptorKey(descriptor)
        if let continuation = writeDescriptorContinuations[key] {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: ())
            }
            writeDescriptorContinuations[key] = nil
        }
    }

    private func handleNotificationStateChanged(_ uuid: CBUUID, _ error: Error?) {
        if let continuation = setNotifyContinuations[uuid] {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: ())
            }
            setNotifyContinuations[uuid] = nil
        }
    }

    private func handleRSSIRead(_ value: Int, _ error: Error?) {
        if let error {
            rssiContinuation?.resume(throwing: error)
        } else {
            rssiContinuation?.resume(returning: value)
        }
        rssiContinuation = nil
    }

    private func handleL2CAPChannelOpened(_ wrapped: SendableL2CAPChannel?, _ error: Error?) {
        if let error {
            l2capChannelContinuation?.resume(throwing: error)
        } else if let wrapped {
            let l2capChannel = _CoreBluetoothL2CAPChannel(channel: wrapped.channel)
            l2capChannelContinuation?.resume(returning: l2capChannel)
        } else {
            l2capChannelContinuation?.resume(throwing: BluetoothError.l2capChannelError("Failed to open L2CAP channel"))
        }
        l2capChannelContinuation = nil
    }

    private nonisolated func descriptorKey(_ descriptor: CBDescriptor) -> String {
        "\(descriptor.characteristic?.uuid.uuidString ?? ""):\(descriptor.uuid.uuidString)"
    }

    func stateUpdates() -> AsyncStream<PeripheralConnectionState> {
        AsyncStream { continuation in
            continuation.yield(state)
            self.stateUpdatesContinuation = continuation
        }
    }

    func mtuUpdates() -> AsyncStream<Int> {
        AsyncStream { continuation in
            continuation.yield(mtu)
            self.mtuUpdatesContinuation = continuation
        }
    }

    func pairingStateUpdates() -> AsyncStream<PairingState> {
        AsyncStream { continuation in
            continuation.yield(pairingState)
            self.pairingStateUpdatesContinuation = continuation
        }
    }

    func disconnect() async {
        centralManager.cancelPeripheralConnection(peripheral)
        stateUpdatesContinuation?.yield(.disconnected(reason: "User requested disconnect"))
    }

    func discoverServices(_ uuids: [BluetoothUUID]?) async throws -> [GATTService] {
        let cbUUIDs = uuids?.map { $0.cbuuid }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.serviceDiscoveryContinuation = continuation
            self.peripheral.discoverServices(cbUUIDs)
        }

        return lastDiscoveredServices.map { cbService in
            GATTService(
                uuid: BluetoothUUID(cbService.uuid),
                isPrimary: cbService.isPrimary,
                instanceID: nil
            )
        }
    }

    func discoverCharacteristics(
        _ uuids: [BluetoothUUID]?,
        for service: GATTService
    ) async throws -> [GATTCharacteristic] {
        guard let cbService = discoveredServices[service.uuid.cbuuid] else {
            throw BluetoothError.serviceNotFound("Service \(service.uuid) not found")
        }

        let cbUUIDs = uuids?.map { $0.cbuuid }
        let serviceUUID = cbService.uuid

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.characteristicDiscoveryContinuations[serviceUUID] = continuation
            self.peripheral.discoverCharacteristics(cbUUIDs, for: cbService)
        }

        let characteristics = characteristicsByService[serviceUUID] ?? []
        return characteristics.map { cbChar in
            GATTCharacteristic(
                uuid: BluetoothUUID(cbChar.uuid),
                properties: GATTCharacteristicProperties(cbChar.properties),
                instanceID: nil,
                service: service
            )
        }
    }

    func readValue(for characteristic: GATTCharacteristic) async throws -> Data {
        guard let cbChar = discoveredCharacteristics[characteristic.uuid.cbuuid] else {
            throw BluetoothError.characteristicNotFound("Characteristic \(characteristic.uuid) not found")
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.readValueContinuations[cbChar.uuid] = continuation
            self.peripheral.readValue(for: cbChar)
        }
    }

    func writeValue(
        _ value: Data,
        for characteristic: GATTCharacteristic,
        type: GATTWriteType
    ) async throws {
        guard let cbChar = discoveredCharacteristics[characteristic.uuid.cbuuid] else {
            throw BluetoothError.characteristicNotFound("Characteristic \(characteristic.uuid) not found")
        }

        let cbWriteType: CBCharacteristicWriteType = type == .withResponse ? .withResponse : .withoutResponse

        if type == .withResponse {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.writeValueContinuations[cbChar.uuid] = continuation
                self.peripheral.writeValue(value, for: cbChar, type: cbWriteType)
            }
        } else {
            peripheral.writeValue(value, for: cbChar, type: cbWriteType)
        }
    }

    func notifications(
        for characteristic: GATTCharacteristic
    ) async throws -> AsyncThrowingStream<GATTNotification, Error> {
        guard let cbChar = discoveredCharacteristics[characteristic.uuid.cbuuid] else {
            throw BluetoothError.characteristicNotFound("Characteristic \(characteristic.uuid) not found")
        }

        let charUUID = cbChar.uuid

        return AsyncThrowingStream { continuation in
            self.notificationContinuations[charUUID] = continuation

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeNotificationContinuation(for: charUUID) }
            }
        }
    }

    private func removeNotificationContinuation(for uuid: CBUUID) {
        notificationContinuations[uuid] = nil
    }

    func setNotificationsEnabled(
        _ enabled: Bool,
        for characteristic: GATTCharacteristic,
        type: GATTClientSubscriptionType
    ) async throws {
        guard let cbChar = discoveredCharacteristics[characteristic.uuid.cbuuid] else {
            throw BluetoothError.characteristicNotFound("Characteristic \(characteristic.uuid) not found")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.setNotifyContinuations[cbChar.uuid] = continuation
            self.peripheral.setNotifyValue(enabled, for: cbChar)
        }
    }

    func discoverDescriptors(for characteristic: GATTCharacteristic) async throws -> [GATTDescriptor] {
        guard let cbChar = discoveredCharacteristics[characteristic.uuid.cbuuid] else {
            throw BluetoothError.characteristicNotFound("Characteristic \(characteristic.uuid) not found")
        }

        let charUUID = cbChar.uuid

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.descriptorDiscoveryContinuations[charUUID] = continuation
            self.peripheral.discoverDescriptors(for: cbChar)
        }

        let descriptors = lastDiscoveredDescriptors[charUUID] ?? []
        return descriptors.map { cbDescriptor in
            GATTDescriptor(
                uuid: BluetoothUUID(cbDescriptor.uuid),
                characteristic: characteristic
            )
        }
    }

    func readValue(for descriptor: GATTDescriptor) async throws -> Data {
        guard let cbChar = discoveredCharacteristics[descriptor.characteristic.uuid.cbuuid],
              let cbDescriptor = cbChar.descriptors?.first(where: { $0.uuid == descriptor.uuid.cbuuid }) else {
            throw BluetoothError.descriptorNotFound("Descriptor \(descriptor.uuid) not found")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let key = self.descriptorKey(cbDescriptor)
            self.readDescriptorContinuations[key] = continuation
            self.peripheral.readValue(for: cbDescriptor)
        }
    }

    func writeValue(_ value: Data, for descriptor: GATTDescriptor) async throws {
        guard let cbChar = discoveredCharacteristics[descriptor.characteristic.uuid.cbuuid],
              let cbDescriptor = cbChar.descriptors?.first(where: { $0.uuid == descriptor.uuid.cbuuid }) else {
            throw BluetoothError.descriptorNotFound("Descriptor \(descriptor.uuid) not found")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let key = self.descriptorKey(cbDescriptor)
            self.writeDescriptorContinuations[key] = continuation
            self.peripheral.writeValue(value, for: cbDescriptor)
        }
    }

    func readRSSI() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            self.rssiContinuation = continuation
            self.peripheral.readRSSI()
        }
    }

    func openL2CAPChannel(
        psm: L2CAPPSM,
        parameters: L2CAPChannelParameters
    ) async throws -> any L2CAPChannel {
        try await withCheckedThrowingContinuation { continuation in
            self.l2capChannelContinuation = continuation
            self.peripheral.openL2CAPChannel(CBL2CAPPSM(psm.rawValue))
        }
    }

    func updateConnectionParameters(_ parameters: ConnectionParameters) async throws {
        throw BluetoothError.unimplemented("Connection parameter updates not available in CoreBluetooth")
    }

    func updatePHY(_ preference: PHYPreference) async throws {
        throw BluetoothError.unimplemented("PHY updates not available in CoreBluetooth")
    }
}

// MARK: - Peripheral Delegate

private final class PeripheralDelegate: NSObject, CBPeripheralDelegate, @unchecked Sendable {
    var onServicesDiscovered: (@Sendable ([CBService]?, Error?) -> Void)?
    var onCharacteristicsDiscovered: (@Sendable (CBService, Error?) -> Void)?
    var onDescriptorsDiscovered: (@Sendable (CBCharacteristic, Error?) -> Void)?
    var onCharacteristicValueUpdated: (@Sendable (CBCharacteristic, Error?) -> Void)?
    var onCharacteristicWritten: (@Sendable (CBCharacteristic, Error?) -> Void)?
    var onDescriptorValueUpdated: (@Sendable (CBDescriptor, Error?) -> Void)?
    var onDescriptorWritten: (@Sendable (CBDescriptor, Error?) -> Void)?
    var onNotificationStateChanged: (@Sendable (CBCharacteristic, Error?) -> Void)?
    var onRSSIRead: (@Sendable (NSNumber, Error?) -> Void)?
    var onL2CAPChannelOpened: (@Sendable (CBL2CAPChannel?, Error?) -> Void)?

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        onServicesDiscovered?(peripheral.services, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        onCharacteristicsDiscovered?(service, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        onDescriptorsDiscovered?(characteristic, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        onCharacteristicValueUpdated?(characteristic, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        onCharacteristicWritten?(characteristic, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        onDescriptorValueUpdated?(descriptor, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: Error?) {
        onDescriptorWritten?(descriptor, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        onNotificationStateChanged?(characteristic, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        onRSSIRead?(RSSI, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        onL2CAPChannelOpened?(channel, error)
    }
}

// MARK: - Peripheral Manager Backend

actor _CoreBluetoothPeripheralBackend: _PeripheralBackend {
    private let delegate: PeripheralManagerDelegate
    private nonisolated(unsafe) let peripheralManager: CBPeripheralManager
    private var stateUpdatesContinuation: AsyncStream<BluetoothState>.Continuation?
    private var connectionEventsContinuation: AsyncThrowingStream<PeripheralConnectionEvent, Error>.Continuation?
    private var gattRequestsContinuation: AsyncThrowingStream<GATTServerRequest, Error>.Continuation?

    private var registeredServices: [CBUUID: CBMutableService] = [:]
    private var characteristicMap: [CBUUID: CBMutableCharacteristic] = [:]
    private var serviceCharacteristics: [CBUUID: [GATTCharacteristic]] = [:]

    private var addServiceContinuation: CheckedContinuation<GATTServiceRegistration, Error>?
    private var pendingServiceDefinition: GATTServiceDefinition?

    private var pendingReadRequests: [UUID: CBATTRequest] = [:]
    private var pendingWriteRequests: [UUID: CBATTRequest] = [:]

    private var l2capPSMContinuation: CheckedContinuation<L2CAPPSM, Error>?
    private var publishedL2CAPChannels: [UInt16: AsyncThrowingStream<any L2CAPChannel, Error>.Continuation] = [:]

    nonisolated var state: BluetoothState {
        BluetoothState(peripheralManager.state)
    }

    init() {
        let delegate = PeripheralManagerDelegate()
        self.delegate = delegate
        self.peripheralManager = CBPeripheralManager(delegate: delegate, queue: .main)
        Task { await setupDelegateCallbacks() }
    }

    private func setupDelegateCallbacks() {
        delegate.onStateUpdate = { [weak self] state in
            guard let self else { return }
            Task { await self.handleStateUpdate(state) }
        }

        delegate.onServiceAdded = { [weak self] service, error in
            guard let self else { return }
            let wrapped = service.map { SendableService($0) }
            Task { await self.handleServiceAdded(wrapped, error) }
        }

        delegate.onCentralSubscribed = { [weak self] central, characteristic in
            guard let self else { return }
            let wrappedCentral = SendableCentral(central)
            let wrappedChar = SendableCharacteristic(characteristic)
            Task { await self.handleCentralSubscribed(wrappedCentral, wrappedChar) }
        }

        delegate.onCentralUnsubscribed = { [weak self] central, characteristic in
            guard let self else { return }
            let wrappedCentral = SendableCentral(central)
            let wrappedChar = SendableCharacteristic(characteristic)
            Task { await self.handleCentralUnsubscribed(wrappedCentral, wrappedChar) }
        }

        delegate.onReadRequest = { [weak self] request in
            guard let self else { return }
            let wrapped = SendableATTRequest(request)
            Task { await self.handleReadRequest(wrapped) }
        }

        delegate.onWriteRequests = { [weak self] requests in
            guard let self else { return }
            let wrapped = requests.map { SendableATTRequest($0) }
            Task { await self.handleWriteRequests(wrapped) }
        }

        delegate.onL2CAPChannelPublished = { [weak self] psm, error in
            guard let self else { return }
            Task { await self.handleL2CAPChannelPublished(psm, error) }
        }

        delegate.onL2CAPChannelOpened = { [weak self] channel, error in
            guard let self else { return }
            let wrapped = channel.map { SendableL2CAPChannel($0) }
            Task { await self.handleL2CAPChannelOpened(wrapped, error) }
        }
    }

    private func handleStateUpdate(_ cbState: CBManagerState) {
        stateUpdatesContinuation?.yield(BluetoothState(cbState))
    }

    private func handleServiceAdded(_ wrapped: SendableService?, _ error: Error?) {
        guard let continuation = addServiceContinuation else { return }

        if let error {
            continuation.resume(throwing: error)
        } else if let wrapped, pendingServiceDefinition != nil {
            let service = wrapped.service
            let gattService = GATTService(
                uuid: BluetoothUUID(service.uuid),
                isPrimary: service.isPrimary,
                instanceID: nil
            )

            let characteristics = serviceCharacteristics[service.uuid] ?? []
            let registration = GATTServiceRegistration(service: gattService, characteristics: characteristics)
            continuation.resume(returning: registration)
        } else {
            continuation.resume(throwing: BluetoothError.serviceRegistrationFailed("Failed to add service"))
        }

        addServiceContinuation = nil
        pendingServiceDefinition = nil
    }

    private func handleCentralSubscribed(_ wrappedCentral: SendableCentral, _ wrappedChar: SendableCharacteristic) {
        let central = wrappedCentral.central
        let characteristic = wrappedChar.characteristic
        let centralDevice = Central(id: .uuid(central.identifier), name: nil)

        if let gattChar = findGATTCharacteristic(for: characteristic.uuid) {
            let subscription = GATTSubscription(
                central: centralDevice,
                characteristic: gattChar,
                type: characteristic.properties.contains(.indicate) ? .indication : .notification
            )
            gattRequestsContinuation?.yield(.subscribe(subscription))
        }

        connectionEventsContinuation?.yield(.connected(centralDevice))
    }

    private func handleCentralUnsubscribed(_ wrappedCentral: SendableCentral, _ wrappedChar: SendableCharacteristic) {
        let central = wrappedCentral.central
        let characteristic = wrappedChar.characteristic
        let centralDevice = Central(id: .uuid(central.identifier), name: nil)

        if let gattChar = findGATTCharacteristic(for: characteristic.uuid) {
            let subscription = GATTSubscription(
                central: centralDevice,
                characteristic: gattChar,
                type: characteristic.properties.contains(.indicate) ? .indication : .notification
            )
            gattRequestsContinuation?.yield(.unsubscribe(subscription))
        }
    }

    private func handleReadRequest(_ wrapped: SendableATTRequest) {
        let request = wrapped.request
        guard let gattChar = findGATTCharacteristic(for: request.characteristic.uuid) else {
            peripheralManager.respond(to: request, withResult: .attributeNotFound)
            return
        }

        let central = Central(id: .uuid(request.central.identifier), name: nil)
        let requestId = UUID()

        pendingReadRequests[requestId] = request

        let readRequest = GATTReadRequest(
            central: central,
            characteristic: gattChar,
            offset: request.offset
        ) { [weak self] result in
            guard let self else { return }
            await self.respondToReadRequest(requestId: requestId, result: result)
        }

        gattRequestsContinuation?.yield(.read(readRequest))
    }

    private func respondToReadRequest(requestId: UUID, result: Result<Data, GATTError>) {
        guard let request = pendingReadRequests.removeValue(forKey: requestId) else { return }

        switch result {
        case .success(let data):
            request.value = data
            peripheralManager.respond(to: request, withResult: .success)
        case .failure(let error):
            peripheralManager.respond(to: request, withResult: error.cbATTError)
        }
    }

    private func handleWriteRequests(_ wrappedRequests: [SendableATTRequest]) {
        for wrapped in wrappedRequests {
            let request = wrapped.request
            guard let gattChar = findGATTCharacteristic(for: request.characteristic.uuid) else {
                peripheralManager.respond(to: request, withResult: .attributeNotFound)
                continue
            }

            let central = Central(id: .uuid(request.central.identifier), name: nil)
            let requestId = UUID()

            pendingWriteRequests[requestId] = request

            let writeRequest = GATTWriteRequest(
                central: central,
                characteristic: gattChar,
                value: request.value ?? Data(),
                offset: request.offset,
                writeType: .withResponse,
                isPreparedWrite: false
            ) { [weak self] result in
                guard let self else { return }
                await self.respondToWriteRequest(requestId: requestId, result: result)
            }

            gattRequestsContinuation?.yield(.write(writeRequest))
        }
    }

    private func respondToWriteRequest(requestId: UUID, result: Result<Void, GATTError>) {
        guard let request = pendingWriteRequests.removeValue(forKey: requestId) else { return }

        switch result {
        case .success:
            peripheralManager.respond(to: request, withResult: .success)
        case .failure(let error):
            peripheralManager.respond(to: request, withResult: error.cbATTError)
        }
    }

    private func findGATTCharacteristic(for uuid: CBUUID) -> GATTCharacteristic? {
        for (_, characteristics) in serviceCharacteristics {
            if let char = characteristics.first(where: { $0.uuid.cbuuid == uuid }) {
                return char
            }
        }
        return nil
    }

    private func handleL2CAPChannelPublished(_ psm: CBL2CAPPSM, _ error: Error?) {
        if let error {
            l2capPSMContinuation?.resume(throwing: error)
        } else {
            l2capPSMContinuation?.resume(returning: L2CAPPSM(rawValue: psm))
        }
        l2capPSMContinuation = nil
    }

    private func handleL2CAPChannelOpened(_ wrapped: SendableL2CAPChannel?, _ error: Error?) {
        guard let wrapped else { return }

        if let continuation = publishedL2CAPChannels[wrapped.channel.psm] {
            let l2capChannel = _CoreBluetoothL2CAPChannel(channel: wrapped.channel)
            continuation.yield(l2capChannel)
        }
    }

    func stateUpdates() -> AsyncStream<BluetoothState> {
        AsyncStream { continuation in
            self.stateUpdatesContinuation = continuation
            continuation.yield(BluetoothState(peripheralManager.state))
        }
    }

    func connectionEvents() async throws -> AsyncThrowingStream<PeripheralConnectionEvent, Error> {
        AsyncThrowingStream { continuation in
            self.connectionEventsContinuation = continuation
        }
    }

    func pairingRequests() async throws -> AsyncThrowingStream<PairingRequest, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func startAdvertising(advertisingData: AdvertisementData, scanResponseData: AdvertisementData?, parameters: AdvertisingParameters) async throws {
        guard peripheralManager.state == .poweredOn else {
            throw BluetoothError.notReady("Bluetooth is not powered on")
        }

        var advData: [String: Any] = [:]

        if let localName = advertisingData.localName {
            advData[CBAdvertisementDataLocalNameKey] = localName
        }

        if !advertisingData.serviceUUIDs.isEmpty {
            advData[CBAdvertisementDataServiceUUIDsKey] = advertisingData.serviceUUIDs.map { $0.cbuuid }
        }

        peripheralManager.startAdvertising(advData)
    }

    func startAdvertisingSet(_ configuration: AdvertisingSetConfiguration) async throws -> AdvertisingSetID {
        throw BluetoothError.unimplemented("Extended advertising sets not available in CoreBluetooth")
    }

    func updateAdvertisingSet(_ id: AdvertisingSetID, configuration: AdvertisingSetConfiguration) async throws {
        throw BluetoothError.unimplemented("Extended advertising sets not available in CoreBluetooth")
    }

    func stopAdvertising() async {
        peripheralManager.stopAdvertising()
    }

    func stopAdvertisingSet(_ id: AdvertisingSetID) async {
        // No-op for CoreBluetooth
    }

    func disconnect(_ central: Central) async throws {
        throw BluetoothError.unimplemented("Direct disconnect not available in CoreBluetooth peripheral role")
    }

    func removeBond(for central: Central) async throws {
        throw BluetoothError.unimplemented("Bond removal not available in CoreBluetooth - use system Settings")
    }

    func addService(_ service: GATTServiceDefinition) async throws -> GATTServiceRegistration {
        guard peripheralManager.state == .poweredOn else {
            throw BluetoothError.notReady("Bluetooth is not powered on")
        }

        let cbService = CBMutableService(type: service.uuid.cbuuid, primary: service.isPrimary)

        var cbCharacteristics: [CBMutableCharacteristic] = []
        var gattCharacteristics: [GATTCharacteristic] = []

        let gattService = GATTService(
            uuid: BluetoothUUID(cbService.uuid),
            isPrimary: service.isPrimary,
            instanceID: nil
        )

        for charDef in service.characteristics {
            let cbChar = CBMutableCharacteristic(
                type: charDef.uuid.cbuuid,
                properties: charDef.properties.cbProperties,
                value: charDef.properties.contains(.read) ? nil : charDef.initialValue,
                permissions: charDef.permissions.cbPermissions
            )

            cbCharacteristics.append(cbChar)
            characteristicMap[cbChar.uuid] = cbChar

            let gattChar = GATTCharacteristic(
                uuid: charDef.uuid,
                properties: charDef.properties,
                instanceID: nil,
                service: gattService
            )
            gattCharacteristics.append(gattChar)
        }

        cbService.characteristics = cbCharacteristics
        registeredServices[cbService.uuid] = cbService
        serviceCharacteristics[cbService.uuid] = gattCharacteristics
        pendingServiceDefinition = service

        return try await withCheckedThrowingContinuation { continuation in
            self.addServiceContinuation = continuation
            self.peripheralManager.add(cbService)
        }
    }

    func removeService(_ registration: GATTServiceRegistration) async throws {
        guard let cbService = registeredServices[registration.service.uuid.cbuuid] else {
            throw BluetoothError.serviceNotFound("Service \(registration.service.uuid) not found")
        }

        peripheralManager.remove(cbService)
        registeredServices[registration.service.uuid.cbuuid] = nil
        serviceCharacteristics[registration.service.uuid.cbuuid] = nil

        for char in registration.characteristics {
            characteristicMap[char.uuid.cbuuid] = nil
        }
    }

    func gattRequests() async throws -> AsyncThrowingStream<GATTServerRequest, Error> {
        AsyncThrowingStream { continuation in
            self.gattRequestsContinuation = continuation
        }
    }

    func updateValue(_ value: Data, for characteristic: GATTCharacteristic, type: GATTServerUpdateType) async throws {
        guard let cbChar = characteristicMap[characteristic.uuid.cbuuid] else {
            throw BluetoothError.characteristicNotFound("Characteristic \(characteristic.uuid) not found")
        }

        let success = peripheralManager.updateValue(value, for: cbChar, onSubscribedCentrals: nil)
        if !success {
            throw BluetoothError.notificationFailed("Failed to send notification")
        }
    }

    func publishL2CAPChannel(parameters: L2CAPChannelParameters) async throws -> L2CAPPSM {
        guard peripheralManager.state == .poweredOn else {
            throw BluetoothError.notReady("Bluetooth is not powered on")
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.l2capPSMContinuation = continuation
            self.peripheralManager.publishL2CAPChannel(withEncryption: parameters.requiresEncryption)
        }
    }

    func incomingL2CAPChannels(psm: L2CAPPSM) async throws -> AsyncThrowingStream<any L2CAPChannel, Error> {
        AsyncThrowingStream { continuation in
            self.publishedL2CAPChannels[psm.rawValue] = continuation

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeL2CAPChannelContinuation(for: psm.rawValue) }
            }
        }
    }

    private func removeL2CAPChannelContinuation(for psm: UInt16) {
        publishedL2CAPChannels[psm] = nil
    }
}

// MARK: - Peripheral Manager Delegate

private final class PeripheralManagerDelegate: NSObject, CBPeripheralManagerDelegate, @unchecked Sendable {
    var onStateUpdate: (@Sendable (CBManagerState) -> Void)?
    var onServiceAdded: (@Sendable (CBService?, Error?) -> Void)?
    var onCentralSubscribed: (@Sendable (CBCentral, CBCharacteristic) -> Void)?
    var onCentralUnsubscribed: (@Sendable (CBCentral, CBCharacteristic) -> Void)?
    var onReadRequest: (@Sendable (CBATTRequest) -> Void)?
    var onWriteRequests: (@Sendable ([CBATTRequest]) -> Void)?
    var onL2CAPChannelPublished: (@Sendable (CBL2CAPPSM, Error?) -> Void)?
    var onL2CAPChannelOpened: (@Sendable (CBL2CAPChannel?, Error?) -> Void)?

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        onStateUpdate?(peripheral.state)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        onServiceAdded?(service, error)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        onCentralSubscribed?(central, characteristic)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        onCentralUnsubscribed?(central, characteristic)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        onReadRequest?(request)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        onWriteRequests?(requests)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        onL2CAPChannelPublished?(PSM, error)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        onL2CAPChannelOpened?(channel, error)
    }
}

// MARK: - L2CAP Channel

final class _CoreBluetoothL2CAPChannel: L2CAPChannel, @unchecked Sendable {
    let psm: L2CAPPSM
    let mtu: Int

    private let channel: CBL2CAPChannel
    private let inputStream: InputStream
    private let outputStream: OutputStream
    private var incomingContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private let streamDelegate: L2CAPStreamDelegate
    private let lock = NSLock()

    init(channel: CBL2CAPChannel) {
        self.channel = channel
        self.psm = L2CAPPSM(rawValue: channel.psm)
        self.mtu = Int(channel.outputStream.property(forKey: .dataWrittenToMemoryStreamKey) as? Int ?? 512)
        self.inputStream = channel.inputStream
        self.outputStream = channel.outputStream

        let delegate = L2CAPStreamDelegate()
        self.streamDelegate = delegate

        inputStream.delegate = delegate
        outputStream.delegate = delegate

        inputStream.schedule(in: .main, forMode: .default)
        outputStream.schedule(in: .main, forMode: .default)

        inputStream.open()
        outputStream.open()

        delegate.onDataAvailable = { [weak self] in
            self?.readAvailableData()
        }

        delegate.onError = { [weak self] error in
            self?.handleStreamError(error)
        }
    }

    private func readAvailableData() {
        lock.lock()
        defer { lock.unlock() }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = inputStream.read(&buffer, maxLength: buffer.count)

        if bytesRead > 0 {
            let data = Data(buffer.prefix(bytesRead))
            incomingContinuation?.yield(data)
        }
    }

    private func handleStreamError(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }

        incomingContinuation?.finish(throwing: error)
        incomingContinuation = nil
    }

    func send(_ data: Data) async throws {
        guard outputStream.hasSpaceAvailable else {
            throw BluetoothError.l2capChannelError("Output stream not available")
        }

        let bytesWritten = data.withUnsafeBytes { buffer in
            outputStream.write(buffer.bindMemory(to: UInt8.self).baseAddress!, maxLength: data.count)
        }

        if bytesWritten < 0 {
            throw BluetoothError.l2capChannelError("Failed to write to L2CAP channel")
        }
    }

    func incoming() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            self.lock.lock()
            self.incomingContinuation = continuation
            self.lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.incomingContinuation = nil
                self.lock.unlock()
            }
        }
    }

    func close() async {
        closeStreams()
    }

    private func closeStreams() {
        lock.lock()
        incomingContinuation?.finish()
        incomingContinuation = nil
        lock.unlock()

        inputStream.close()
        outputStream.close()
    }
}

// MARK: - L2CAP Stream Delegate

private final class L2CAPStreamDelegate: NSObject, Foundation.StreamDelegate, @unchecked Sendable {
    var onDataAvailable: (() -> Void)?
    var onError: ((Error) -> Void)?

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            onDataAvailable?()
        case .errorOccurred:
            if let error = aStream.streamError {
                onError?(error)
            }
        default:
            break
        }
    }
}

// MARK: - GATTError Extensions

extension GATTError {
    var cbATTError: CBATTError.Code {
        switch self {
        case .att(let attError):
            switch attError {
            case .invalidHandle: return .invalidHandle
            case .readNotPermitted: return .readNotPermitted
            case .writeNotPermitted: return .writeNotPermitted
            case .invalidPdu: return .invalidPdu
            case .insufficientAuthentication: return .insufficientAuthentication
            case .requestNotSupported: return .requestNotSupported
            case .invalidOffset: return .invalidOffset
            case .insufficientAuthorization: return .insufficientAuthorization
            case .prepareQueueFull: return .prepareQueueFull
            case .attributeNotFound: return .attributeNotFound
            case .attributeNotLong: return .attributeNotLong
            case .insufficientEncryptionKeySize: return .insufficientEncryptionKeySize
            case .invalidAttributeValueLength: return .invalidAttributeValueLength
            case .unlikelyError: return .unlikelyError
            case .insufficientEncryption: return .insufficientEncryption
            case .unsupportedGroupType: return .unsupportedGroupType
            case .insufficientResources: return .insufficientResources
            }
        case .other:
            return .unlikelyError
        }
    }
}

#endif
