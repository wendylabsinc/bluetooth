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

  /// A client for interacting with BlueZ over D-Bus.
  /// Provides a shared connection that can be used across multiple controllers.
  actor BlueZClient {
    let busName = "org.bluez"
    private let socketPath = "/var/run/dbus/system_bus_socket"
    private let logger = BluetoothLogger.dbus

    private var connection: DBusClient.Connection?
    private var objectServer: DBusObjectServer?
    private var connectionTask: Task<Void, Error>?
    private var connectionContinuations: [CheckedContinuation<DBusClient.Connection, Error>] = []
    private var messageHandlers: [UUID: @Sendable (DBusMessage) async -> Void] = [:]
    private var isConnecting = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var messageContinuation: AsyncStream<DBusMessage>.Continuation?

    init() {
      logger.trace("BlueZClient initialized")
    }

    /// Gets the connection, establishing it if necessary.
    func getConnection() async throws -> DBusClient.Connection {
      if let conn = connection {
        return conn
      }

      if isConnecting {
        logger.trace("Connection in progress, waiting...")
        // Wait for existing connection attempt - multiple waiters are supported
        return try await withCheckedThrowingContinuation { continuation in
          connectionContinuations.append(continuation)
        }
      }

      isConnecting = true
      logger.info(
        "Establishing D-Bus connection",
        metadata: [
          "socketPath": "\(socketPath)"
        ])

      let address = try SocketAddress(unixDomainSocketPath: socketPath)
      let auth = AuthType.external(userID: String(getuid()))

      // Start a long-running task that keeps the connection alive
      connectionTask = Task {
        do {
          try await DBusClient.withConnection(to: address, auth: auth) { conn in
            await self.setConnection(conn)
            await self.waitForShutdown()
          }
          self.logger.warning("D-Bus withConnection returned normally (unexpected)")
        } catch {
          self.logger.error(
            "D-Bus connection failed",
            metadata: [
              "error": "\(error)",
              "errorType": "\(type(of: error))",
            ])
        }
      }

      // Wait for connection to be established
      return try await withCheckedThrowingContinuation { continuation in
        connectionContinuations.append(continuation)
      }
    }

    /// Gets the object server, establishing connection if necessary.
    func getObjectServer() async throws -> DBusObjectServer {
      _ = try await getConnection()
      guard let server = objectServer else {
        throw BluetoothError.invalidState("BlueZ D-Bus object server not available")
      }
      return server
    }

    /// Sends a D-Bus request and returns the reply.
    func send(_ request: DBusRequest) async throws -> DBusMessage? {
      let conn = try await getConnection()
      return try await conn.send(request)
    }

    /// Registers a message handler that receives all incoming D-Bus messages.
    /// Returns an ID that can be used to unregister the handler.
    nonisolated func addMessageHandler(_ handler: @escaping @Sendable (DBusMessage) async -> Void)
      -> UUID
    {
      let id = UUID()
      Task {
        await self.registerHandler(id: id, handler: handler)
      }
      return id
    }

    private func registerHandler(id: UUID, handler: @escaping @Sendable (DBusMessage) async -> Void)
    {
      messageHandlers[id] = handler
    }

    /// Removes a message handler.
    nonisolated func removeMessageHandler(_ id: UUID) {
      Task {
        await self.unregisterHandler(id: id)
      }
    }

    private func unregisterHandler(id: UUID) {
      messageHandlers.removeValue(forKey: id)
    }

    /// Adds a D-Bus match rule for receiving signals.
    func addMatchRule(_ rule: String) async throws {
      logger.trace("Adding D-Bus match rule", metadata: ["rule": "\(rule)"])
      let conn = try await getConnection()
      let request = DBusRequest.createMethodCall(
        destination: "org.freedesktop.DBus",
        path: "/org/freedesktop/DBus",
        interface: "org.freedesktop.DBus",
        method: "AddMatch",
        body: [.string(rule)]
      )
      _ = try await conn.send(request)
    }

    // MARK: - Private

    private func setConnection(_ conn: DBusClient.Connection) async {
      connection = conn
      // Create the object server but DON'T let it set its own message handler
      // We'll route messages to it ourselves to avoid overwriting
      let server = DBusObjectServer(connection: conn, logger: logger)
      objectServer = server
      isConnecting = false

      // Create an AsyncStream to receive messages
      let (stream, continuation) = AsyncStream<DBusMessage>.makeStream()
      messageContinuation = continuation

      // Set a message handler that yields messages to the stream.
      // NOTE: We intentionally capture `continuation` strongly here. AsyncStream.Continuation
      // is a value-like handle to the stream and does not retain the DBusClient.Connection,
      // so this does not introduce a retain cycle. The lifetime of the continuation is
      // explicitly bounded: shutdown() calls messageContinuation?.finish() and clears it,
      // which terminates the stream and releases any associated resources.
      await conn.setMessageHandler { [logger] message in
        logger.debug(
          "BlueZClient received D-Bus message",
          metadata: [
            "type": "\(message.messageType)",
            "path": "\(message.path ?? "nil")",
            "interface": "\(message.interface ?? "nil")",
            "member": "\(message.member ?? "nil")",
          ])
        continuation.yield(message)
      }

      logger.info("D-Bus connection established")

      // Resume all waiting continuations
      let continuations = connectionContinuations
      connectionContinuations.removeAll()
      for continuation in continuations {
        continuation.resume(returning: conn)
      }

      // Run the message handling loop
      logger.debug("Starting message handling loop...")
      await run(stream: stream, server: server)
      logger.warning("Message handling loop exited (unexpected)")
    }

    /// Message handling loop that processes incoming D-Bus messages.
    private func run(stream: AsyncStream<DBusMessage>, server: DBusObjectServer) async {
      logger.debug("BlueZClient run loop started")
      for await message in stream {
        logger.debug(
          "BlueZClient processing message from stream",
          metadata: [
            "type": "\(message.messageType)",
            "path": "\(message.path ?? "nil")",
            "member": "\(message.member ?? "nil")",
          ])
        // First, let the object server handle method calls (Introspect, GetAll, etc.).
        // The object server exposes standard D-Bus introspection interfaces that BlueZ
        // calls as part of RegisterAdvertisement. BlueZ will typically:
        //   1. Call Introspect/GetAll on the advertisement object path to discover its
        //      interfaces and properties.
        //   2. Only then complete the RegisterAdvertisement call.
        //
        // If we ran user-registered handlers first, they could delay or interfere with
        // these method calls. To avoid this, we always give the object server the first
        // chance to handle each message.
        await server.handle(message: message)
        logger.trace("BlueZClient finished server.handle")

        // Then let any registered handlers also see the message (for signals, logging,
        // higher-level state updates, etc.). They observe the message after the core
        // D-Bus semantics (introspection, property access, etc.) have been applied.
        await handleMessage(message)
      }
      logger.debug("BlueZClient run loop ended")
    }

    private func waitForShutdown() async {
      await withCheckedContinuation { continuation in
        stopContinuation = continuation
      }
    }

    private func handleMessage(_ message: DBusMessage) async {
      let handlers = Array(messageHandlers.values)
      for handler in handlers {
        await handler(message)
      }
    }

    /// Shuts down the connection. Should be called when the application is done with BlueZ.
    func shutdown() async {
      logger.info("Shutting down D-Bus connection")

      connection = nil
      objectServer = nil
      messageHandlers.removeAll()
      isConnecting = false

      // Fail any pending connection waiters
      let pendingContinuations = connectionContinuations
      connectionContinuations.removeAll()
      for continuation in pendingContinuations {
        continuation.resume(throwing: BluetoothError.invalidState("D-Bus client shutdown"))
      }

      // Finish the message stream to stop the run loop
      messageContinuation?.finish()
      messageContinuation = nil

      if let continuation = stopContinuation {
        stopContinuation = nil
        continuation.resume()
      }

      connectionTask?.cancel()
      connectionTask = nil

      logger.debug("D-Bus connection shutdown complete")
    }
  }

  // MARK: - Convenience Extensions

  extension BlueZClient {
    /// Extracts the error name from a D-Bus error message.
    nonisolated func dbusErrorName(_ message: DBusMessage) -> String? {
      guard
        let field = message.headerFields.first(where: { $0.code == .errorName }),
        case .string(let name) = field.variant.value
      else {
        return nil
      }
      return name
    }

    /// Unwraps a D-Bus variant value.
    nonisolated func unwrapVariant(_ value: DBusValue) -> DBusValue {
      if case .variant(let variant) = value {
        return variant.value
      }
      return value
    }

    /// Parses an integer from a D-Bus value.
    nonisolated func parseInt(_ value: DBusValue) -> Int? {
      switch value {
      case .int16(let v): return Int(v)
      case .int32(let v): return Int(v)
      case .int64(let v): return Int(v)
      case .uint16(let v): return Int(v)
      case .uint32(let v): return Int(v)
      case .uint64(let v): return Int(v)
      default: return nil
      }
    }

    /// Converts a D-Bus byte array to Data.
    nonisolated func dataFromValue(_ value: DBusValue) -> Data? {
      let unwrapped = unwrapVariant(value)
      guard case .array(let values) = unwrapped else { return nil }
      var bytes: [UInt8] = []
      for entry in values {
        if case .byte(let byte) = entry {
          bytes.append(byte)
        } else {
          return nil
        }
      }
      return Data(bytes)
    }

    /// Parses a Bluetooth UUID from a string.
    nonisolated func parseBluetoothUUID(_ value: String) -> BluetoothUUID? {
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
  }

#endif
