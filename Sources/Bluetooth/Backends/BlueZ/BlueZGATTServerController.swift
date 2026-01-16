#if os(Linux)
  #if canImport(FoundationEssentials)
    import FoundationEssentials
    import Foundation
  #else
    import Foundation
  #endif

  import DBUS
  import NIOCore

  #if canImport(Glibc)
    import Glibc
  #elseif canImport(Musl)
    import Musl
  #endif

  actor _BlueZGATTServerController {
    private let client: BlueZClient
    private let adapterPath: String
    private let appPath = "/com/wendylabsinc/bluetooth"

    private var task: Task<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var stopRequested = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var isRegistered = false
    private var isStarted = false

    private var requestContinuation: AsyncThrowingStream<GATTServerRequest, Error>.Continuation?

    private var nextServiceID: UInt32 = 1
    private var nextCharacteristicID: UInt32 = 1

    private var serviceStates: [String: ServiceState] = [:]
    private var characteristicStates: [String: CharacteristicState] = [:]
    private var descriptorStates: [String: DescriptorState] = [:]
    private var characteristicPathByCharacteristic: [GATTCharacteristic: String] = [:]
    private var descriptorPathByDescriptor: [GATTDescriptor: String] = [:]
    private var preparedWrites: [UUID: PreparedWrite] = [:]
    private var preparedWriteIDsByCentral: [String: [UUID]] = [:]
    private var pendingExecuteByCentral: Set<String> = []

    init(client: BlueZClient, adapterPath: String) {
      self.client = client
      self.adapterPath = adapterPath
    }

    func addService(_ definition: GATTServiceDefinition) async throws -> GATTServiceRegistration {
      try await ensureStarted()
      let server = try await client.getObjectServer()
      let connection = try await client.getConnection()

      let servicePath = "\(appPath)/service\(nextServiceID)"
      let service = GATTService(
        uuid: definition.uuid, isPrimary: definition.isPrimary, instanceID: nextServiceID)
      nextServiceID &+= 1

      var characteristics: [GATTCharacteristic] = []
      var charStates: [CharacteristicState] = []

      for (index, charDef) in definition.characteristics.enumerated() {
        let charID = nextCharacteristicID
        nextCharacteristicID &+= 1
        let charPath = "\(servicePath)/char\(index)"
        let characteristic = GATTCharacteristic(
          uuid: charDef.uuid,
          properties: charDef.properties,
          instanceID: charID,
          service: service
        )

        let flags = characteristicFlags(for: charDef)
        if flags.isEmpty {
          throw BluetoothError.invalidState("GATT characteristic must have at least one flag")
        }

        let initialValue = charDef.initialValue ?? Data()

        var descriptorStates: [DescriptorState] = []
        for (descIndex, descDef) in charDef.descriptors.enumerated() {
          let descPath = "\(charPath)/desc\(descIndex)"
          let descriptor = GATTDescriptor(uuid: descDef.uuid, characteristic: characteristic)
          let descFlags = descriptorFlags(for: descDef)
          if descFlags.isEmpty {
            throw BluetoothError.invalidState("GATT descriptor must have at least one flag")
          }
          let descValue = descDef.initialValue ?? Data()

          let descState = DescriptorState(
            path: descPath,
            characteristicPath: charPath,
            descriptor: descriptor,
            definition: descDef,
            value: descValue,
            flags: descFlags
          )
          descriptorStates.append(descState)
        }

        let charState = CharacteristicState(
          path: charPath,
          servicePath: servicePath,
          characteristic: characteristic,
          definition: charDef,
          value: initialValue,
          flags: flags,
          descriptors: descriptorStates,
          notifyEnabled: false
        )
        charStates.append(charState)
        characteristics.append(characteristic)
      }

      let serviceState = ServiceState(
        path: servicePath,
        service: service,
        definition: definition,
        characteristics: charStates
      )

      try await export(serviceState: serviceState, server: server)

      if !isRegistered {
        try await registerApplication(connection)
        isRegistered = true
      } else {
        try await emitInterfacesAdded(for: serviceState, connection: connection)
      }

      return GATTServiceRegistration(service: service, characteristics: characteristics)
    }

    func removeService(_ registration: GATTServiceRegistration) async throws {
      try await ensureStarted()
      let server = try await client.getObjectServer()

      guard let servicePath = servicePath(for: registration.service),
        let serviceState = serviceStates[servicePath]
      else {
        throw BluetoothError.invalidState("GATT service not registered")
      }

      let removedPaths = await removeServiceObjects(serviceState, server: server)
      removePreparedWrites(for: removedPaths)
      serviceStates[servicePath] = nil
      await server.unexport(path: servicePath)

      if serviceStates.isEmpty, isRegistered {
        let connection = try await client.getConnection()
        try await unregisterApplication(connection)
        isRegistered = false
      }
    }

    func requests() async throws -> AsyncThrowingStream<GATTServerRequest, Error> {
      if requestContinuation != nil {
        throw BluetoothError.invalidState("BlueZ GATT request stream already active")
      }

      return AsyncThrowingStream { continuation in
        self.requestContinuation = continuation
        continuation.onTermination = { @Sendable _ in
          Task { await self.clearRequests() }
        }
      }
    }

    func updateValue(
      _ value: Data,
      for characteristic: GATTCharacteristic,
      type: GATTServerUpdateType
    ) async throws {
      guard let path = characteristicPathByCharacteristic[characteristic],
        var state = characteristicStates[path]
      else {
        throw BluetoothError.invalidState("Unknown GATT characteristic for BlueZ updateValue")
      }

      if type == .notification && !state.characteristic.properties.contains(.notify) {
        throw BluetoothError.invalidState("Characteristic does not support notifications")
      }
      if type == .indication && !state.characteristic.properties.contains(.indicate) {
        throw BluetoothError.invalidState("Characteristic does not support indications")
      }

      state.value = value
      let shouldNotify = state.notifyEnabled
      characteristicStates[path] = state

      guard shouldNotify else { return }
      let connection = try await client.getConnection()

      let bytes = value.map { DBusValue.byte($0) }
      let changed: [DBusValue: DBusValue] = [
        .string("Value"): .variant(DBusVariant(.array(bytes)))
      ]
      // DBusValue doesn't support typed empty arrays, so keep a placeholder to satisfy "as".
      let invalidated = DBusValue.array([.string("dummy")])
      let signal = DBusRequest.createSignal(
        path: path,
        interface: "org.freedesktop.DBus.Properties",
        name: "PropertiesChanged",
        body: [
          .string("org.bluez.GattCharacteristic1"),
          .dictionary(changed),
          invalidated,
        ],
        signature: "sa{sv}as"
      )

      _ = try await connection.send(signal)
    }

    private func clearRequests() {
      requestContinuation = nil
      preparedWrites.removeAll()
      preparedWriteIDsByCentral.removeAll()
      pendingExecuteByCentral.removeAll()
    }

    /// Ensures the GATT application object is exported.
    /// Thread-safety: Actor isolation guarantees this method runs serially,
    /// so concurrent calls cannot race on the `isStarted` check.
    private func ensureStarted() async throws {
      if isStarted {
        return
      }

      let server = try await client.getObjectServer()
      let application = makeApplicationObject()
      await server.export(application)
      isStarted = true
    }

    private func makeApplicationObject() -> DBusObjectServer.ExportedObject {
      let release = DBusObjectServer.Method(name: "Release") { [weak self] _ in
        await self?.handleRelease()
        return []
      }

      let applicationInterface = DBusObjectServer.Interface(
        name: "org.bluez.GattApplication1",
        methods: [release],
        properties: [],
        signals: []
      )

      return DBusObjectServer.ExportedObject(
        path: appPath,
        interfaces: [applicationInterface],
        exposesObjectManager: true
      )
    }

    private func handleRelease() async {
      requestStop()
    }

    private func requestStop() {
      stopRequested = true
      if let continuation = stopContinuation {
        stopContinuation = nil
        continuation.resume()
      }
    }

    private func registerApplication(_ connection: DBusClient.Connection) async throws {
      let request = DBusRequest.createMethodCall(
        destination: client.busName,
        path: adapterPath,
        interface: "org.bluez.GattManager1",
        method: "RegisterApplication",
        body: [
          .objectPath(appPath),
          .dictionary([:]),
        ],
        signature: "oa{sv}"
      )

      guard let reply = try await connection.send(request) else { return }
      if reply.messageType == .error {
        let name = client.dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
        throw BluetoothError.invalidState("D-Bus RegisterApplication failed: \(name)")
      }
    }

    private func unregisterApplication(_ connection: DBusClient.Connection) async throws {
      let request = DBusRequest.createMethodCall(
        destination: client.busName,
        path: adapterPath,
        interface: "org.bluez.GattManager1",
        method: "UnregisterApplication",
        body: [
          .objectPath(appPath)
        ]
      )

      guard let reply = try await connection.send(request) else { return }
      if reply.messageType == .error {
        let name = client.dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
        if name == "org.bluez.Error.DoesNotExist" {
          return
        }
        throw BluetoothError.invalidState("D-Bus UnregisterApplication failed: \(name)")
      }
    }

    private func export(serviceState: ServiceState, server: DBusObjectServer) async throws {
      let serviceObject = makeServiceObject(serviceState)
      serviceStates[serviceState.path] = serviceState
      await server.export(serviceObject)

      for charState in serviceState.characteristics {
        let charObject = makeCharacteristicObject(charState)
        characteristicStates[charState.path] = charState
        characteristicPathByCharacteristic[charState.characteristic] = charState.path
        await server.export(charObject)

        for descState in charState.descriptors {
          let descObject = makeDescriptorObject(descState)
          descriptorStates[descState.path] = descState
          descriptorPathByDescriptor[descState.descriptor] = descState.path
          await server.export(descObject)
        }
      }
    }

    private func servicePath(for service: GATTService) -> String? {
      serviceStates.first(where: { $0.value.service == service })?.key
    }

    private func removeServiceObjects(
      _ serviceState: ServiceState,
      server: DBusObjectServer
    ) async -> Set<String> {
      var removed: Set<String> = []

      for charState in serviceState.characteristics {
        for descState in charState.descriptors {
          removed.insert(descState.path)
          descriptorStates[descState.path] = nil
          descriptorPathByDescriptor[descState.descriptor] = nil
          await server.unexport(path: descState.path)
        }

        removed.insert(charState.path)
        characteristicStates[charState.path] = nil
        characteristicPathByCharacteristic[charState.characteristic] = nil
        await server.unexport(path: charState.path)
      }

      return removed
    }

    private func removePreparedWrites(for removedPaths: Set<String>) {
      guard !removedPaths.isEmpty else { return }

      var removedIDs: Set<UUID> = []
      for (id, write) in preparedWrites {
        let path: String
        switch write.target {
        case .characteristic(let value), .descriptor(let value):
          path = value
        }

        if removedPaths.contains(path) {
          removedIDs.insert(id)
        }
      }

      guard !removedIDs.isEmpty else { return }

      for id in removedIDs {
        preparedWrites[id] = nil
      }

      for (centralKey, ids) in preparedWriteIDsByCentral {
        let filtered = ids.filter { !removedIDs.contains($0) }
        if filtered.isEmpty {
          preparedWriteIDsByCentral[centralKey] = nil
        } else {
          preparedWriteIDsByCentral[centralKey] = filtered
        }
      }

      pendingExecuteByCentral = pendingExecuteByCentral.filter {
        preparedWriteIDsByCentral[$0] != nil
      }
    }

    private func emitInterfacesAdded(
      for serviceState: ServiceState,
      connection: DBusClient.Connection
    ) async throws {
      var objects: [InterfacesAddedPayload] = []
      objects.append(
        InterfacesAddedPayload(
          path: serviceState.path, interfaces: await serviceInterfaces(serviceState)))

      for charState in serviceState.characteristics {
        objects.append(
          InterfacesAddedPayload(
            path: charState.path, interfaces: await characteristicInterfaces(charState)))
        for descState in charState.descriptors {
          objects.append(
            InterfacesAddedPayload(
              path: descState.path, interfaces: await descriptorInterfaces(descState)))
        }
      }

      for object in objects {
        let request = DBusRequest.createSignal(
          path: appPath,
          interface: "org.freedesktop.DBus.ObjectManager",
          name: "InterfacesAdded",
          body: [
            .objectPath(object.path),
            .dictionary(object.interfaces),
          ],
          signature: "oa{sa{sv}}"
        )
        _ = try await connection.send(request)
      }
    }

    private func makeServiceObject(_ state: ServiceState) -> DBusObjectServer.ExportedObject {
      let properties = [
        DBusObjectServer.Property(name: "UUID", value: .string(state.service.uuid.description)),
        DBusObjectServer.Property(name: "Primary", value: .boolean(state.service.isPrimary)),
      ]
      let serviceInterface = DBusObjectServer.Interface(
        name: "org.bluez.GattService1",
        methods: [],
        properties: properties,
        signals: []
      )

      return DBusObjectServer.ExportedObject(path: state.path, interfaces: [serviceInterface])
    }

    private func makeCharacteristicObject(_ state: CharacteristicState)
      -> DBusObjectServer.ExportedObject
    {
      let read = DBusObjectServer.Method(
        name: "ReadValue",
        inputArgs: [.init(name: "options", type: "a{sv}")],
        outputArgs: [.init(name: "value", type: "ay")]
      ) { [weak self] context in
        guard let self else { return [] }
        let options = context.arguments.first
        let data = try await self.handleCharacteristicRead(path: context.path, options: options)
        let bytes = data.map { DBusValue.byte($0) }
        return [.array(bytes)]
      }

      let write = DBusObjectServer.Method(
        name: "WriteValue",
        inputArgs: [
          .init(name: "value", type: "ay"),
          .init(name: "options", type: "a{sv}"),
        ]
      ) { [weak self] context in
        guard let self else { return [] }
        let value = context.arguments.first
        let options = context.arguments.dropFirst().first
        try await self.handleCharacteristicWrite(path: context.path, value: value, options: options)
        return []
      }

      let startNotify = DBusObjectServer.Method(name: "StartNotify") { [weak self] context in
        guard let self else { return [] }
        try await self.handleStartNotify(path: context.path)
        return []
      }

      let stopNotify = DBusObjectServer.Method(name: "StopNotify") { [weak self] context in
        guard let self else { return [] }
        try await self.handleStopNotify(path: context.path)
        return []
      }

      let properties = [
        DBusObjectServer.Property(
          name: "UUID", value: .string(state.characteristic.uuid.description)),
        DBusObjectServer.Property(name: "Service", value: .objectPath(state.servicePath)),
        DBusObjectServer.Property(
          name: "Flags",
          signature: "as",
          access: .read,
          get: { _ in .array(state.flags.map { DBusValue.string($0) }) }
        ),
        DBusObjectServer.Property(
          name: "Value",
          signature: "ay",
          access: .read,
          get: { [weak self] _ in
            guard let self else { return .array([]) }
            let data = await self.valueForCharacteristic(path: state.path)
            let bytes = data.map { DBusValue.byte($0) }
            return .array(bytes)
          }
        ),
      ]

      let interface = DBusObjectServer.Interface(
        name: "org.bluez.GattCharacteristic1",
        methods: [read, write, startNotify, stopNotify],
        properties: properties,
        signals: []
      )

      return DBusObjectServer.ExportedObject(path: state.path, interfaces: [interface])
    }

    private func makeDescriptorObject(_ state: DescriptorState) -> DBusObjectServer.ExportedObject {
      let read = DBusObjectServer.Method(
        name: "ReadValue",
        inputArgs: [.init(name: "options", type: "a{sv}")],
        outputArgs: [.init(name: "value", type: "ay")]
      ) { [weak self] context in
        guard let self else { return [] }
        let options = context.arguments.first
        let data = try await self.handleDescriptorRead(path: context.path, options: options)
        let bytes = data.map { DBusValue.byte($0) }
        return [.array(bytes)]
      }

      let write = DBusObjectServer.Method(
        name: "WriteValue",
        inputArgs: [
          .init(name: "value", type: "ay"),
          .init(name: "options", type: "a{sv}"),
        ]
      ) { [weak self] context in
        guard let self else { return [] }
        let value = context.arguments.first
        let options = context.arguments.dropFirst().first
        try await self.handleDescriptorWrite(path: context.path, value: value, options: options)
        return []
      }

      let properties = [
        DBusObjectServer.Property(name: "UUID", value: .string(state.descriptor.uuid.description)),
        DBusObjectServer.Property(
          name: "Characteristic", value: .objectPath(state.characteristicPath)),
        DBusObjectServer.Property(
          name: "Flags",
          signature: "as",
          access: .read,
          get: { _ in .array(state.flags.map { DBusValue.string($0) }) }
        ),
        DBusObjectServer.Property(
          name: "Value",
          signature: "ay",
          access: .read,
          get: { [weak self] _ in
            guard let self else { return .array([]) }
            let data = await self.valueForDescriptor(path: state.path)
            let bytes = data.map { DBusValue.byte($0) }
            return .array(bytes)
          }
        ),
      ]

      let interface = DBusObjectServer.Interface(
        name: "org.bluez.GattDescriptor1",
        methods: [read, write],
        properties: properties,
        signals: []
      )

      return DBusObjectServer.ExportedObject(path: state.path, interfaces: [interface])
    }

    private func handleCharacteristicRead(path: String, options: DBusValue?) async throws -> Data {
      guard let state = characteristicStates[path] else {
        throw BluetoothError.invalidState("Unknown GATT characteristic for ReadValue")
      }
      guard supportsRead(flags: state.flags) else {
        throw BluetoothError.invalidState("Characteristic does not support read")
      }

      let parsed = parseOptions(options)
      let offset = parsed.offset ?? 0
      let central = parsed.central
      try await authorizeIfNeeded(
        parsed: parsed,
        central: central,
        target: .characteristic(state.characteristic),
        type: .read
      )

      if let continuation = requestContinuation {
        return try await withCheckedThrowingContinuation { continuationResult in
          let request = GATTReadRequest(
            central: central,
            characteristic: state.characteristic,
            offset: offset
          ) { result in
            Self.resume(continuationResult, with: result)
          }
          continuation.yield(.read(request))
        }
      }

      if offset > state.value.count {
        throw BluetoothError.invalidState("Read offset exceeds value length")
      }
      return state.value.dropFirst(offset)
    }

    private func handleCharacteristicWrite(
      path: String,
      value: DBusValue?,
      options: DBusValue?
    ) async throws {
      guard var state = characteristicStates[path] else {
        throw BluetoothError.invalidState("Unknown GATT characteristic for WriteValue")
      }
      guard supportsWrite(flags: state.flags) else {
        throw BluetoothError.invalidState("Characteristic does not support write")
      }

      guard let value, let data = client.dataFromValue(value) else {
        throw BluetoothError.invalidState("WriteValue payload is invalid")
      }

      let parsed = parseOptions(options)
      let offset = parsed.offset ?? 0
      let central = parsed.central
      let writeType: GATTWriteType = parsed.writeType
      let isPrepared = parsed.isPrepared
      let centralKey = preparedCentralKey(for: central)

      try await authorizeIfNeeded(
        parsed: parsed,
        central: central,
        target: .characteristic(state.characteristic),
        type: .write
      )

      if writeType == .withoutResponse && !state.flags.contains("write-without-response") {
        throw BluetoothError.invalidState("Characteristic does not support write without response")
      }

      if isPrepared {
        if let continuation = requestContinuation {
          let preparedID = storePreparedWrite(
            target: .characteristic(path),
            data: data,
            offset: offset,
            centralKey: centralKey
          )
          try await withCheckedThrowingContinuation { continuationResult in
            let request = GATTWriteRequest(
              central: central,
              characteristic: state.characteristic,
              value: data,
              offset: offset,
              writeType: writeType,
              isPreparedWrite: true
            ) { result in
              await self.recordPreparedWriteResult(id: preparedID, result: result)
              Self.resume(continuationResult, with: result)
            }
            continuation.yield(.write(request))
          }

          if preparedWriteApproved(id: preparedID) {
            emitExecuteIfNeeded(centralKey: centralKey, central: central)
          }
          return
        }

        state.value = try applyingWrite(data, to: state.value, offset: offset)
        characteristicStates[path] = state
        return
      }

      if let continuation = requestContinuation {
        try await withCheckedThrowingContinuation { continuationResult in
          let request = GATTWriteRequest(
            central: central,
            characteristic: state.characteristic,
            value: data,
            offset: offset,
            writeType: writeType,
            isPreparedWrite: isPrepared
          ) { result in
            Self.resume(continuationResult, with: result)
          }
          continuation.yield(.write(request))
        }
        state.value = try applyingWrite(data, to: state.value, offset: offset)
        characteristicStates[path] = state
        return
      }

      state.value = try applyingWrite(data, to: state.value, offset: offset)
      characteristicStates[path] = state
    }

    private func handleDescriptorRead(path: String, options: DBusValue?) async throws -> Data {
      guard let state = descriptorStates[path] else {
        throw BluetoothError.invalidState("Unknown GATT descriptor for ReadValue")
      }
      guard supportsRead(flags: state.flags) else {
        throw BluetoothError.invalidState("Descriptor does not support read")
      }

      let parsed = parseOptions(options)
      let offset = parsed.offset ?? 0
      let central = parsed.central
      try await authorizeIfNeeded(
        parsed: parsed,
        central: central,
        target: .descriptor(state.descriptor),
        type: .read
      )

      if let continuation = requestContinuation {
        return try await withCheckedThrowingContinuation { continuationResult in
          let request = GATTDescriptorReadRequest(
            central: central,
            descriptor: state.descriptor,
            offset: offset
          ) { result in
            Self.resume(continuationResult, with: result)
          }
          continuation.yield(.readDescriptor(request))
        }
      }

      if offset > state.value.count {
        throw BluetoothError.invalidState("Read offset exceeds value length")
      }
      return state.value.dropFirst(offset)
    }

    private func handleDescriptorWrite(
      path: String,
      value: DBusValue?,
      options: DBusValue?
    ) async throws {
      guard var state = descriptorStates[path] else {
        throw BluetoothError.invalidState("Unknown GATT descriptor for WriteValue")
      }
      guard supportsWrite(flags: state.flags) else {
        throw BluetoothError.invalidState("Descriptor does not support write")
      }

      guard let value, let data = client.dataFromValue(value) else {
        throw BluetoothError.invalidState("WriteValue payload is invalid")
      }

      let parsed = parseOptions(options)
      let offset = parsed.offset ?? 0
      let central = parsed.central
      let writeType: GATTWriteType = parsed.writeType
      let isPrepared = parsed.isPrepared
      let centralKey = preparedCentralKey(for: central)

      try await authorizeIfNeeded(
        parsed: parsed,
        central: central,
        target: .descriptor(state.descriptor),
        type: .write
      )

      if writeType == .withoutResponse && !state.flags.contains("write-without-response") {
        throw BluetoothError.invalidState("Descriptor does not support write without response")
      }

      if isPrepared {
        if let continuation = requestContinuation {
          let preparedID = storePreparedWrite(
            target: .descriptor(path),
            data: data,
            offset: offset,
            centralKey: centralKey
          )
          try await withCheckedThrowingContinuation { continuationResult in
            let request = GATTDescriptorWriteRequest(
              central: central,
              descriptor: state.descriptor,
              value: data,
              offset: offset,
              writeType: writeType,
              isPreparedWrite: true
            ) { result in
              await self.recordPreparedWriteResult(id: preparedID, result: result)
              Self.resume(continuationResult, with: result)
            }
            continuation.yield(.writeDescriptor(request))
          }

          if preparedWriteApproved(id: preparedID) {
            emitExecuteIfNeeded(centralKey: centralKey, central: central)
          }
          return
        }

        state.value = try applyingWrite(data, to: state.value, offset: offset)
        descriptorStates[path] = state
        return
      }

      if let continuation = requestContinuation {
        try await withCheckedThrowingContinuation { continuationResult in
          let request = GATTDescriptorWriteRequest(
            central: central,
            descriptor: state.descriptor,
            value: data,
            offset: offset,
            writeType: writeType,
            isPreparedWrite: isPrepared
          ) { result in
            Self.resume(continuationResult, with: result)
          }
          continuation.yield(.writeDescriptor(request))
        }
        state.value = try applyingWrite(data, to: state.value, offset: offset)
        descriptorStates[path] = state
        return
      }

      state.value = try applyingWrite(data, to: state.value, offset: offset)
      descriptorStates[path] = state
    }

    private func authorizeIfNeeded(
      parsed: ParsedOptions,
      central: Central?,
      target: GATTAuthorizationTarget,
      type: GATTAuthorizationType
    ) async throws {
      guard parsed.isPrepareAuthorize else { return }
      guard let continuation = requestContinuation else { return }

      let approved = await withCheckedContinuation { continuationResult in
        let request = GATTAuthorizationRequest(
          central: central,
          target: target,
          type: type
        ) { allowed in
          continuationResult.resume(returning: allowed)
        }
        continuation.yield(.authorize(request))
      }

      if !approved {
        throw BluetoothError.invalidState("GATT authorization rejected")
      }
    }

    private func handleStartNotify(path: String) async throws {
      guard var state = characteristicStates[path] else {
        throw BluetoothError.invalidState("Unknown GATT characteristic for StartNotify")
      }
      guard
        state.characteristic.properties.contains(.notify)
          || state.characteristic.properties.contains(.indicate)
      else {
        throw BluetoothError.invalidState("Characteristic does not support notify/indicate")
      }

      state.notifyEnabled = true
      characteristicStates[path] = state

      if let continuation = requestContinuation {
        let type: GATTClientSubscriptionType =
          state.characteristic.properties.contains(.notify) ? .notification : .indication
        let subscription = GATTSubscription(
          central: nil, characteristic: state.characteristic, type: type)
        continuation.yield(.subscribe(subscription))
      }
    }

    private func handleStopNotify(path: String) async throws {
      guard var state = characteristicStates[path] else {
        throw BluetoothError.invalidState("Unknown GATT characteristic for StopNotify")
      }
      state.notifyEnabled = false
      characteristicStates[path] = state

      if let continuation = requestContinuation {
        let type: GATTClientSubscriptionType =
          state.characteristic.properties.contains(.notify) ? .notification : .indication
        let subscription = GATTSubscription(
          central: nil, characteristic: state.characteristic, type: type)
        continuation.yield(.unsubscribe(subscription))
      }
    }

    private func valueForCharacteristic(path: String) -> Data {
      characteristicStates[path]?.value ?? Data()
    }

    private func valueForDescriptor(path: String) -> Data {
      descriptorStates[path]?.value ?? Data()
    }

    private func characteristicFlags(for definition: GATTCharacteristicDefinition) -> [String] {
      var flags: [String] = []
      func add(_ flag: String) {
        if !flags.contains(flag) {
          flags.append(flag)
        }
      }

      let props = definition.properties
      if props.contains(.broadcast) { add("broadcast") }
      if props.contains(.read) { add("read") }
      if props.contains(.write) { add("write") }
      if props.contains(.writeWithoutResponse) { add("write-without-response") }
      if props.contains(.notify) { add("notify") }
      if props.contains(.indicate) { add("indicate") }
      if props.contains(.authenticatedSignedWrites) { add("authenticated-signed-writes") }
      if props.contains(.extendedProperties) { add("extended-properties") }

      let perms = definition.permissions
      if perms.contains(.readable) && !props.contains(.read) { add("read") }
      if perms.contains(.writeable) && !props.contains(.write) { add("write") }
      if perms.contains(.readEncryptionRequired) { add("encrypt-read") }
      if perms.contains(.writeEncryptionRequired) { add("encrypt-write") }

      return flags
    }

    private func descriptorFlags(for definition: GATTDescriptorDefinition) -> [String] {
      var flags: [String] = []
      func add(_ flag: String) {
        if !flags.contains(flag) {
          flags.append(flag)
        }
      }

      let perms = definition.permissions
      if perms.contains(.readable) { add("read") }
      if perms.contains(.writeable) { add("write") }
      if perms.contains(.readEncryptionRequired) { add("encrypt-read") }
      if perms.contains(.writeEncryptionRequired) { add("encrypt-write") }

      return flags
    }

    private func supportsRead(flags: [String]) -> Bool {
      flags.contains("read") || flags.contains("encrypt-read")
    }

    private func supportsWrite(flags: [String]) -> Bool {
      flags.contains("write") || flags.contains("write-without-response")
        || flags.contains("encrypt-write")
    }

    private func parseOptions(_ value: DBusValue?) -> ParsedOptions {
      guard let value, case .dictionary(let dict) = value else {
        return ParsedOptions()
      }

      var result = ParsedOptions()
      for (keyValue, rawValue) in dict {
        guard case .string(let key) = keyValue else { continue }
        let value = client.unwrapVariant(rawValue)

        switch key {
        case "offset":
          result.offset = client.parseInt(value)
        case "device":
          if let path = value.objectPath {
            result.central = centralFromDevicePath(path)
          }
        case "type":
          if case .string(let typeValue) = value {
            switch typeValue {
            case "command":
              result.writeType = .withoutResponse
            case "reliable":
              result.writeType = .withResponse
              result.isPrepared = true
            default:
              result.writeType = .withResponse
            }
          }
        case "prepare":
          result.isPrepared = value.boolean ?? false
        case "prepare-authorize":
          let prepared = value.boolean ?? false
          result.isPrepared = prepared
          result.isPrepareAuthorize = prepared
        default:
          break
        }
      }

      return result
    }

    private func applyingWrite(_ data: Data, to current: Data, offset: Int) throws -> Data {
      guard offset >= 0 else {
        throw BluetoothError.invalidState("Write offset must be non-negative")
      }
      if offset > current.count {
        throw BluetoothError.invalidState("Write offset exceeds value length")
      }

      if offset == 0 {
        return data
      }

      var updated = current
      if updated.count < offset {
        updated.append(contentsOf: repeatElement(0, count: offset - updated.count))
      }
      if updated.count < offset + data.count {
        updated.append(contentsOf: repeatElement(0, count: offset + data.count - updated.count))
      }
      updated.replaceSubrange(offset..<(offset + data.count), with: data)
      return updated
    }

    private nonisolated static func resume<T: Sendable>(
      _ continuation: CheckedContinuation<T, Error>,
      with result: Result<T, GATTError>
    ) {
      switch result {
      case .success(let value):
        continuation.resume(returning: value)
      case .failure(let error):
        continuation.resume(throwing: error)
      }
    }

    private func preparedCentralKey(for central: Central?) -> String {
      central?.id.rawValue ?? "unknown"
    }

    private func storePreparedWrite(
      target: PreparedWriteTarget,
      data: Data,
      offset: Int,
      centralKey: String
    ) -> UUID {
      let id = UUID()
      let entry = PreparedWrite(
        id: id,
        target: target,
        data: data,
        offset: offset,
        centralKey: centralKey,
        approved: nil
      )
      preparedWrites[id] = entry
      preparedWriteIDsByCentral[centralKey, default: []].append(id)
      return id
    }

    private func recordPreparedWriteResult(id: UUID, result: Result<Void, GATTError>) {
      guard var entry = preparedWrites[id] else { return }
      switch result {
      case .success:
        entry.approved = true
      case .failure:
        entry.approved = false
      }
      preparedWrites[id] = entry
    }

    private func preparedWriteApproved(id: UUID) -> Bool {
      preparedWrites[id]?.approved == true
    }

    private func emitExecuteIfNeeded(centralKey: String, central: Central?) {
      guard let continuation = requestContinuation else { return }
      guard !pendingExecuteByCentral.contains(centralKey) else { return }
      pendingExecuteByCentral.insert(centralKey)

      let request = GATTExecuteWriteRequest(
        central: central,
        shouldCommit: true
      ) { result in
        await self.handleExecuteWrite(for: centralKey, result: result)
      }

      continuation.yield(.executeWrite(request))
    }

    private func handleExecuteWrite(for centralKey: String, result: Result<Void, GATTError>) async {
      defer { pendingExecuteByCentral.remove(centralKey) }
      let shouldCommit: Bool
      switch result {
      case .success:
        shouldCommit = true
      case .failure:
        shouldCommit = false
      }

      await commitPreparedWrites(for: centralKey, shouldCommit: shouldCommit)
    }

    private func commitPreparedWrites(for centralKey: String, shouldCommit: Bool) async {
      guard let ids = preparedWriteIDsByCentral.removeValue(forKey: centralKey) else { return }
      var entries: [PreparedWrite] = []
      for id in ids {
        if let entry = preparedWrites.removeValue(forKey: id) {
          entries.append(entry)
        }
      }

      guard shouldCommit else { return }
      guard entries.allSatisfy({ $0.approved == true }) else { return }

      for entry in entries {
        switch entry.target {
        case .characteristic(let path):
          guard var state = characteristicStates[path] else { continue }
          guard let updated = try? applyingWrite(entry.data, to: state.value, offset: entry.offset)
          else {
            continue
          }
          state.value = updated
          characteristicStates[path] = state
        case .descriptor(let path):
          guard var state = descriptorStates[path] else { continue }
          guard let updated = try? applyingWrite(entry.data, to: state.value, offset: entry.offset)
          else {
            continue
          }
          state.value = updated
          descriptorStates[path] = state
        }
      }
    }

    private func centralFromDevicePath(_ path: String) -> Central? {
      guard let range = path.range(of: "/dev_") else { return nil }
      let suffix = path[range.upperBound...]
      let address = suffix.replacingOccurrences(of: "_", with: ":")
      return Central(id: .address(BluetoothAddress(address)))
    }

    private func serviceInterfaces(_ state: ServiceState) async -> [DBusValue: DBusValue] {
      let props: [DBusValue: DBusValue] = [
        .string("UUID"): .variant(DBusVariant(.string(state.service.uuid.description))),
        .string("Primary"): .variant(DBusVariant(.boolean(state.service.isPrimary))),
      ]
      return [.string("org.bluez.GattService1"): .dictionary(props)]
    }

    private func characteristicInterfaces(_ state: CharacteristicState) async -> [DBusValue:
      DBusValue]
    {
      let value = valueForCharacteristic(path: state.path)
      let bytes = value.map { DBusValue.byte($0) }
      let props: [DBusValue: DBusValue] = [
        .string("UUID"): .variant(DBusVariant(.string(state.characteristic.uuid.description))),
        .string("Service"): .variant(DBusVariant(.objectPath(state.servicePath))),
        .string("Flags"): .variant(DBusVariant(.array(state.flags.map { .string($0) }))),
        .string("Value"): .variant(DBusVariant(.array(bytes))),
      ]
      return [.string("org.bluez.GattCharacteristic1"): .dictionary(props)]
    }

    private func descriptorInterfaces(_ state: DescriptorState) async -> [DBusValue: DBusValue] {
      let value = valueForDescriptor(path: state.path)
      let bytes = value.map { DBusValue.byte($0) }
      let props: [DBusValue: DBusValue] = [
        .string("UUID"): .variant(DBusVariant(.string(state.descriptor.uuid.description))),
        .string("Characteristic"): .variant(DBusVariant(.objectPath(state.characteristicPath))),
        .string("Flags"): .variant(DBusVariant(.array(state.flags.map { .string($0) }))),
        .string("Value"): .variant(DBusVariant(.array(bytes))),
      ]
      return [.string("org.bluez.GattDescriptor1"): .dictionary(props)]
    }

    private struct ServiceState {
      let path: String
      let service: GATTService
      let definition: GATTServiceDefinition
      let characteristics: [CharacteristicState]
    }

    private struct CharacteristicState {
      let path: String
      let servicePath: String
      let characteristic: GATTCharacteristic
      let definition: GATTCharacteristicDefinition
      var value: Data
      let flags: [String]
      let descriptors: [DescriptorState]
      var notifyEnabled: Bool
    }

    private struct DescriptorState {
      let path: String
      let characteristicPath: String
      let descriptor: GATTDescriptor
      let definition: GATTDescriptorDefinition
      var value: Data
      let flags: [String]
    }

    private struct InterfacesAddedPayload {
      let path: String
      let interfaces: [DBusValue: DBusValue]
    }

    private enum PreparedWriteTarget {
      case characteristic(String)
      case descriptor(String)
    }

    private struct PreparedWrite {
      let id: UUID
      let target: PreparedWriteTarget
      let data: Data
      let offset: Int
      let centralKey: String
      var approved: Bool?
    }

    private struct ParsedOptions {
      var offset: Int?
      var central: Central?
      var writeType: GATTWriteType = .withResponse
      var isPrepared: Bool = false
      var isPrepareAuthorize: Bool = false
    }
  }

#endif
