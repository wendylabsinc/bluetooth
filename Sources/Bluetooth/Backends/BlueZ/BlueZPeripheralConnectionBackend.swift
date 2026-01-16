#if os(Linux)
  #if canImport(FoundationEssentials)
    import FoundationEssentials
    import Foundation
  #else
    import Foundation
  #endif

  import DBUS
  import Logging
  import NIOCore

  #if canImport(Glibc)
    import Glibc
  #elseif canImport(Musl)
    import Musl
  #endif

  actor _BlueZPeripheralConnectionBackend: _PeripheralConnectionBackend {
    private let client: BlueZClient
    private let adapterPath: String
    private let devicePath: String
    private let deviceAddress: String
    private let requiresBonding: Bool
    private let agentController: _BlueZPeripheralAgentController?
    private let agentPath: String
    private let agentConfig: AgentConfig
    private let logger: Logger

    private var stateValue: PeripheralConnectionState = .connecting
    private var mtuValue: Int = 23
    private var pairingStateValue: PairingState = .unknown
    private var rssiValue: Int?
    private var pairedValue: Bool?
    private var addressType: BlueZAddressType?
    private var servicesResolved = false
    private var servicesResolvedWaiters: [CheckedContinuation<Void, Never>] = []

    private var servicePathByService: [GATTService: String] = [:]
    private var characteristicPathByCharacteristic: [GATTCharacteristic: String] = [:]
    private var descriptorPathByDescriptor: [GATTDescriptor: String] = [:]
    private var notificationStates: [String: NotificationState] = [:]

    private var stateContinuations: [UUID: AsyncStream<PeripheralConnectionState>.Continuation] =
      [:]
    private var mtuContinuations: [UUID: AsyncStream<Int>.Continuation] = [:]
    private var pairingStateContinuations: [UUID: AsyncStream<PairingState>.Continuation] = [:]

    private var task: Task<Void, Never>?
    private var stopRequested = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var agentRegistered = false
    private var messageHandlerID: UUID?

    init(
      client: BlueZClient,
      peripheral: Peripheral,
      options: ConnectionOptions,
      agentController: _BlueZPeripheralAgentController? = nil,
      adapterPath: String
    ) throws {
      self.client = client
      guard let address = Self.extractAddress(from: peripheral) else {
        throw BluetoothError.invalidState("BlueZ requires a peripheral address on Linux")
      }

      self.adapterPath = adapterPath
      self.deviceAddress = address
      self.devicePath =
        "\(adapterPath)/dev_" + address.uppercased().replacingOccurrences(of: ":", with: "_")
      self.requiresBonding = options.requiresBonding
      self.agentController = agentController
      self.agentConfig = AgentConfig.load()
      self.agentPath = AgentConfig.makeAgentPath()
      self.logger = BluetoothLogger.backend
    }

    var state: PeripheralConnectionState { stateValue }

    func stateUpdates() -> AsyncStream<PeripheralConnectionState> {
      AsyncStream { continuation in
        let id = UUID()
        stateContinuations[id] = continuation
        continuation.yield(stateValue)
        continuation.onTermination = { @Sendable _ in
          Task { await self.removeStateContinuation(id) }
        }
      }
    }

    var mtu: Int { mtuValue }

    func mtuUpdates() -> AsyncStream<Int> {
      AsyncStream { continuation in
        let id = UUID()
        mtuContinuations[id] = continuation
        continuation.yield(mtuValue)
        continuation.onTermination = { @Sendable _ in
          Task { await self.removeMtuContinuation(id) }
        }
      }
    }

    var pairingState: PairingState { pairingStateValue }

    func pairingStateUpdates() -> AsyncStream<PairingState> {
      AsyncStream { continuation in
        let id = UUID()
        pairingStateContinuations[id] = continuation
        continuation.yield(pairingStateValue)
        continuation.onTermination = { @Sendable _ in
          Task { await self.removePairingStateContinuation(id) }
        }
      }
    }

    func connect() async throws {
      if task != nil {
        throw BluetoothError.invalidState("BlueZ connection already started")
      }

      updateState(.connecting)

      try await withCheckedThrowingContinuation { continuation in
        connectContinuation = continuation
        task = Task { [weak self] in
          await self?.runConnection()
        }
      }
    }

    func disconnect() async {
      stopRequested = true
      if let continuation = stopContinuation {
        stopContinuation = nil
        continuation.resume()
      }

      if let task {
        await task.value
      }
      cleanup()
    }

    func discoverServices(_ uuids: [BluetoothUUID]?) async throws -> [GATTService] {
      let connection = try await client.getConnection()

      await waitForServicesResolved()
      let cache = try await loadGattObjects(connection)
      updateCaches(from: cache)

      var services = cache.servicesByPath.sorted { $0.key < $1.key }.map(\.value)
      if let uuids, !uuids.isEmpty {
        services = services.filter { uuids.contains($0.uuid) }
      }
      return services
    }

    func discoverCharacteristics(
      _ uuids: [BluetoothUUID]?,
      for service: GATTService
    ) async throws -> [GATTCharacteristic] {
      let connection = try await client.getConnection()

      await waitForServicesResolved()
      let cache = try await loadGattObjects(connection)
      updateCaches(from: cache)

      guard let servicePath = resolveServicePath(service, in: cache) else {
        throw BluetoothError.invalidState("GATT service not found on BlueZ device")
      }

      let characteristicPaths = cache.characteristicsByServicePath[servicePath] ?? []
      var characteristics = characteristicPaths.compactMap { cache.characteristicsByPath[$0] }
      if let uuids, !uuids.isEmpty {
        characteristics = characteristics.filter { uuids.contains($0.uuid) }
      }
      return characteristics
    }

    func readValue(for characteristic: GATTCharacteristic) async throws -> Data {
      let connection = try await client.getConnection()

      let path = try await resolveCharacteristicPath(characteristic, connection: connection)
      let request = DBusRequest.createMethodCall(
        destination: client.busName,
        path: path,
        interface: "org.bluez.GattCharacteristic1",
        method: "ReadValue",
        body: [
          .dictionary([:])
        ],
        signature: "a{sv}"
      )

      guard let reply = try await connection.send(request), reply.messageType == .methodReturn
      else {
        throw BluetoothError.invalidState("BlueZ ReadValue failed")
      }

      guard let value = reply.body.first, let data = client.dataFromValue(value) else {
        throw BluetoothError.invalidState("BlueZ ReadValue returned invalid data")
      }

      return data
    }

    func writeValue(
      _ value: Data,
      for characteristic: GATTCharacteristic,
      type: GATTWriteType
    ) async throws {
      let connection = try await client.getConnection()

      let path = try await resolveCharacteristicPath(characteristic, connection: connection)
      let bytes = value.map { DBusValue.byte($0) }
      var options: [DBusValue: DBusValue] = [:]
      let writeType = type == .withoutResponse ? "command" : "request"
      options[.string("type")] = .variant(DBusVariant(.string(writeType)))

      let request = DBusRequest.createMethodCall(
        destination: client.busName,
        path: path,
        interface: "org.bluez.GattCharacteristic1",
        method: "WriteValue",
        body: [
          .array(bytes),
          .dictionary(options),
        ],
        signature: "aya{sv}"
      )

      guard let reply = try await connection.send(request) else { return }
      if reply.messageType == .error {
        let name = client.dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
        throw BluetoothError.invalidState("BlueZ WriteValue failed: \(name)")
      }
    }

    func notifications(
      for characteristic: GATTCharacteristic
    ) async throws -> AsyncThrowingStream<GATTNotification, Error> {
      let connection = try await client.getConnection()

      let path = try await resolveCharacteristicPath(characteristic, connection: connection)
      let initialType: GATTClientSubscriptionType =
        characteristic.properties.contains(.indicate) ? .indication : .notification

      return AsyncThrowingStream { continuation in
        let id = UUID()
        var state =
          notificationStates[path] ?? NotificationState(type: initialType, continuations: [:])
        state.continuations[id] = continuation
        notificationStates[path] = state

        continuation.onTermination = { @Sendable _ in
          Task { await self.removeNotificationContinuation(path: path, id: id) }
        }
      }
    }

    func setNotificationsEnabled(
      _ enabled: Bool,
      for characteristic: GATTCharacteristic,
      type: GATTClientSubscriptionType
    ) async throws {
      let connection = try await client.getConnection()

      let path = try await resolveCharacteristicPath(characteristic, connection: connection)
      if enabled {
        let request = DBusRequest.createMethodCall(
          destination: client.busName,
          path: path,
          interface: "org.bluez.GattCharacteristic1",
          method: "StartNotify"
        )
        guard let reply = try await connection.send(request) else { return }
        if reply.messageType == .error {
          let name = client.dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
          if name != "org.bluez.Error.InProgress" {
            throw BluetoothError.invalidState("BlueZ StartNotify failed: \(name)")
          }
        }
      } else {
        let request = DBusRequest.createMethodCall(
          destination: client.busName,
          path: path,
          interface: "org.bluez.GattCharacteristic1",
          method: "StopNotify"
        )
        guard let reply = try await connection.send(request) else { return }
        if reply.messageType == .error {
          let name = client.dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
          if name != "org.bluez.Error.NotPermitted" {
            throw BluetoothError.invalidState("BlueZ StopNotify failed: \(name)")
          }
        }
      }

      var state = notificationStates[path] ?? NotificationState(type: type, continuations: [:])
      state.type = type
      notificationStates[path] = state
    }

    func discoverDescriptors(for characteristic: GATTCharacteristic) async throws
      -> [GATTDescriptor]
    {
      let connection = try await client.getConnection()

      await waitForServicesResolved()
      let cache = try await loadGattObjects(connection)
      updateCaches(from: cache)

      guard let characteristicPath = resolveCharacteristicPath(characteristic, in: cache) else {
        throw BluetoothError.invalidState("GATT characteristic not found on BlueZ device")
      }

      let descriptorPaths = cache.descriptorsByCharacteristicPath[characteristicPath] ?? []
      let descriptors = descriptorPaths.compactMap { cache.descriptorsByPath[$0] }
      return descriptors
    }

    func readValue(for descriptor: GATTDescriptor) async throws -> Data {
      let connection = try await client.getConnection()

      let path = try await resolveDescriptorPath(descriptor, connection: connection)
      let request = DBusRequest.createMethodCall(
        destination: client.busName,
        path: path,
        interface: "org.bluez.GattDescriptor1",
        method: "ReadValue",
        body: [
          .dictionary([:])
        ],
        signature: "a{sv}"
      )

      guard let reply = try await connection.send(request), reply.messageType == .methodReturn
      else {
        throw BluetoothError.invalidState("BlueZ ReadDescriptor failed")
      }

      guard let value = reply.body.first, let data = client.dataFromValue(value) else {
        throw BluetoothError.invalidState("BlueZ ReadDescriptor returned invalid data")
      }

      return data
    }

    func writeValue(_ value: Data, for descriptor: GATTDescriptor) async throws {
      let connection = try await client.getConnection()

      let path = try await resolveDescriptorPath(descriptor, connection: connection)
      let bytes = value.map { DBusValue.byte($0) }
      let request = DBusRequest.createMethodCall(
        destination: client.busName,
        path: path,
        interface: "org.bluez.GattDescriptor1",
        method: "WriteValue",
        body: [
          .array(bytes),
          .dictionary([:]),
        ],
        signature: "aya{sv}"
      )

      guard let reply = try await connection.send(request) else { return }
      if reply.messageType == .error {
        let name = client.dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
        throw BluetoothError.invalidState("BlueZ WriteDescriptor failed: \(name)")
      }
    }

    func readRSSI() async throws -> Int {
      let connection = try await client.getConnection()

      let request = DBusRequest.createMethodCall(
        destination: client.busName,
        path: devicePath,
        interface: "org.freedesktop.DBus.Properties",
        method: "Get",
        body: [
          .string("org.bluez.Device1"),
          .string("RSSI"),
        ]
      )

      guard let reply = try await connection.send(request), reply.messageType == .methodReturn
      else {
        throw BluetoothError.invalidState("BlueZ RSSI read failed")
      }

      guard let body = reply.body.first else {
        throw BluetoothError.invalidState("BlueZ RSSI read returned no data")
      }

      let value = client.unwrapVariant(body)
      guard let rssi = client.parseInt(value) else {
        throw BluetoothError.invalidState("BlueZ RSSI read returned unsupported type")
      }

      rssiValue = rssi
      return rssi
    }

    func openL2CAPChannel(
      psm: L2CAPPSM,
      parameters: L2CAPChannelParameters
    ) async throws -> any L2CAPChannel {
      guard case .connected = stateValue else {
        throw BluetoothError.invalidState("BlueZ L2CAP requires an active connection")
      }
      if parameters.requiresEncryption {
        let connection = try await client.getConnection()
        if let agentController {
          await agentController.registerPeripheralDevice(path: devicePath)
        }
        try await ensureAgentAvailable(connection)
      }

      let candidates = BlueZL2CAP.addressTypeCandidates(preferred: addressType)
      return try await BlueZL2CAP.openChannel(
        address: deviceAddress,
        addressTypes: candidates,
        psm: psm,
        parameters: parameters
      )
    }

    func updateConnectionParameters(_ parameters: ConnectionParameters) async throws {
      _ = parameters
      throw BluetoothError.unimplemented("BlueZ connection parameter update backend")
    }

    func updatePHY(_ preference: PHYPreference) async throws {
      _ = preference
      throw BluetoothError.unimplemented("BlueZ PHY update backend")
    }

    private func runConnection() async {
      do {
        let connection = try await client.getConnection()

        let handlerID = client.addMessageHandler { [weak self] message in
          await self?.handleMessage(message, connection: connection)
        }
        messageHandlerID = handlerID

        try await addMatchRules(connection)
        try await loadDeviceProperties(connection)

        if let agentController {
          await agentController.registerPeripheralDevice(path: devicePath)
        }

        if requiresBonding {
          try await ensureAgentAvailable(connection)
          try await pairIfNeeded(connection)
        }

        if !isConnected() {
          logger.debug(
            "Connecting to device",
            metadata: [
              BluetoothLogMetadata.deviceAddress: "\(deviceAddress)",
              "path": "\(devicePath)",
            ])
          try await connectDevice(connection)
          updateState(.connected)
          try await loadDeviceProperties(connection)
        }

        resumeConnectIfNeeded()
        await waitForStop()

        if isConnected() {
          logger.debug(
            "Disconnecting from device",
            metadata: [
              BluetoothLogMetadata.deviceAddress: "\(deviceAddress)",
              "path": "\(devicePath)",
            ])
          try await disconnectDevice(connection)
          updateState(.disconnected(reason: nil))
        }

        await unregisterAgentIfNeeded(connection)
      } catch {
        resumeConnectIfNeeded(error: error)
        updateState(.disconnected(reason: String(describing: error)))
      }

      cleanup()
    }

    private func addMatchRules(_ connection: DBusClient.Connection) async throws {
      let rules = [
        "type='signal',sender='\(client.busName)',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path='\(devicePath)'",
        "type='signal',sender='\(client.busName)',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path_namespace='\(devicePath)',arg0='org.bluez.GattCharacteristic1'",
      ]

      for rule in rules {
        try await client.addMatchRule(rule)
      }
    }

    private func connectDevice(_ connection: DBusClient.Connection) async throws {
      let request = DBusRequest.createMethodCall(
        destination: client.busName,
        path: devicePath,
        interface: "org.bluez.Device1",
        method: "Connect"
      )
      guard let reply = try await connection.send(request) else { return }
      if reply.messageType == .error {
        let name = client.dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
        throw BluetoothError.invalidState("D-Bus Connect failed: \(name)")
      }
    }

    private func disconnectDevice(_ connection: DBusClient.Connection) async throws {
      let request = DBusRequest.createMethodCall(
        destination: client.busName,
        path: devicePath,
        interface: "org.bluez.Device1",
        method: "Disconnect"
      )
      guard let reply = try await connection.send(request) else { return }
      if reply.messageType == .error {
        let name = client.dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
        if name == "org.bluez.Error.NotConnected" {
          return
        }
        throw BluetoothError.invalidState("D-Bus Disconnect failed: \(name)")
      }
    }

    private func ensureAgentAvailable(_ connection: DBusClient.Connection) async throws {
      if let agentController {
        try await agentController.startIfNeeded()
      } else {
        try await registerAgent(connection)
      }
    }

    private func registerAgent(_ connection: DBusClient.Connection) async throws {
      guard agentController == nil else { return }
      guard !agentRegistered else { return }

      logger.debug(
        "Registering agent",
        metadata: [
          "path": "\(agentPath)",
          "capability": "\(agentConfig.capability)",
        ])

      let registerRequest = DBusRequest.createMethodCall(
        destination: client.busName,
        path: "/org/bluez",
        interface: "org.bluez.AgentManager1",
        method: "RegisterAgent",
        body: [
          .objectPath(agentPath),
          .string(agentConfig.capability),
        ]
      )

      if let reply = try await connection.send(registerRequest), reply.messageType == .error {
        let name = client.dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
        if name != "org.bluez.Error.AlreadyExists" {
          throw BluetoothError.invalidState("D-Bus RegisterAgent failed: \(name)")
        }
      }

      let defaultRequest = DBusRequest.createMethodCall(
        destination: client.busName,
        path: "/org/bluez",
        interface: "org.bluez.AgentManager1",
        method: "RequestDefaultAgent",
        body: [.objectPath(agentPath)]
      )

      if let reply = try await connection.send(defaultRequest), reply.messageType == .error {
        let name = client.dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
        if name != "org.bluez.Error.AlreadyExists" {
          throw BluetoothError.invalidState("D-Bus RequestDefaultAgent failed: \(name)")
        }
      }

      agentRegistered = true
    }

    private func unregisterAgentIfNeeded(_ connection: DBusClient.Connection) async {
      guard agentController == nil else { return }
      guard agentRegistered else { return }

      let request = DBusRequest.createMethodCall(
        destination: client.busName,
        path: "/org/bluez",
        interface: "org.bluez.AgentManager1",
        method: "UnregisterAgent",
        body: [.objectPath(agentPath)]
      )

      do {
        if let reply = try await connection.send(request), reply.messageType == .error {
          let name = client.dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
          logger.debug(
            "UnregisterAgent failed",
            metadata: [
              BluetoothLogMetadata.error: "\(name)"
            ])
        }
      } catch {
        logger.debug(
          "UnregisterAgent failed",
          metadata: [
            BluetoothLogMetadata.error: "\(error)"
          ])
      }

      agentRegistered = false
    }

    private func pairIfNeeded(_ connection: DBusClient.Connection) async throws {
      if pairedValue == true {
        if requiresBonding {
          try await setTrusted(connection, value: true)
        }
        return
      }

      logger.debug(
        "Pairing with device",
        metadata: [
          BluetoothLogMetadata.deviceAddress: "\(deviceAddress)",
          "path": "\(devicePath)",
        ])

      let request = DBusRequest.createMethodCall(
        destination: client.busName,
        path: devicePath,
        interface: "org.bluez.Device1",
        method: "Pair"
      )

      if let reply = try await connection.send(request), reply.messageType == .error {
        let name = client.dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
        if name != "org.bluez.Error.AlreadyExists" {
          throw BluetoothError.invalidState("D-Bus Pair failed: \(name)")
        }
      }

      pairedValue = true
      updatePairingState(.paired)
      if requiresBonding {
        try await setTrusted(connection, value: true)
      }
    }

    private func setTrusted(_ connection: DBusClient.Connection, value: Bool) async throws {
      let request = DBusRequest.createMethodCall(
        destination: client.busName,
        path: devicePath,
        interface: "org.freedesktop.DBus.Properties",
        method: "Set",
        body: [
          .string("org.bluez.Device1"),
          .string("Trusted"),
          .variant(DBusVariant(.boolean(value))),
        ]
      )

      guard let reply = try await connection.send(request) else { return }
      if reply.messageType == .error {
        let name = client.dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
        throw BluetoothError.invalidState("D-Bus Set Trusted failed: \(name)")
      }
    }

    private func loadDeviceProperties(_ connection: DBusClient.Connection) async throws {
      let request = DBusRequest.createMethodCall(
        destination: client.busName,
        path: devicePath,
        interface: "org.freedesktop.DBus.Properties",
        method: "GetAll",
        body: [.string("org.bluez.Device1")]
      )
      guard let reply = try await connection.send(request), reply.messageType == .methodReturn
      else {
        return
      }
      guard let body = reply.body.first, case .dictionary(let props) = body else {
        return
      }
      handleProperties(props)
    }

    private func handleMessage(_ message: DBusMessage, connection: DBusClient.Connection) async {
      switch message.messageType {
      case .signal:
        break
      case .methodCall:
        await handleAgentMessage(message, connection: connection)
        return
      default:
        return
      }

      guard message.interface == "org.freedesktop.DBus.Properties" else { return }
      guard message.member == "PropertiesChanged" else { return }
      guard message.body.count >= 2 else { return }
      guard case .string(let iface) = message.body[0] else { return }
      guard case .dictionary(let props) = message.body[1] else { return }

      switch iface {
      case "org.bluez.Device1":
        guard message.path == devicePath else { return }
        handleProperties(props)
      case "org.bluez.GattCharacteristic1":
        guard let path = message.path else { return }
        handleCharacteristicProperties(path: path, properties: props)
      default:
        return
      }
    }

    private func handleAgentMessage(_ message: DBusMessage, connection: DBusClient.Connection) async
    {
      guard agentController == nil else { return }
      guard let path = message.path, path == agentPath else { return }
      guard let member = message.member else { return }

      if message.interface == "org.freedesktop.DBus.Introspectable", member == "Introspect" {
        await sendAgentReply(
          message,
          connection: connection,
          body: [.string(Self.agentIntrospectionXML)]
        )
        return
      }

      guard message.interface == "org.bluez.Agent1" else { return }

      switch member {
      case "Release":
        agentRegistered = false
        await sendAgentReply(message, connection: connection)
      case "RequestPinCode":
        if let pin = agentConfig.pinCode {
          await sendAgentReply(message, connection: connection, body: [.string(pin)])
        } else {
          await sendAgentError(
            message,
            connection: connection,
            name: "org.bluez.Error.Rejected",
            reason: "PIN code unavailable"
          )
        }
      case "DisplayPinCode":
        if let device = message.body.first?.objectPath,
          let code = message.body.dropFirst().first?.string
        {
          logger.info(
            "Display PIN code",
            metadata: [
              "device": "\(device)",
              "code": "\(code)",
            ])
        }
        await sendAgentReply(message, connection: connection)
      case "RequestPasskey":
        if let passkey = agentConfig.passkey {
          await sendAgentReply(message, connection: connection, body: [.uint32(passkey)])
        } else {
          await sendAgentError(
            message,
            connection: connection,
            name: "org.bluez.Error.Rejected",
            reason: "Passkey unavailable"
          )
        }
      case "DisplayPasskey":
        if let device = message.body.first?.objectPath,
          let passkey = message.body.dropFirst().first?.uint32
        {
          logger.info(
            "Display passkey",
            metadata: [
              "device": "\(device)",
              "passkey": "\(passkey)",
            ])
        }
        await sendAgentReply(message, connection: connection)
      case "RequestConfirmation":
        if let device = message.body.first?.objectPath,
          let passkey = message.body.dropFirst().first?.uint32
        {
          logger.info(
            "Request confirmation",
            metadata: [
              "device": "\(device)",
              "passkey": "\(passkey)",
            ])
        }
        if agentConfig.autoAccept {
          await sendAgentReply(message, connection: connection)
        } else {
          await sendAgentError(
            message,
            connection: connection,
            name: "org.bluez.Error.Rejected",
            reason: "User confirmation disabled"
          )
        }
      case "RequestAuthorization":
        if agentConfig.autoAccept {
          await sendAgentReply(message, connection: connection)
        } else {
          await sendAgentError(
            message,
            connection: connection,
            name: "org.bluez.Error.Rejected",
            reason: "Authorization disabled"
          )
        }
      case "AuthorizeService":
        if agentConfig.autoAccept {
          await sendAgentReply(message, connection: connection)
        } else {
          await sendAgentError(
            message,
            connection: connection,
            name: "org.bluez.Error.Rejected",
            reason: "Service authorization disabled"
          )
        }
      case "Cancel":
        await sendAgentReply(message, connection: connection)
      default:
        await sendAgentError(
          message,
          connection: connection,
          name: "org.bluez.Error.Rejected",
          reason: "Unsupported agent request"
        )
      }
    }

    private func sendAgentReply(
      _ message: DBusMessage,
      connection: DBusClient.Connection,
      body: [DBusValue] = []
    ) async {
      guard !message.flags.contains(.noReplyExpected) else { return }
      do {
        _ = try await connection.send(
          DBusRequest.createMethodReturn(replyingTo: message, body: body)
        )
      } catch {
        logger.debug(
          "Agent reply failed",
          metadata: [
            BluetoothLogMetadata.error: "\(error)"
          ])
      }
    }

    private func sendAgentError(
      _ message: DBusMessage,
      connection: DBusClient.Connection,
      name: String,
      reason: String
    ) async {
      guard !message.flags.contains(.noReplyExpected) else { return }
      do {
        _ = try await connection.send(
          DBusRequest.createError(
            replyingTo: message,
            errorName: name,
            body: [.string(reason)]
          )
        )
      } catch {
        logger.debug(
          "Agent error reply failed",
          metadata: [
            BluetoothLogMetadata.error: "\(error)"
          ])
      }
    }

    private func handleProperties(_ props: [DBusValue: DBusValue]) {
      for (keyValue, rawValue) in props {
        guard case .string(let key) = keyValue else { continue }
        let value = client.unwrapVariant(rawValue)

        switch key {
        case "Connected":
          if let connected = value.boolean {
            updateState(connected ? .connected : .disconnected(reason: nil))
            if !connected {
              requestStop()
            }
          }
        case "MTU":
          if let mtu = client.parseInt(value) {
            updateMtu(mtu)
          }
        case "RSSI":
          if let rssi = client.parseInt(value) {
            rssiValue = rssi
          }
        case "Paired":
          if let paired = value.boolean {
            pairedValue = paired
            updatePairingState(paired ? .paired : .unpaired)
          }
        case "ServicesResolved":
          if let resolved = value.boolean {
            updateServicesResolved(resolved)
          }
        case "AddressType":
          if case .string(let type) = value, let parsed = BlueZAddressType(bluezString: type) {
            addressType = parsed
          }
        default:
          break
        }
      }
    }

    private func handleCharacteristicProperties(path: String, properties: [DBusValue: DBusValue]) {
      guard let state = notificationStates[path] else { return }

      for (keyValue, rawValue) in properties {
        guard case .string(let key) = keyValue else { continue }
        guard key == "Value" else { continue }
        let value = client.unwrapVariant(rawValue)
        guard let data = client.dataFromValue(value) else { continue }
        let notification: GATTNotification =
          (state.type == .indication)
          ? .indication(data)
          : .notification(data)
        for continuation in state.continuations.values {
          continuation.yield(notification)
        }
      }

      notificationStates[path] = state
    }

    private func updateState(_ newState: PeripheralConnectionState) {
      guard stateValue != newState else { return }
      stateValue = newState
      for continuation in stateContinuations.values {
        continuation.yield(newState)
      }
    }

    private func updateMtu(_ mtu: Int) {
      guard mtuValue != mtu else { return }
      mtuValue = mtu
      for continuation in mtuContinuations.values {
        continuation.yield(mtu)
      }
    }

    private func updatePairingState(_ newState: PairingState) {
      guard pairingStateValue != newState else { return }
      pairingStateValue = newState
      for continuation in pairingStateContinuations.values {
        continuation.yield(newState)
      }
    }

    private func updateServicesResolved(_ resolved: Bool) {
      servicesResolved = resolved
      if resolved {
        resumeServicesResolvedWaiters()
      }
    }

    private func waitForServicesResolved() async {
      if servicesResolved || !isConnected() {
        return
      }

      await withCheckedContinuation { continuation in
        servicesResolvedWaiters.append(continuation)
      }
    }

    private func resumeServicesResolvedWaiters() {
      let waiters = servicesResolvedWaiters
      servicesResolvedWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
    }

    private func updateCaches(from cache: GattObjectCache) {
      servicePathByService.removeAll()
      for (path, service) in cache.servicesByPath {
        servicePathByService[service] = path
      }

      characteristicPathByCharacteristic.removeAll()
      for (path, characteristic) in cache.characteristicsByPath {
        characteristicPathByCharacteristic[characteristic] = path
      }

      descriptorPathByDescriptor.removeAll()
      for (path, descriptor) in cache.descriptorsByPath {
        descriptorPathByDescriptor[descriptor] = path
      }
    }

    private func loadGattObjects(_ connection: DBusClient.Connection) async throws
      -> GattObjectCache
    {
      let request = DBusRequest.createMethodCall(
        destination: client.busName,
        path: "/",
        interface: "org.freedesktop.DBus.ObjectManager",
        method: "GetManagedObjects"
      )

      guard let reply = try await connection.send(request), reply.messageType == .methodReturn
      else {
        return .empty
      }

      guard let body = reply.body.first, case .dictionary(let objects) = body else {
        return .empty
      }

      var servicesByPath: [String: GATTService] = [:]
      var characteristicsByPath: [String: GATTCharacteristic] = [:]
      var descriptorsByPath: [String: GATTDescriptor] = [:]
      var characteristicsByServicePath: [String: [String]] = [:]
      var descriptorsByCharacteristicPath: [String: [String]] = [:]

      for (pathValue, interfacesValue) in objects {
        guard case .objectPath(let path) = pathValue else { continue }
        guard path.hasPrefix(devicePath) else { continue }
        guard case .dictionary(let interfaces) = interfacesValue else { continue }
        guard let props = properties(for: "org.bluez.GattService1", in: interfaces) else {
          continue
        }

        if let device = propertyObjectPath(props, key: "Device"), device != devicePath {
          continue
        }

        if let service = parseService(props) {
          servicesByPath[path] = service
        }
      }

      for (pathValue, interfacesValue) in objects {
        guard case .objectPath(let path) = pathValue else { continue }
        guard path.hasPrefix(devicePath) else { continue }
        guard case .dictionary(let interfaces) = interfacesValue else { continue }
        guard let props = properties(for: "org.bluez.GattCharacteristic1", in: interfaces) else {
          continue
        }

        if let entry = parseCharacteristic(props, servicesByPath: servicesByPath) {
          characteristicsByPath[path] = entry.characteristic
          characteristicsByServicePath[entry.servicePath, default: []].append(path)
        }
      }

      for (pathValue, interfacesValue) in objects {
        guard case .objectPath(let path) = pathValue else { continue }
        guard path.hasPrefix(devicePath) else { continue }
        guard case .dictionary(let interfaces) = interfacesValue else { continue }
        guard let props = properties(for: "org.bluez.GattDescriptor1", in: interfaces) else {
          continue
        }

        if let entry = parseDescriptor(props, characteristicsByPath: characteristicsByPath) {
          descriptorsByPath[path] = entry.descriptor
          descriptorsByCharacteristicPath[entry.characteristicPath, default: []].append(path)
        }
      }

      return GattObjectCache(
        servicesByPath: servicesByPath,
        characteristicsByPath: characteristicsByPath,
        descriptorsByPath: descriptorsByPath,
        characteristicsByServicePath: characteristicsByServicePath,
        descriptorsByCharacteristicPath: descriptorsByCharacteristicPath
      )
    }

    private func resolveServicePath(_ service: GATTService, in cache: GattObjectCache) -> String? {
      if let path = cache.servicesByPath.first(where: { $0.value == service })?.key {
        return path
      }
      if service.instanceID == nil {
        return cache.servicesByPath.first(where: {
          $0.value.uuid == service.uuid && $0.value.isPrimary == service.isPrimary
        })?.key
      }
      return nil
    }

    private func resolveCharacteristicPath(
      _ characteristic: GATTCharacteristic, in cache: GattObjectCache
    ) -> String? {
      if let path = cache.characteristicsByPath.first(where: { $0.value == characteristic })?.key {
        return path
      }
      if characteristic.instanceID == nil {
        return cache.characteristicsByPath.first(where: {
          $0.value.uuid == characteristic.uuid
            && $0.value.service.uuid == characteristic.service.uuid
        })?.key
      }
      return nil
    }

    private func resolveCharacteristicPath(
      _ characteristic: GATTCharacteristic,
      connection: DBusClient.Connection
    ) async throws -> String {
      if let path = characteristicPathByCharacteristic[characteristic] {
        return path
      }

      let cache = try await loadGattObjects(connection)
      updateCaches(from: cache)
      if let path = resolveCharacteristicPath(characteristic, in: cache) {
        return path
      }

      throw BluetoothError.invalidState("GATT characteristic not found on BlueZ device")
    }

    private func resolveDescriptorPath(_ descriptor: GATTDescriptor, in cache: GattObjectCache)
      -> String?
    {
      if let path = cache.descriptorsByPath.first(where: { $0.value == descriptor })?.key {
        return path
      }
      return cache.descriptorsByPath.first(where: {
        $0.value.uuid == descriptor.uuid
          && $0.value.characteristic.uuid == descriptor.characteristic.uuid
          && $0.value.characteristic.service.uuid == descriptor.characteristic.service.uuid
      })?.key
    }

    private func resolveDescriptorPath(
      _ descriptor: GATTDescriptor,
      connection: DBusClient.Connection
    ) async throws -> String {
      if let path = descriptorPathByDescriptor[descriptor] {
        return path
      }

      let cache = try await loadGattObjects(connection)
      updateCaches(from: cache)
      if let path = resolveDescriptorPath(descriptor, in: cache) {
        return path
      }

      throw BluetoothError.invalidState("GATT descriptor not found on BlueZ device")
    }

    private func requestStop() {
      stopRequested = true
      if let continuation = stopContinuation {
        stopContinuation = nil
        continuation.resume()
      }
      resumeServicesResolvedWaiters()
      finishNotificationStreams()
    }

    private func waitForStop() async {
      if stopRequested {
        stopRequested = false
        return
      }

      await withCheckedContinuation { continuation in
        stopContinuation = continuation
      }
      stopContinuation = nil
      stopRequested = false
    }

    private func resumeConnectIfNeeded(error: Error? = nil) {
      guard let continuation = connectContinuation else { return }
      connectContinuation = nil
      if let error {
        continuation.resume(throwing: error)
      } else {
        continuation.resume()
      }
    }

    private func isConnected() -> Bool {
      switch stateValue {
      case .connected:
        return true
      case .connecting, .disconnected:
        return false
      }
    }

    private func removeStateContinuation(_ id: UUID) {
      stateContinuations[id] = nil
    }

    private func removeMtuContinuation(_ id: UUID) {
      mtuContinuations[id] = nil
    }

    private func removePairingStateContinuation(_ id: UUID) {
      pairingStateContinuations[id] = nil
    }

    private func cleanup() {
      stopRequested = false
      stopContinuation = nil
      connectContinuation = nil
      task?.cancel()
      task = nil
      servicesResolved = false
      resumeServicesResolvedWaiters()
      finishNotificationStreams()
      servicePathByService.removeAll()
      characteristicPathByCharacteristic.removeAll()
      descriptorPathByDescriptor.removeAll()
      if let handlerID = messageHandlerID {
        client.removeMessageHandler(handlerID)
        messageHandlerID = nil
      }
      if let agentController {
        Task { await agentController.unregisterDevice(path: devicePath) }
      }
    }

    private func removeNotificationContinuation(path: String, id: UUID) {
      guard var state = notificationStates[path] else { return }
      state.continuations[id] = nil
      if state.continuations.isEmpty {
        notificationStates[path] = nil
      } else {
        notificationStates[path] = state
      }
    }

    private func finishNotificationStreams(error: Error? = nil) {
      for state in notificationStates.values {
        for continuation in state.continuations.values {
          if let error {
            continuation.finish(throwing: error)
          } else {
            continuation.finish()
          }
        }
      }
      notificationStates.removeAll()
    }

    private func properties(
      for interfaceName: String,
      in interfaces: [DBusValue: DBusValue]
    ) -> [DBusValue: DBusValue]? {
      for (key, value) in interfaces {
        guard case .string(let name) = key, name == interfaceName else { continue }
        guard case .dictionary(let props) = value else { continue }
        return props
      }
      return nil
    }

    private func propertyValue(
      _ props: [DBusValue: DBusValue],
      key: String
    ) -> DBusValue? {
      for (keyValue, rawValue) in props {
        guard case .string(let name) = keyValue, name == key else { continue }
        return client.unwrapVariant(rawValue)
      }
      return nil
    }

    private func propertyString(_ props: [DBusValue: DBusValue], key: String) -> String? {
      propertyValue(props, key: key)?.string
    }

    private func propertyObjectPath(_ props: [DBusValue: DBusValue], key: String) -> String? {
      propertyValue(props, key: key)?.objectPath
    }

    private func propertyStringArray(_ props: [DBusValue: DBusValue], key: String) -> [String]? {
      guard let value = propertyValue(props, key: key) else { return nil }
      guard case .array(let values) = value else { return nil }
      var result: [String] = []
      for entry in values {
        guard let string = entry.string else { return nil }
        result.append(string)
      }
      return result
    }

    private func parseService(_ props: [DBusValue: DBusValue]) -> GATTService? {
      guard let uuidString = propertyString(props, key: "UUID"),
        let uuid = client.parseBluetoothUUID(uuidString)
      else {
        return nil
      }

      let isPrimary = propertyValue(props, key: "Primary")?.boolean ?? true
      let handle = propertyValue(props, key: "Handle").flatMap(client.parseInt)
      let instanceID = handle.map { UInt32($0) }
      return GATTService(uuid: uuid, isPrimary: isPrimary, instanceID: instanceID)
    }

    private func parseCharacteristic(
      _ props: [DBusValue: DBusValue],
      servicesByPath: [String: GATTService]
    ) -> (servicePath: String, characteristic: GATTCharacteristic)? {
      guard let uuidString = propertyString(props, key: "UUID"),
        let uuid = client.parseBluetoothUUID(uuidString)
      else {
        return nil
      }

      guard let servicePath = propertyObjectPath(props, key: "Service"),
        let service = servicesByPath[servicePath]
      else {
        return nil
      }

      let flags = propertyStringArray(props, key: "Flags") ?? []
      let properties = parseCharacteristicProperties(flags)
      let handle = propertyValue(props, key: "Handle").flatMap(client.parseInt)
      let instanceID = handle.map { UInt32($0) }

      let characteristic = GATTCharacteristic(
        uuid: uuid,
        properties: properties,
        instanceID: instanceID,
        service: service
      )

      return (servicePath, characteristic)
    }

    private func parseDescriptor(
      _ props: [DBusValue: DBusValue],
      characteristicsByPath: [String: GATTCharacteristic]
    ) -> (characteristicPath: String, descriptor: GATTDescriptor)? {
      guard let uuidString = propertyString(props, key: "UUID"),
        let uuid = client.parseBluetoothUUID(uuidString)
      else {
        return nil
      }

      guard let characteristicPath = propertyObjectPath(props, key: "Characteristic"),
        let characteristic = characteristicsByPath[characteristicPath]
      else {
        return nil
      }

      let descriptor = GATTDescriptor(uuid: uuid, characteristic: characteristic)
      return (characteristicPath, descriptor)
    }

    private func parseCharacteristicProperties(_ flags: [String]) -> GATTCharacteristicProperties {
      var properties: GATTCharacteristicProperties = []
      for flag in flags {
        switch flag {
        case "broadcast":
          properties.insert(.broadcast)
        case "read":
          properties.insert(.read)
        case "write":
          properties.insert(.write)
        case "write-without-response":
          properties.insert(.writeWithoutResponse)
        case "notify":
          properties.insert(.notify)
        case "indicate":
          properties.insert(.indicate)
        case "authenticated-signed-writes":
          properties.insert(.authenticatedSignedWrites)
        case "extended-properties":
          properties.insert(.extendedProperties)
        default:
          break
        }
      }
      return properties
    }

    private struct AgentConfig: Sendable {
      let capability: String
      let pinCode: String?
      let passkey: UInt32?
      let autoAccept: Bool

      static func load() -> AgentConfig {
        let logger = BluetoothLogger.backend
        let env = ProcessInfo.processInfo.environment
        let capabilityValue = env["BLUETOOTH_BLUEZ_AGENT_CAPABILITY"]?.trimmingCharacters(
          in: .whitespacesAndNewlines)
        let normalized = normalizeCapability(capabilityValue)

        if let capabilityValue, !capabilityValue.isEmpty, normalized != capabilityValue {
          logger.warning(
            "Unknown agent capability",
            metadata: [
              "provided": "\(capabilityValue)",
              "using": "\(normalized)",
            ])
        }

        let pin = env["BLUETOOTH_BLUEZ_AGENT_PIN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pinCode = (pin?.isEmpty == false) ? pin : nil

        let passkeyValue = env["BLUETOOTH_BLUEZ_AGENT_PASSKEY"]?.trimmingCharacters(
          in: .whitespacesAndNewlines)
        let passkey = passkeyValue.flatMap { UInt32($0) }
        if passkeyValue != nil, passkey == nil {
          logger.warning("Invalid BLUETOOTH_BLUEZ_AGENT_PASSKEY value")
        }

        let autoAcceptValue = env["BLUETOOTH_BLUEZ_AGENT_AUTO_ACCEPT"]?.trimmingCharacters(
          in: .whitespacesAndNewlines
        ).lowercased()
        let autoAccept = autoAcceptValue.map { ["1", "true", "yes", "on"].contains($0) } ?? true

        return AgentConfig(
          capability: normalized,
          pinCode: pinCode,
          passkey: passkey,
          autoAccept: autoAccept
        )
      }

      static func makeAgentPath() -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return "/org/wendylabsinc/bluetooth/agent\(suffix)"
      }

      private static func normalizeCapability(_ value: String?) -> String {
        let supported = [
          "DisplayOnly",
          "DisplayYesNo",
          "KeyboardOnly",
          "NoInputNoOutput",
          "KeyboardDisplay",
          "External",
        ]
        guard let value, !value.isEmpty else {
          return "NoInputNoOutput"
        }
        if supported.contains(value) {
          return value
        }
        return "NoInputNoOutput"
      }
    }

    private static let agentIntrospectionXML = """
      <!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
      <node>
        <interface name="org.freedesktop.DBus.Introspectable">
          <method name="Introspect">
            <arg name="data" type="s" direction="out"/>
          </method>
        </interface>
        <interface name="org.bluez.Agent1">
          <method name="Release"/>
          <method name="RequestPinCode">
            <arg name="device" type="o" direction="in"/>
            <arg name="pincode" type="s" direction="out"/>
          </method>
          <method name="DisplayPinCode">
            <arg name="device" type="o" direction="in"/>
            <arg name="pincode" type="s" direction="in"/>
          </method>
          <method name="RequestPasskey">
            <arg name="device" type="o" direction="in"/>
            <arg name="passkey" type="u" direction="out"/>
          </method>
          <method name="DisplayPasskey">
            <arg name="device" type="o" direction="in"/>
            <arg name="passkey" type="u" direction="in"/>
            <arg name="entered" type="q" direction="in"/>
          </method>
          <method name="RequestConfirmation">
            <arg name="device" type="o" direction="in"/>
            <arg name="passkey" type="u" direction="in"/>
          </method>
          <method name="RequestAuthorization">
            <arg name="device" type="o" direction="in"/>
          </method>
          <method name="AuthorizeService">
            <arg name="device" type="o" direction="in"/>
            <arg name="uuid" type="s" direction="in"/>
          </method>
          <method name="Cancel"/>
        </interface>
      </node>
      """

    private struct NotificationState {
      var type: GATTClientSubscriptionType
      var continuations: [UUID: AsyncThrowingStream<GATTNotification, Error>.Continuation]
    }

    private struct GattObjectCache {
      var servicesByPath: [String: GATTService]
      var characteristicsByPath: [String: GATTCharacteristic]
      var descriptorsByPath: [String: GATTDescriptor]
      var characteristicsByServicePath: [String: [String]]
      var descriptorsByCharacteristicPath: [String: [String]]

      static var empty: GattObjectCache {
        GattObjectCache(
          servicesByPath: [:],
          characteristicsByPath: [:],
          descriptorsByPath: [:],
          characteristicsByServicePath: [:],
          descriptorsByCharacteristicPath: [:]
        )
      }
    }

    private static func extractAddress(from peripheral: Peripheral) -> String? {
      let raw = peripheral.id.rawValue
      guard raw.hasPrefix("addr:") else { return nil }
      return String(raw.dropFirst("addr:".count))
    }
  }

#endif
