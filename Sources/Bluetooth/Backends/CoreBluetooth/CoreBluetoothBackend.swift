#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
import Synchronization
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
            // 16-bit UUID (e.g., "180A")
            guard let value = UInt16(uuidString, radix: 16) else {
                // Fallback: treat as full UUID using CoreBluetooth's standard base UUID expansion
                self = .bit128(UUID(uuidString: "0000\(uuidString)-0000-1000-8000-00805F9B34FB") ?? UUID())
                return
            }
            self = .bit16(value)
        } else if uuidString.count == 8 {
            // 32-bit UUID (e.g., "0000180A")
            guard let value = UInt32(uuidString, radix: 16) else {
                self = .bit128(UUID(uuidString: "\(uuidString)-0000-1000-8000-00805F9B34FB") ?? UUID())
                return
            }
            self = .bit32(value)
        } else {
            // 128-bit UUID
            guard let uuid = UUID(uuidString: uuidString) else {
                // This shouldn't happen with CoreBluetooth, but handle gracefully
                assertionFailure("Invalid UUID string from CoreBluetooth: \(uuidString)")
                self = .bit128(UUID())
                return
            }
            self = .bit128(uuid)
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
// These wrappers are necessary because CoreBluetooth types are not Sendable.
// With @preconcurrency import, we can wrap them in Sendable structs.
// Safety: CoreBluetooth objects are thread-safe when accessed from their designated queue (.main)

@usableFromInline
struct SendablePeripheral: Sendable {
    @preconcurrency let peripheral: CBPeripheral
    init(_ peripheral: CBPeripheral) { self.peripheral = peripheral }
}

@usableFromInline
struct SendableService: Sendable {
    @preconcurrency let service: CBService
    init(_ service: CBService) { self.service = service }
}

@usableFromInline
struct SendableCharacteristic: Sendable {
    @preconcurrency let characteristic: CBCharacteristic
    init(_ characteristic: CBCharacteristic) { self.characteristic = characteristic }
}

@usableFromInline
struct SendableDescriptor: Sendable {
    @preconcurrency let descriptor: CBDescriptor
    init(_ descriptor: CBDescriptor) { self.descriptor = descriptor }
}

@usableFromInline
struct SendableL2CAPChannel: Sendable {
    @preconcurrency let channel: CBL2CAPChannel
    init(_ channel: CBL2CAPChannel) { self.channel = channel }
}

@usableFromInline
struct SendableATTRequest: Sendable {
    @preconcurrency let request: CBATTRequest
    init(_ request: CBATTRequest) { self.request = request }
}

@usableFromInline
struct SendableCentral: Sendable {
    @preconcurrency let central: CBCentral
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

struct _CoreBluetoothCentralBackend: _CentralBackend {
    private let controller: _CoreBluetoothCentralController

    var state: BluetoothState {
        controller.state
    }

    init() {
        self.controller = _CoreBluetoothCentralController()
    }

    func stateUpdates() -> AsyncStream<BluetoothState> {
        let currentState = state
        return AsyncStream { continuation in
            continuation.yield(currentState)
            Task {
                await controller.setStateUpdatesContinuation(continuation)
            }
            continuation.onTermination = { _ in
                Task { await controller.clearStateUpdatesContinuation() }
            }
        }
    }

    func stopScan() async throws {
        await controller.stopScan()
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
        try await controller.scan(filter: filter, parameters: parameters)
    }

    func connect(
        to peripheral: Peripheral,
        options: ConnectionOptions
    ) async throws -> any _PeripheralConnectionBackend {
        try await controller.connect(to: peripheral, options: options)
    }
}

private actor _CoreBluetoothCentralController {
    private let delegate: CentralManagerDelegate
    private let centralManager: CBCentralManager
    private let cachedState: Mutex<BluetoothState>
    private var stateUpdatesContinuation: AsyncStream<BluetoothState>.Continuation?
    private var scanContinuation: AsyncThrowingStream<ScanResult, Error>.Continuation?
    private var currentFilter: ScanFilter?
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var pendingConnections: [UUID: CheckedContinuation<any _PeripheralConnectionBackend, Error>] = [:]
    private var activeConnections: [UUID: _CoreBluetoothPeripheralConnectionBackend] = [:]

    nonisolated var state: BluetoothState {
        cachedState.withLock { $0 }
    }

    init() {
        let delegate = CentralManagerDelegate()
        self.delegate = delegate
        let centralManager = CBCentralManager(delegate: delegate, queue: .main)
        self.centralManager = centralManager
        self.cachedState = Mutex(BluetoothState(centralManager.state))
        Task { await setupDelegateCallbacks() }
    }

    private func setupDelegateCallbacks() {
        delegate.onStateUpdate = { [weak self] state in
            guard let self else { return }
            Task { await self.handleStateUpdate(state) }
        }

        delegate.onDiscover = { [weak self] peripheral, advertisementData, rssi in
            guard let self else { return }
            let advData = SendableAdvertisementData(peripheral: peripheral, advertisementData: advertisementData)
            let rssiValue = rssi.intValue
            Task { await self.handleDiscovery(peripheral, advData, rssiValue) }
        }

        delegate.onConnect = { [weak self] peripheral in
            guard let self else { return }
            Task { await self.handleConnect(peripheral) }
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
        let newState = BluetoothState(cbState)
        cachedState.withLock { $0 = newState }
        stateUpdatesContinuation?.yield(newState)
    }

    private func handleDiscovery(_ peripheral: CBPeripheral, _ sendableAdvData: SendableAdvertisementData, _ rssi: Int) {
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

    private func handleConnect(_ peripheral: CBPeripheral) {
        if let continuation = pendingConnections.removeValue(forKey: peripheral.identifier) {
            let connectionBackend = _CoreBluetoothPeripheralConnectionBackend(peripheral: peripheral, centralManager: centralManager)
            activeConnections[peripheral.identifier] = connectionBackend
            continuation.resume(returning: connectionBackend)
        }
    }

    private func handleFailToConnect(_ peripheralId: UUID, _ errorMsg: String?) {
        if let continuation = pendingConnections.removeValue(forKey: peripheralId) {
            continuation.resume(throwing: BluetoothError.connectionFailed(errorMsg ?? "Unknown error"))
        }
    }

    private func handleDisconnect(_ peripheralId: UUID) {
        if let continuation = pendingConnections.removeValue(forKey: peripheralId) {
            continuation.resume(throwing: BluetoothError.connectionFailed("Peripheral disconnected during connection"))
        }

        if let connectionBackend = activeConnections.removeValue(forKey: peripheralId) {
            Task {
                await connectionBackend.handleRemoteDisconnect(reason: "Peripheral disconnected")
            }
        }
    }

    func setStateUpdatesContinuation(_ continuation: AsyncStream<BluetoothState>.Continuation) {
        stateUpdatesContinuation = continuation
    }

    func clearStateUpdatesContinuation() {
        stateUpdatesContinuation = nil
    }

    func stopScan() {
        centralManager.stopScan()
        scanContinuation?.finish()
        scanContinuation = nil
    }

    func scan(
        filter: ScanFilter?,
        parameters: ScanParameters
    ) throws -> AsyncThrowingStream<ScanResult, Error> {
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

        discoveredPeripherals[uuid] = cbPeripheral

        let timeoutSeconds: Double = 30.0

        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(timeoutSeconds))
            self.handleConnectionTimeout(uuid: uuid, peripheral: cbPeripheral)
        }

        do {
            let result = try await withCheckedThrowingContinuation { continuation in
                self.pendingConnections[uuid] = continuation
                self.centralManager.connect(cbPeripheral, options: nil)
            }
            timeoutTask.cancel()
            return result
        } catch {
            timeoutTask.cancel()
            throw error
        }
    }

    private func handleConnectionTimeout(uuid: UUID, peripheral: CBPeripheral) {
        if let continuation = pendingConnections.removeValue(forKey: uuid) {
            centralManager.cancelPeripheralConnection(peripheral)
            continuation.resume(throwing: BluetoothError.connectionFailed("Connection timed out after 30 seconds"))
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

private final class CentralManagerDelegate: NSObject, CBCentralManagerDelegate, Sendable {
    private struct Callbacks: Sendable {
        var onStateUpdate: (@Sendable (CBManagerState) -> Void)?
        var onDiscover: (@Sendable (CBPeripheral, [String: Any], NSNumber) -> Void)?
        var onConnect: (@Sendable (CBPeripheral) -> Void)?
        var onFailToConnect: (@Sendable (CBPeripheral, Error?) -> Void)?
        var onDisconnect: (@Sendable (CBPeripheral, Error?) -> Void)?
    }

    private let callbacks = Mutex(Callbacks())

    var onStateUpdate: (@Sendable (CBManagerState) -> Void)? {
        get { callbacks.withLock { $0.onStateUpdate } }
        set { callbacks.withLock { $0.onStateUpdate = newValue } }
    }

    var onDiscover: (@Sendable (CBPeripheral, [String: Any], NSNumber) -> Void)? {
        get { callbacks.withLock { $0.onDiscover } }
        set { callbacks.withLock { $0.onDiscover = newValue } }
    }

    var onConnect: (@Sendable (CBPeripheral) -> Void)? {
        get { callbacks.withLock { $0.onConnect } }
        set { callbacks.withLock { $0.onConnect = newValue } }
    }

    var onFailToConnect: (@Sendable (CBPeripheral, Error?) -> Void)? {
        get { callbacks.withLock { $0.onFailToConnect } }
        set { callbacks.withLock { $0.onFailToConnect = newValue } }
    }

    var onDisconnect: (@Sendable (CBPeripheral, Error?) -> Void)? {
        get { callbacks.withLock { $0.onDisconnect } }
        set { callbacks.withLock { $0.onDisconnect = newValue } }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        callbacks.withLock { $0.onStateUpdate }?(central.state)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        callbacks.withLock { $0.onDiscover }?(peripheral, advertisementData, RSSI)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        callbacks.withLock { $0.onConnect }?(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        callbacks.withLock { $0.onFailToConnect }?(peripheral, error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        callbacks.withLock { $0.onDisconnect }?(peripheral, error)
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

    // Concurrent operation handling:
    // We use arrays (FIFO queues) to support multiple concurrent operations on the same characteristic.
    // CoreBluetooth processes operations in order, so responses arrive in the same order as requests.
    // This approach is simpler than unique ID tracking and sufficient for typical BLE use cases.
    // Note: If responses could arrive out-of-order (they shouldn't in BLE), this would need revision.
    private var readValueContinuations: [CBUUID: [CheckedContinuation<Data, Error>]] = [:]
    private var writeValueContinuations: [CBUUID: [CheckedContinuation<Void, Error>]] = [:]
    private var readDescriptorContinuations: [String: [CheckedContinuation<Data, Error>]] = [:]
    private var writeDescriptorContinuations: [String: [CheckedContinuation<Void, Error>]] = [:]
    private var rssiContinuations: [CheckedContinuation<Int, Error>] = []

    // Track pending read requests to disambiguate from notifications
    private var pendingReads: Set<CBUUID> = []

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

    deinit {
        // Note: We can't await in deinit, so we dispatch cleanup synchronously
        // This ensures any pending operations are failed when the backend is deallocated
        // The actual cleanup happens via the disconnect() method in normal usage
    }

    /// Called by CentralBackend when the peripheral disconnects unexpectedly
    func handleRemoteDisconnect(reason: String?) {
        cleanupOnDisconnect(reason: reason)

        // Notify state stream
        stateUpdatesContinuation?.yield(.disconnected(reason: reason))
        stateUpdatesContinuation?.finish()
        stateUpdatesContinuation = nil

        mtuUpdatesContinuation?.finish()
        mtuUpdatesContinuation = nil

        pairingStateUpdatesContinuation?.finish()
        pairingStateUpdatesContinuation = nil
    }

    /// Cleans up all pending operations with a disconnection error
    private func cleanupOnDisconnect(reason: String?) {
        let error = BluetoothError.connectionFailed(reason ?? "Peripheral disconnected")

        // Fail pending service discovery
        serviceDiscoveryContinuation?.resume(throwing: error)
        serviceDiscoveryContinuation = nil

        // Fail pending characteristic discoveries
        for (_, continuation) in characteristicDiscoveryContinuations {
            continuation.resume(throwing: error)
        }
        characteristicDiscoveryContinuations.removeAll()

        // Fail pending descriptor discoveries
        for (_, continuation) in descriptorDiscoveryContinuations {
            continuation.resume(throwing: error)
        }
        descriptorDiscoveryContinuations.removeAll()

        // Fail pending read operations
        for (_, continuations) in readValueContinuations {
            for continuation in continuations {
                continuation.resume(throwing: error)
            }
        }
        readValueContinuations.removeAll()
        pendingReads.removeAll()

        // Fail pending write operations
        for (_, continuations) in writeValueContinuations {
            for continuation in continuations {
                continuation.resume(throwing: error)
            }
        }
        writeValueContinuations.removeAll()

        // Fail pending descriptor reads
        for (_, continuations) in readDescriptorContinuations {
            for continuation in continuations {
                continuation.resume(throwing: error)
            }
        }
        readDescriptorContinuations.removeAll()

        // Fail pending descriptor writes
        for (_, continuations) in writeDescriptorContinuations {
            for continuation in continuations {
                continuation.resume(throwing: error)
            }
        }
        writeDescriptorContinuations.removeAll()

        // Fail pending RSSI reads
        for continuation in rssiContinuations {
            continuation.resume(throwing: error)
        }
        rssiContinuations.removeAll()

        // Fail pending notification state changes
        for (_, continuation) in setNotifyContinuations {
            continuation.resume(throwing: error)
        }
        setNotifyContinuations.removeAll()

        // Finish notification streams
        for (_, continuation) in notificationContinuations {
            continuation.finish(throwing: error)
        }
        notificationContinuations.removeAll()

        // Fail pending L2CAP channel
        l2capChannelContinuation?.resume(throwing: error)
        l2capChannelContinuation = nil

        // Clear discovered items (free memory)
        discoveredServices.removeAll()
        discoveredCharacteristics.removeAll()
        characteristicsByService.removeAll()
        lastDiscoveredServices.removeAll()
        lastDiscoveredDescriptors.removeAll()
    }

    private func setupDelegateCallbacks() {
        delegate.onServicesDiscovered = { [weak self] services, error in
            guard let self else { return }
            let wrappedServices = services?.map { SendableService($0) }
            Task { await self.handleServicesDiscovered(wrappedServices, error) }
        }

        delegate.onCharacteristicsDiscovered = { [weak self] service, error in
            guard let self else { return }
            Task { await self.handleCharacteristicsDiscovered(service, error) }
        }

        delegate.onDescriptorsDiscovered = { [weak self] characteristic, error in
            guard let self else { return }
            Task { await self.handleDescriptorsDiscovered(characteristic, error) }
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
            Task { await self.handleDescriptorValueUpdated(descriptor, error) }
        }

        delegate.onDescriptorWritten = { [weak self] descriptor, error in
            guard let self else { return }
            Task { await self.handleDescriptorWritten(descriptor, error) }
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
            let wrappedChannel = channel.map { SendableL2CAPChannel($0) }
            Task { await self.handleL2CAPChannelOpened(wrappedChannel, error) }
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

    private func handleCharacteristicsDiscovered(_ service: CBService, _ error: Error?) {
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

    private func handleDescriptorsDiscovered(_ characteristic: CBCharacteristic, _ error: Error?) {
        if let error {
            descriptorDiscoveryContinuations[characteristic.uuid]?.resume(throwing: error)
        } else {
            lastDiscoveredDescriptors[characteristic.uuid] = characteristic.descriptors ?? []
            descriptorDiscoveryContinuations[characteristic.uuid]?.resume(returning: ())
        }
        descriptorDiscoveryContinuations[characteristic.uuid] = nil
    }

    private func handleCharacteristicValueUpdated(_ uuid: CBUUID, _ value: Data, _ isIndicate: Bool, _ error: Error?) {
        // Prioritize read responses over notifications to avoid ambiguity
        // If there's a pending read, assume this is the read response
        if pendingReads.contains(uuid), var continuations = readValueContinuations[uuid], !continuations.isEmpty {
            let continuation = continuations.removeFirst()
            if continuations.isEmpty {
                readValueContinuations[uuid] = nil
                pendingReads.remove(uuid)
            } else {
                readValueContinuations[uuid] = continuations
            }

            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: value)
            }
            return
        }

        // Otherwise, this is a notification/indication
        if let continuation = notificationContinuations[uuid] {
            if let error {
                continuation.finish(throwing: error)
                notificationContinuations[uuid] = nil
            } else {
                let notification: GATTNotification = isIndicate ? .indication(value) : .notification(value)
                continuation.yield(notification)
            }
        }
    }

    private func handleCharacteristicWritten(_ uuid: CBUUID, _ error: Error?) {
        guard var continuations = writeValueContinuations[uuid], !continuations.isEmpty else { return }

        let continuation = continuations.removeFirst()
        if continuations.isEmpty {
            writeValueContinuations[uuid] = nil
        } else {
            writeValueContinuations[uuid] = continuations
        }

        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: ())
        }
    }

    private func handleDescriptorValueUpdated(_ descriptor: CBDescriptor, _ error: Error?) {
        let key = descriptorKey(descriptor)
        guard var continuations = readDescriptorContinuations[key], !continuations.isEmpty else { return }

        let continuation = continuations.removeFirst()
        if continuations.isEmpty {
            readDescriptorContinuations[key] = nil
        } else {
            readDescriptorContinuations[key] = continuations
        }

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
    }

    private func handleDescriptorWritten(_ descriptor: CBDescriptor, _ error: Error?) {
        let key = descriptorKey(descriptor)
        guard var continuations = writeDescriptorContinuations[key], !continuations.isEmpty else { return }

        let continuation = continuations.removeFirst()
        if continuations.isEmpty {
            writeDescriptorContinuations[key] = nil
        } else {
            writeDescriptorContinuations[key] = continuations
        }

        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: ())
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
        guard !rssiContinuations.isEmpty else { return }

        let continuation = rssiContinuations.removeFirst()
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: value)
        }
    }

    private func handleL2CAPChannelOpened(_ wrappedChannel: SendableL2CAPChannel?, _ error: Error?) {
        if let error {
            l2capChannelContinuation?.resume(throwing: error)
        } else if let wrappedChannel {
            let l2capChannel = _CoreBluetoothL2CAPChannel(channel: wrappedChannel.channel)
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

    /// Returns MTU updates stream.
    /// Note: CoreBluetooth does not provide MTU change notifications.
    /// The MTU is negotiated once during connection and typically remains constant.
    /// This stream yields the initial MTU value and will only update on disconnect.
    func mtuUpdates() -> AsyncStream<Int> {
        AsyncStream { continuation in
            continuation.yield(mtu)
            self.mtuUpdatesContinuation = continuation
        }
    }

    /// Returns pairing state updates stream.
    /// Note: CoreBluetooth does not expose pairing state directly.
    /// We infer pairing based on connection state (connected = paired for most purposes).
    /// This stream yields the initial value and will only update on disconnect.
    /// For actual pairing events, use system Bluetooth settings.
    func pairingStateUpdates() -> AsyncStream<PairingState> {
        AsyncStream { continuation in
            continuation.yield(pairingState)
            self.pairingStateUpdatesContinuation = continuation
        }
    }

    func disconnect() async {
        centralManager.cancelPeripheralConnection(peripheral)

        // Clean up all pending operations
        cleanupOnDisconnect(reason: "User requested disconnect")

        // Notify state stream
        stateUpdatesContinuation?.yield(.disconnected(reason: "User requested disconnect"))
        stateUpdatesContinuation?.finish()
        stateUpdatesContinuation = nil

        mtuUpdatesContinuation?.finish()
        mtuUpdatesContinuation = nil

        pairingStateUpdatesContinuation?.finish()
        pairingStateUpdatesContinuation = nil
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
            // Track that we have a pending read to disambiguate from notifications
            self.pendingReads.insert(cbChar.uuid)
            var existing = self.readValueContinuations[cbChar.uuid] ?? []
            existing.append(continuation)
            self.readValueContinuations[cbChar.uuid] = existing
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
                var existing = self.writeValueContinuations[cbChar.uuid] ?? []
                existing.append(continuation)
                self.writeValueContinuations[cbChar.uuid] = existing
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

    /// Enable or disable notifications for a characteristic.
    /// Note: The `type` parameter is ignored on CoreBluetooth.
    /// CoreBluetooth automatically selects notification vs indication based on
    /// the characteristic's properties (uses indication if available, else notification).
    func setNotificationsEnabled(
        _ enabled: Bool,
        for characteristic: GATTCharacteristic,
        type: GATTClientSubscriptionType
    ) async throws {
        // Note: CoreBluetooth ignores the notification/indication preference.
        // It automatically uses indication if the characteristic supports it,
        // otherwise falls back to notification.
        _ = type // Silence unused parameter warning

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
            var existing = self.readDescriptorContinuations[key] ?? []
            existing.append(continuation)
            self.readDescriptorContinuations[key] = existing
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
            var existing = self.writeDescriptorContinuations[key] ?? []
            existing.append(continuation)
            self.writeDescriptorContinuations[key] = existing
            self.peripheral.writeValue(value, for: cbDescriptor)
        }
    }

    func readRSSI() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            self.rssiContinuations.append(continuation)
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

private final class PeripheralDelegate: NSObject, CBPeripheralDelegate, Sendable {
    private struct Callbacks: Sendable {
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
    }

    private let callbacks = Mutex(Callbacks())

    var onServicesDiscovered: (@Sendable ([CBService]?, Error?) -> Void)? {
        get { callbacks.withLock { $0.onServicesDiscovered } }
        set { callbacks.withLock { $0.onServicesDiscovered = newValue } }
    }

    var onCharacteristicsDiscovered: (@Sendable (CBService, Error?) -> Void)? {
        get { callbacks.withLock { $0.onCharacteristicsDiscovered } }
        set { callbacks.withLock { $0.onCharacteristicsDiscovered = newValue } }
    }

    var onDescriptorsDiscovered: (@Sendable (CBCharacteristic, Error?) -> Void)? {
        get { callbacks.withLock { $0.onDescriptorsDiscovered } }
        set { callbacks.withLock { $0.onDescriptorsDiscovered = newValue } }
    }

    var onCharacteristicValueUpdated: (@Sendable (CBCharacteristic, Error?) -> Void)? {
        get { callbacks.withLock { $0.onCharacteristicValueUpdated } }
        set { callbacks.withLock { $0.onCharacteristicValueUpdated = newValue } }
    }

    var onCharacteristicWritten: (@Sendable (CBCharacteristic, Error?) -> Void)? {
        get { callbacks.withLock { $0.onCharacteristicWritten } }
        set { callbacks.withLock { $0.onCharacteristicWritten = newValue } }
    }

    var onDescriptorValueUpdated: (@Sendable (CBDescriptor, Error?) -> Void)? {
        get { callbacks.withLock { $0.onDescriptorValueUpdated } }
        set { callbacks.withLock { $0.onDescriptorValueUpdated = newValue } }
    }

    var onDescriptorWritten: (@Sendable (CBDescriptor, Error?) -> Void)? {
        get { callbacks.withLock { $0.onDescriptorWritten } }
        set { callbacks.withLock { $0.onDescriptorWritten = newValue } }
    }

    var onNotificationStateChanged: (@Sendable (CBCharacteristic, Error?) -> Void)? {
        get { callbacks.withLock { $0.onNotificationStateChanged } }
        set { callbacks.withLock { $0.onNotificationStateChanged = newValue } }
    }

    var onRSSIRead: (@Sendable (NSNumber, Error?) -> Void)? {
        get { callbacks.withLock { $0.onRSSIRead } }
        set { callbacks.withLock { $0.onRSSIRead = newValue } }
    }

    var onL2CAPChannelOpened: (@Sendable (CBL2CAPChannel?, Error?) -> Void)? {
        get { callbacks.withLock { $0.onL2CAPChannelOpened } }
        set { callbacks.withLock { $0.onL2CAPChannelOpened = newValue } }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        callbacks.withLock { $0.onServicesDiscovered }?(peripheral.services, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        callbacks.withLock { $0.onCharacteristicsDiscovered }?(service, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        callbacks.withLock { $0.onDescriptorsDiscovered }?(characteristic, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        callbacks.withLock { $0.onCharacteristicValueUpdated }?(characteristic, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        callbacks.withLock { $0.onCharacteristicWritten }?(characteristic, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        callbacks.withLock { $0.onDescriptorValueUpdated }?(descriptor, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: Error?) {
        callbacks.withLock { $0.onDescriptorWritten }?(descriptor, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        callbacks.withLock { $0.onNotificationStateChanged }?(characteristic, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        callbacks.withLock { $0.onRSSIRead }?(RSSI, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        callbacks.withLock { $0.onL2CAPChannelOpened }?(channel, error)
    }
}

// MARK: - Peripheral Manager Backend

struct _CoreBluetoothPeripheralBackend: _PeripheralBackend {
    private let controller: _CoreBluetoothPeripheralController

    var state: BluetoothState {
        controller.state
    }

    init() {
        self.controller = _CoreBluetoothPeripheralController()
    }

    func stateUpdates() -> AsyncStream<BluetoothState> {
        let currentState = state
        return AsyncStream { continuation in
            continuation.yield(currentState)
            Task {
                await controller.setStateUpdatesContinuation(continuation)
            }
            continuation.onTermination = { _ in
                Task { await controller.clearStateUpdatesContinuation() }
            }
        }
    }

    func connectionEvents() async throws -> AsyncThrowingStream<PeripheralConnectionEvent, Error> {
        await controller.connectionEvents()
    }

    func pairingRequests() async throws -> AsyncThrowingStream<PairingRequest, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func startAdvertising(advertisingData: AdvertisementData, scanResponseData: AdvertisementData?, parameters: AdvertisingParameters) async throws {
        try await controller.startAdvertising(advertisingData: advertisingData, scanResponseData: scanResponseData, parameters: parameters)
    }

    func startAdvertisingSet(_ configuration: AdvertisingSetConfiguration) async throws -> AdvertisingSetID {
        throw BluetoothError.unimplemented("Extended advertising sets not available in CoreBluetooth")
    }

    func updateAdvertisingSet(_ id: AdvertisingSetID, configuration: AdvertisingSetConfiguration) async throws {
        throw BluetoothError.unimplemented("Extended advertising sets not available in CoreBluetooth")
    }

    func stopAdvertising() async {
        await controller.stopAdvertising()
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
        try await controller.addService(service)
    }

    func removeService(_ registration: GATTServiceRegistration) async throws {
        try await controller.removeService(registration)
    }

    func gattRequests() async throws -> AsyncThrowingStream<GATTServerRequest, Error> {
        await controller.gattRequests()
    }

    func updateValue(_ value: Data, for characteristic: GATTCharacteristic, type: GATTServerUpdateType) async throws {
        try await controller.updateValue(value, for: characteristic, type: type)
    }

    func publishL2CAPChannel(parameters: L2CAPChannelParameters) async throws -> L2CAPPSM {
        try await controller.publishL2CAPChannel(parameters: parameters)
    }

    func incomingL2CAPChannels(psm: L2CAPPSM) async throws -> AsyncThrowingStream<any L2CAPChannel, Error> {
        await controller.incomingL2CAPChannels(psm: psm)
    }
}

private actor _CoreBluetoothPeripheralController {
    private let delegate: PeripheralManagerDelegate
    private let peripheralManager: CBPeripheralManager
    private let cachedState: Mutex<BluetoothState>
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
        cachedState.withLock { $0 }
    }

    init() {
        let delegate = PeripheralManagerDelegate()
        self.delegate = delegate
        let peripheralManager = CBPeripheralManager(delegate: delegate, queue: .main)
        self.peripheralManager = peripheralManager
        self.cachedState = Mutex(BluetoothState(peripheralManager.state))
        Task { await setupDelegateCallbacks() }
    }

    private func setupDelegateCallbacks() {
        delegate.onStateUpdate = { [weak self] state in
            guard let self else { return }
            Task { await self.handleStateUpdate(state) }
        }

        delegate.onServiceAdded = { [weak self] service, error in
            guard let self else { return }
            let wrappedService = service.map { SendableService($0) }
            Task { await self.handleServiceAdded(wrappedService, error) }
        }

        delegate.onCentralSubscribed = { [weak self] central, characteristic in
            guard let self else { return }
            Task { await self.handleCentralSubscribed(central, characteristic) }
        }

        delegate.onCentralUnsubscribed = { [weak self] central, characteristic in
            guard let self else { return }
            Task { await self.handleCentralUnsubscribed(central, characteristic) }
        }

        delegate.onReadRequest = { [weak self] request in
            guard let self else { return }
            Task { await self.handleReadRequest(request) }
        }

        delegate.onWriteRequests = { [weak self] requests in
            guard let self else { return }
            let wrappedRequests = requests.map { SendableATTRequest($0) }
            Task { await self.handleWriteRequests(wrappedRequests) }
        }

        delegate.onL2CAPChannelPublished = { [weak self] psm, error in
            guard let self else { return }
            Task { await self.handleL2CAPChannelPublished(psm, error) }
        }

        delegate.onL2CAPChannelOpened = { [weak self] channel, error in
            guard let self else { return }
            let wrappedChannel = channel.map { SendableL2CAPChannel($0) }
            Task { await self.handleL2CAPChannelOpened(wrappedChannel, error) }
        }
    }

    private func handleStateUpdate(_ cbState: CBManagerState) {
        let newState = BluetoothState(cbState)
        cachedState.withLock { $0 = newState }
        stateUpdatesContinuation?.yield(newState)
    }

    private func handleServiceAdded(_ wrappedService: SendableService?, _ error: Error?) {
        guard let continuation = addServiceContinuation else { return }

        if let error {
            continuation.resume(throwing: error)
        } else if let wrappedService, pendingServiceDefinition != nil {
            let service = wrappedService.service
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

    private func handleCentralSubscribed(_ central: CBCentral, _ characteristic: CBCharacteristic) {
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

    private func handleCentralUnsubscribed(_ central: CBCentral, _ characteristic: CBCharacteristic) {
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

    private func handleReadRequest(_ request: CBATTRequest) {
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
        for wrappedRequest in wrappedRequests {
            let request = wrappedRequest.request
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

    private func handleL2CAPChannelOpened(_ wrappedChannel: SendableL2CAPChannel?, _ error: Error?) {
        if let error {
            for (_, continuation) in publishedL2CAPChannels {
                continuation.finish(throwing: error)
            }
            return
        }

        guard let wrappedChannel else {
            for (_, continuation) in publishedL2CAPChannels {
                continuation.finish(throwing: BluetoothError.l2capChannelError("Failed to open L2CAP channel"))
            }
            return
        }

        let channel = wrappedChannel.channel
        if let continuation = publishedL2CAPChannels[channel.psm] {
            let l2capChannel = _CoreBluetoothL2CAPChannel(channel: channel)
            continuation.yield(l2capChannel)
        }
    }

    func setStateUpdatesContinuation(_ continuation: AsyncStream<BluetoothState>.Continuation) {
        stateUpdatesContinuation = continuation
    }

    func clearStateUpdatesContinuation() {
        stateUpdatesContinuation = nil
    }

    func connectionEvents() -> AsyncThrowingStream<PeripheralConnectionEvent, Error> {
        AsyncThrowingStream { continuation in
            self.connectionEventsContinuation = continuation
        }
    }

    func startAdvertising(advertisingData: AdvertisementData, scanResponseData: AdvertisementData?, parameters: AdvertisingParameters) throws {
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

    func stopAdvertising() {
        peripheralManager.stopAdvertising()
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

    func removeService(_ registration: GATTServiceRegistration) throws {
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

    func gattRequests() -> AsyncThrowingStream<GATTServerRequest, Error> {
        AsyncThrowingStream { continuation in
            self.gattRequestsContinuation = continuation
        }
    }

    func updateValue(_ value: Data, for characteristic: GATTCharacteristic, type: GATTServerUpdateType) throws {
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

    func incomingL2CAPChannels(psm: L2CAPPSM) -> AsyncThrowingStream<any L2CAPChannel, Error> {
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

private final class PeripheralManagerDelegate: NSObject, CBPeripheralManagerDelegate, Sendable {
    private struct Callbacks: Sendable {
        var onStateUpdate: (@Sendable (CBManagerState) -> Void)?
        var onServiceAdded: (@Sendable (CBService?, Error?) -> Void)?
        var onCentralSubscribed: (@Sendable (CBCentral, CBCharacteristic) -> Void)?
        var onCentralUnsubscribed: (@Sendable (CBCentral, CBCharacteristic) -> Void)?
        var onReadRequest: (@Sendable (CBATTRequest) -> Void)?
        var onWriteRequests: (@Sendable ([CBATTRequest]) -> Void)?
        var onL2CAPChannelPublished: (@Sendable (CBL2CAPPSM, Error?) -> Void)?
        var onL2CAPChannelOpened: (@Sendable (CBL2CAPChannel?, Error?) -> Void)?
    }

    private let callbacks = Mutex(Callbacks())

    var onStateUpdate: (@Sendable (CBManagerState) -> Void)? {
        get { callbacks.withLock { $0.onStateUpdate } }
        set { callbacks.withLock { $0.onStateUpdate = newValue } }
    }

    var onServiceAdded: (@Sendable (CBService?, Error?) -> Void)? {
        get { callbacks.withLock { $0.onServiceAdded } }
        set { callbacks.withLock { $0.onServiceAdded = newValue } }
    }

    var onCentralSubscribed: (@Sendable (CBCentral, CBCharacteristic) -> Void)? {
        get { callbacks.withLock { $0.onCentralSubscribed } }
        set { callbacks.withLock { $0.onCentralSubscribed = newValue } }
    }

    var onCentralUnsubscribed: (@Sendable (CBCentral, CBCharacteristic) -> Void)? {
        get { callbacks.withLock { $0.onCentralUnsubscribed } }
        set { callbacks.withLock { $0.onCentralUnsubscribed = newValue } }
    }

    var onReadRequest: (@Sendable (CBATTRequest) -> Void)? {
        get { callbacks.withLock { $0.onReadRequest } }
        set { callbacks.withLock { $0.onReadRequest = newValue } }
    }

    var onWriteRequests: (@Sendable ([CBATTRequest]) -> Void)? {
        get { callbacks.withLock { $0.onWriteRequests } }
        set { callbacks.withLock { $0.onWriteRequests = newValue } }
    }

    var onL2CAPChannelPublished: (@Sendable (CBL2CAPPSM, Error?) -> Void)? {
        get { callbacks.withLock { $0.onL2CAPChannelPublished } }
        set { callbacks.withLock { $0.onL2CAPChannelPublished = newValue } }
    }

    var onL2CAPChannelOpened: (@Sendable (CBL2CAPChannel?, Error?) -> Void)? {
        get { callbacks.withLock { $0.onL2CAPChannelOpened } }
        set { callbacks.withLock { $0.onL2CAPChannelOpened = newValue } }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        callbacks.withLock { $0.onStateUpdate }?(peripheral.state)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        callbacks.withLock { $0.onServiceAdded }?(service, error)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        callbacks.withLock { $0.onCentralSubscribed }?(central, characteristic)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        callbacks.withLock { $0.onCentralUnsubscribed }?(central, characteristic)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        callbacks.withLock { $0.onReadRequest }?(request)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        callbacks.withLock { $0.onWriteRequests }?(requests)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        callbacks.withLock { $0.onL2CAPChannelPublished }?(PSM, error)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        callbacks.withLock { $0.onL2CAPChannelOpened }?(channel, error)
    }
}

// MARK: - L2CAP Channel

/// CoreBluetooth L2CAP Channel implementation.
///
/// Thread-safety: This class uses @unchecked Sendable because:
/// 1. Foundation's InputStream/OutputStream are not Sendable and there's no @preconcurrency import for Foundation
/// 2. All stream operations are serialized on the main run loop (streams are scheduled on .main)
/// 3. Mutable state (incomingContinuation, closed) is protected by Mutex
/// 4. Stream delegate callbacks happen on main thread where streams are scheduled
///
/// This is the only remaining @unchecked Sendable in the CoreBluetooth backend.
/// The delegates (CentralManagerDelegate, PeripheralDelegate, etc.) use Mutex pattern instead.
final class _CoreBluetoothL2CAPChannel: L2CAPChannel, @unchecked Sendable {
    let psm: L2CAPPSM
    let mtu: Int

    private let channel: CBL2CAPChannel
    private let inputStream: InputStream
    private let outputStream: OutputStream
    private let state: Mutex<L2CAPChannelState>
    private let streamDelegate: L2CAPStreamDelegate
    private let runLoopThread: L2CAPRunLoopThread

    private struct L2CAPChannelState: Sendable {
        var incomingContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        var closed: Bool = false
    }

    init(channel: CBL2CAPChannel) {
        self.channel = channel
        self.psm = L2CAPPSM(rawValue: channel.psm)
        // Use a reasonable default MTU for L2CAP CoC (Connection-oriented Channels)
        // The actual MTU is negotiated during channel setup, but we use a conservative default
        self.mtu = 512
        self.inputStream = channel.inputStream!
        self.outputStream = channel.outputStream!
        self.state = Mutex(L2CAPChannelState())

        let delegate = L2CAPStreamDelegate()
        self.streamDelegate = delegate

        // Create a dedicated thread with run loop for stream processing
        // This is necessary because CLI tools using async/await don't pump the main run loop
        let thread = L2CAPRunLoopThread()
        self.runLoopThread = thread
        thread.start()

        // Wait for run loop to be ready
        thread.waitUntilReady()

        inputStream.delegate = delegate
        outputStream.delegate = delegate

        // Schedule streams on the dedicated run loop thread
        thread.perform {
            self.inputStream.schedule(in: .current, forMode: .default)
            self.outputStream.schedule(in: .current, forMode: .default)
            self.inputStream.open()
            self.outputStream.open()
        }

        delegate.onDataAvailable = { [weak self] in
            self?.readAvailableData()
        }

        delegate.onError = { [weak self] error in
            self?.handleStreamError(error)
        }
    }

    private func readAvailableData() {
        let isClosed = state.withLock { $0.closed }
        guard !isClosed else { return }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = inputStream.read(&buffer, maxLength: buffer.count)

        if bytesRead > 0 {
            let data = Data(buffer.prefix(bytesRead))
            _ = state.withLock { $0.incomingContinuation?.yield(data) }
        }
    }

    private func handleStreamError(_ error: Error) {
        state.withLock { state in
            state.incomingContinuation?.finish(throwing: error)
            state.incomingContinuation = nil
        }
    }

    func send(_ data: Data) async throws {
        let isClosed = state.withLock { $0.closed }
        guard !isClosed else {
            throw BluetoothError.l2capChannelError("Channel closed")
        }

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
            self.state.withLock { $0.incomingContinuation = continuation }

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.state.withLock { $0.incomingContinuation = nil }
            }
        }
    }

    func close() async {
        state.withLock { state in
            guard !state.closed else { return }
            state.closed = true
            state.incomingContinuation?.finish()
            state.incomingContinuation = nil
        }

        runLoopThread.perform {
            self.inputStream.close()
            self.outputStream.close()
        }
        runLoopThread.stop()
    }
}

// MARK: - L2CAP Stream Delegate

private final class L2CAPStreamDelegate: NSObject, Foundation.StreamDelegate, Sendable {
    private struct Callbacks: Sendable {
        var onDataAvailable: (@Sendable () -> Void)?
        var onError: (@Sendable (Error) -> Void)?
    }

    private let callbacks = Mutex(Callbacks())

    var onDataAvailable: (@Sendable () -> Void)? {
        get { callbacks.withLock { $0.onDataAvailable } }
        set { callbacks.withLock { $0.onDataAvailable = newValue } }
    }

    var onError: (@Sendable (Error) -> Void)? {
        get { callbacks.withLock { $0.onError } }
        set { callbacks.withLock { $0.onError = newValue } }
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            callbacks.withLock { $0.onDataAvailable }?()
        case .errorOccurred:
            if let error = aStream.streamError {
                callbacks.withLock { $0.onError }?(error)
            }
        default:
            break
        }
    }
}

// MARK: - L2CAP Run Loop Thread

/// A dedicated thread with its own run loop for processing L2CAP streams.
/// This is necessary because CLI tools using async/await don't pump the main run loop,
/// but Foundation streams require a running run loop to process I/O events.
private final class L2CAPRunLoopThread: Thread, @unchecked Sendable {
    private let readySemaphore = DispatchSemaphore(value: 0)
    private var runLoop: RunLoop?
    private let stopSource = Mutex<CFRunLoopSource?>(nil)

    override func main() {
        runLoop = .current

        // Create a source to allow stopping the run loop
        var context = CFRunLoopSourceContext()
        context.perform = { _ in }
        let source = CFRunLoopSourceCreate(nil, 0, &context)!
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
        stopSource.withLock { $0 = source }

        // Signal that run loop is ready
        readySemaphore.signal()

        // Run the loop until stopped
        CFRunLoopRun()
    }

    func waitUntilReady() {
        readySemaphore.wait()
    }

    func perform(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        runLoop.perform(block)
    }

    func stop() {
        let source = stopSource.withLock { source -> CFRunLoopSource? in
            let s = source
            source = nil
            return s
        }
        if let source {
            CFRunLoopSourceInvalidate(source)
        }
        if let cfRunLoop = runLoop?.getCFRunLoop() {
            CFRunLoopStop(cfRunLoop)
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
