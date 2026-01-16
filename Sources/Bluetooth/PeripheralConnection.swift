#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public actor PeripheralConnection {
  public nonisolated let peripheral: Peripheral
  private let backend: any _PeripheralConnectionBackend

  init(peripheral: Peripheral, backend: any _PeripheralConnectionBackend) {
    self.peripheral = peripheral
    self.backend = backend
  }

  public func state() async -> PeripheralConnectionState {
    await backend.state
  }

  public func stateUpdates() async -> AsyncStream<PeripheralConnectionState> {
    await backend.stateUpdates()
  }

  public func disconnect() async {
    await backend.disconnect()
  }

  public func discoverServices(_ uuids: [BluetoothUUID]? = nil) async throws -> [GATTService] {
    try await backend.discoverServices(uuids)
  }

  public func discoverCharacteristics(
    _ uuids: [BluetoothUUID]? = nil,
    for service: GATTService
  ) async throws -> [GATTCharacteristic] {
    try await backend.discoverCharacteristics(uuids, for: service)
  }

  public func readValue(for characteristic: GATTCharacteristic) async throws -> Data {
    try await backend.readValue(for: characteristic)
  }

  public func writeValue(
    _ value: Data,
    for characteristic: GATTCharacteristic,
    type: GATTWriteType = .withResponse
  ) async throws {
    try await backend.writeValue(value, for: characteristic, type: type)
  }

  public func notifications(
    for characteristic: GATTCharacteristic
  ) async throws -> AsyncThrowingStream<GATTNotification, Error> {
    try await backend.notifications(for: characteristic)
  }

  public func setNotificationsEnabled(
    _ enabled: Bool,
    for characteristic: GATTCharacteristic,
    type: GATTClientSubscriptionType = .notification
  ) async throws {
    try await backend.setNotificationsEnabled(enabled, for: characteristic, type: type)
  }

  public func discoverDescriptors(
    for characteristic: GATTCharacteristic
  ) async throws -> [GATTDescriptor] {
    try await backend.discoverDescriptors(for: characteristic)
  }

  public func readValue(for descriptor: GATTDescriptor) async throws -> Data {
    try await backend.readValue(for: descriptor)
  }

  public func writeValue(_ value: Data, for descriptor: GATTDescriptor) async throws {
    try await backend.writeValue(value, for: descriptor)
  }

  public func readRSSI() async throws -> Int {
    try await backend.readRSSI()
  }

  public func mtu() async -> Int {
    await backend.mtu
  }

  public func mtuUpdates() async -> AsyncStream<Int> {
    await backend.mtuUpdates()
  }

  public func pairingState() async -> PairingState {
    await backend.pairingState
  }

  public func pairingStateUpdates() async -> AsyncStream<PairingState> {
    await backend.pairingStateUpdates()
  }

  public func openL2CAPChannel(
    psm: L2CAPPSM,
    parameters: L2CAPChannelParameters = .init()
  ) async throws -> any L2CAPChannel {
    try await backend.openL2CAPChannel(psm: psm, parameters: parameters)
  }

  public func updateConnectionParameters(_ parameters: ConnectionParameters) async throws {
    try await backend.updateConnectionParameters(parameters)
  }

  public func updatePHY(_ preference: PHYPreference) async throws {
    try await backend.updatePHY(preference)
  }
}
