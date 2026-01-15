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

actor _BlueZPeripheralAgentController {
    private let client: BlueZClient
    private let managerPath = "/org/bluez"

    private enum PeerRole {
        case central
        case peripheral
    }

    private struct PeerContext {
        var central: Central?
        var peripheral: Peripheral?

        init(central: Central? = nil, peripheral: Peripheral? = nil) {
            self.central = central
            self.peripheral = peripheral
        }
    }

    private let agentPath: String
    private let config: AgentConfig
    private let requestTimeoutNanos: UInt64 = 30 * 1_000_000_000

    private var logger: Logger {
        var logger = BluetoothLogger.pairing
        logger[metadataKey: BluetoothLogMetadata.agentPath] = "\(agentPath)"
        return logger
    }

    private var task: Task<Void, Never>?
    private var stopRequested = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var agentRegistered = false
    private var pairingContinuation: AsyncThrowingStream<PairingRequest, Error>.Continuation?
    private var pendingResponses: [UUID: PendingResponse] = [:]
    private var deviceRoles: [String: PeerRole] = [:]
    private var messageHandlerID: UUID?

    init(client: BlueZClient) {
        self.client = client
        self.config = AgentConfig.load()
        self.agentPath = AgentConfig.makeAgentPath()
    }

    func startIfNeeded() async throws {
        if task != nil {
            return
        }

        stopRequested = false

        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            task = Task { [weak self] in
                await self?.run()
            }
        }
    }

    func stop() async {
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

    func pairingRequests() async throws -> AsyncThrowingStream<PairingRequest, Error> {
        if pairingContinuation != nil {
            throw BluetoothError.invalidState("BlueZ pairing request stream already active")
        }

        return AsyncThrowingStream { continuation in
            pairingContinuation = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.clearPairingState() }
            }
        }
    }

    func registerPeripheralDevice(path: String) {
        deviceRoles[path] = .peripheral
    }

    func unregisterDevice(path: String) {
        deviceRoles.removeValue(forKey: path)
    }

    private func run() async {
        do {
            let connection = try await client.getConnection()

            let handlerID = client.addMessageHandler { [weak self] message in
                await self?.handleMessage(message, connection: connection)
            }
            messageHandlerID = handlerID

            try await registerAgent(connection)
            resumeStartIfNeeded()
            await waitForStop()
            await unregisterAgent(connection)
        } catch {
            resumeStartIfNeeded(error: error)
        }

        cleanup()
    }

    private func handleMessage(_ message: DBusMessage, connection: DBusClient.Connection) async {
        guard message.messageType == .methodCall else { return }
        guard message.path == agentPath else { return }
        guard let member = message.member else { return }

        if message.interface == "org.freedesktop.DBus.Introspectable", member == "Introspect" {
            await sendReply(message, connection: connection, body: [.string(Self.agentIntrospectionXML)])
            return
        }

        guard message.interface == "org.bluez.Agent1" else { return }

        switch member {
        case "Release":
            agentRegistered = false
            await sendReply(message, connection: connection)
        case "RequestPinCode":
            await handleRequestPinCode(message, connection: connection)
        case "DisplayPinCode":
            await handleDisplayPinCode(message, connection: connection)
        case "RequestPasskey":
            await handleRequestPasskey(message, connection: connection)
        case "DisplayPasskey":
            await handleDisplayPasskey(message, connection: connection)
        case "RequestConfirmation":
            await handleRequestConfirmation(message, connection: connection)
        case "RequestAuthorization":
            await handleRequestAuthorization(message, connection: connection)
        case "AuthorizeService":
            await handleAuthorizeService(message, connection: connection)
        case "Cancel":
            await sendReply(message, connection: connection)
        default:
            await sendError(message, connection: connection, reason: "Unsupported agent request")
        }
    }

    private func handleRequestPinCode(_ message: DBusMessage, connection: DBusClient.Connection) async {
        let peer = peerContext(from: message)
        if let pin = await awaitPinCode(central: peer.central, peripheral: peer.peripheral) {
            await sendReply(message, connection: connection, body: [.string(pin)])
        } else {
            await sendError(message, connection: connection, reason: "PIN code unavailable")
        }
    }

    private func handleDisplayPinCode(_ message: DBusMessage, connection: DBusClient.Connection) async {
        let peer = peerContext(from: message)
        if let code = message.body.dropFirst().first?.string {
            if let continuation = pairingContinuation {
                let display = PairingDisplayPinCode(
                    central: peer.central,
                    pinCode: code,
                    peripheral: peer.peripheral
                )
                continuation.yield(.displayPinCode(display))
            }
            if let device = message.body.first?.objectPath {
                logger.info("DisplayPinCode request", metadata: [
                    BluetoothLogMetadata.devicePath: "\(device)",
                    "pinCode": "\(code)"
                ])
            }
        }
        await sendReply(message, connection: connection)
    }

    private func handleRequestPasskey(_ message: DBusMessage, connection: DBusClient.Connection) async {
        let peer = peerContext(from: message)
        if let passkey = await awaitPasskey(central: peer.central, peripheral: peer.peripheral) {
            await sendReply(message, connection: connection, body: [.uint32(passkey)])
        } else {
            await sendError(message, connection: connection, reason: "Passkey unavailable")
        }
    }

    private func handleDisplayPasskey(_ message: DBusMessage, connection: DBusClient.Connection) async {
        let peer = peerContext(from: message)
        let passkeyValue = message.body.dropFirst().first?.uint32
        let enteredValue = message.body.dropFirst(2).first?.uint16

        if let passkeyValue {
            if let continuation = pairingContinuation {
                let display = PairingDisplayPasskey(
                    central: peer.central,
                    passkey: passkeyValue,
                    entered: enteredValue,
                    peripheral: peer.peripheral
                )
                continuation.yield(.displayPasskey(display))
            }
            if let device = message.body.first?.objectPath {
                logger.info("DisplayPasskey request", metadata: [
                    BluetoothLogMetadata.devicePath: "\(device)",
                    "passkey": "\(passkeyValue)",
                    "entered": "\(enteredValue.map { String($0) } ?? "nil")"
                ])
            }
        }

        await sendReply(message, connection: connection)
    }

    private func handleRequestConfirmation(_ message: DBusMessage, connection: DBusClient.Connection) async {
        let peer = peerContext(from: message)
        let passkey = message.body.dropFirst().first?.uint32 ?? 0

        if let device = message.body.first?.objectPath {
            logger.info("RequestConfirmation", metadata: [
                BluetoothLogMetadata.devicePath: "\(device)",
                "passkey": "\(passkey)"
            ])
        }

        let accepted = await awaitConfirmation(
            central: peer.central,
            peripheral: peer.peripheral,
            passkey: passkey
        )
        if accepted {
            logger.debug("Confirmation accepted")
            await sendReply(message, connection: connection)
        } else {
            logger.info("Confirmation rejected")
            await sendError(message, connection: connection, reason: "User confirmation rejected")
        }
    }

    private func handleRequestAuthorization(_ message: DBusMessage, connection: DBusClient.Connection) async {
        let peer = peerContext(from: message)
        let accepted = await awaitAuthorization(central: peer.central, peripheral: peer.peripheral)
        if accepted {
            await sendReply(message, connection: connection)
        } else {
            await sendError(message, connection: connection, reason: "Authorization rejected")
        }
    }

    private func handleAuthorizeService(_ message: DBusMessage, connection: DBusClient.Connection) async {
        let peer = peerContext(from: message)
        let uuidString = message.body.dropFirst().first?.string
        let uuid = uuidString.flatMap(client.parseBluetoothUUID)
        let accepted = await awaitServiceAuthorization(
            central: peer.central,
            peripheral: peer.peripheral,
            serviceUUID: uuid
        )
        if accepted {
            await sendReply(message, connection: connection)
        } else {
            await sendError(message, connection: connection, reason: "Service authorization rejected")
        }
    }

    private func awaitPinCode(central: Central?, peripheral: Peripheral?) async -> String? {
        guard let continuation = pairingContinuation else {
            return config.pinCode
        }

        return await withCheckedContinuation { continuationResult in
            let id = UUID()
            pendingResponses[id] = .pinCode(continuationResult)
            let request = PairingRequest.pinCode(
                PairingPinCodeRequest(central: central, peripheral: peripheral) { [weak self] code in
                    guard let self else { return }
                    await self.resolvePinCode(id: id, value: code)
                }
            )
            continuation.yield(request)
            scheduleTimeout(id: id, kind: .pinCode)
        }
    }

    private func awaitPasskey(central: Central?, peripheral: Peripheral?) async -> UInt32? {
        guard let continuation = pairingContinuation else {
            return config.passkey
        }

        return await withCheckedContinuation { continuationResult in
            let id = UUID()
            pendingResponses[id] = .passkey(continuationResult)
            let request = PairingRequest.passkey(
                PairingPasskeyRequest(central: central, peripheral: peripheral) { [weak self] passkey in
                    guard let self else { return }
                    await self.resolvePasskey(id: id, value: passkey)
                }
            )
            continuation.yield(request)
            scheduleTimeout(id: id, kind: .passkey)
        }
    }

    private func awaitConfirmation(
        central: Central?,
        peripheral: Peripheral?,
        passkey: UInt32
    ) async -> Bool {
        guard let continuation = pairingContinuation else {
            return config.autoAccept
        }

        return await withCheckedContinuation { continuationResult in
            let id = UUID()
            pendingResponses[id] = .confirmation(continuationResult)
            let request = PairingRequest.confirmation(
                PairingConfirmationRequest(
                    central: central,
                    passkey: passkey,
                    peripheral: peripheral
                ) { [weak self] accepted in
                    guard let self else { return }
                    await self.resolveConfirmation(id: id, accepted: accepted)
                }
            )
            continuation.yield(request)
            scheduleTimeout(id: id, kind: .confirmation)
        }
    }

    private func awaitAuthorization(central: Central?, peripheral: Peripheral?) async -> Bool {
        guard let continuation = pairingContinuation else {
            return config.autoAccept
        }

        return await withCheckedContinuation { continuationResult in
            let id = UUID()
            pendingResponses[id] = .authorization(continuationResult)
            let request = PairingRequest.authorization(
                PairingAuthorizationRequest(central: central, peripheral: peripheral) { [weak self] accepted in
                    guard let self else { return }
                    await self.resolveAuthorization(id: id, accepted: accepted)
                }
            )
            continuation.yield(request)
            scheduleTimeout(id: id, kind: .authorization)
        }
    }

    private func awaitServiceAuthorization(
        central: Central?,
        peripheral: Peripheral?,
        serviceUUID: BluetoothUUID?
    ) async -> Bool {
        guard let continuation = pairingContinuation else {
            return config.autoAccept
        }

        return await withCheckedContinuation { continuationResult in
            let id = UUID()
            pendingResponses[id] = .serviceAuthorization(continuationResult)
            let request = PairingRequest.serviceAuthorization(
                PairingServiceAuthorizationRequest(
                    central: central,
                    serviceUUID: serviceUUID,
                    peripheral: peripheral
                ) { [weak self] accepted in
                    guard let self else { return }
                    await self.resolveServiceAuthorization(id: id, accepted: accepted)
                }
            )
            continuation.yield(request)
            scheduleTimeout(id: id, kind: .serviceAuthorization)
        }
    }

    private func registerAgent(_ connection: DBusClient.Connection) async throws {
        logger.info("Registering agent", metadata: [
            "capability": "\(config.capability)"
        ])

        let registerRequest = DBusRequest.createMethodCall(
            destination: client.busName,
            path: managerPath,
            interface: "org.bluez.AgentManager1",
            method: "RegisterAgent",
            body: [
                .objectPath(agentPath),
                .string(config.capability)
            ]
        )

        if let reply = try await connection.send(registerRequest), reply.messageType == .error {
            let name = client.dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
            if name != "org.bluez.Error.AlreadyExists" {
                logger.error("RegisterAgent failed", metadata: [BluetoothLogMetadata.error: "\(name)"])
                throw BluetoothError.invalidState("D-Bus RegisterAgent failed: \(name)")
            }
            logger.debug("Agent already registered")
        }

        let defaultRequest = DBusRequest.createMethodCall(
            destination: client.busName,
            path: managerPath,
            interface: "org.bluez.AgentManager1",
            method: "RequestDefaultAgent",
            body: [.objectPath(agentPath)]
        )

        if let reply = try await connection.send(defaultRequest), reply.messageType == .error {
            let name = client.dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
            if name != "org.bluez.Error.AlreadyExists" {
                logger.error("RequestDefaultAgent failed", metadata: [BluetoothLogMetadata.error: "\(name)"])
                throw BluetoothError.invalidState("D-Bus RequestDefaultAgent failed: \(name)")
            }
        }

        agentRegistered = true
        logger.info("Agent registered successfully")
    }

    private func unregisterAgent(_ connection: DBusClient.Connection) async {
        guard agentRegistered else { return }

        logger.debug("Unregistering agent")

        let request = DBusRequest.createMethodCall(
            destination: client.busName,
            path: managerPath,
            interface: "org.bluez.AgentManager1",
            method: "UnregisterAgent",
            body: [.objectPath(agentPath)]
        )

        do {
            if let reply = try await connection.send(request), reply.messageType == .error {
                let name = client.dbusErrorName(reply) ?? "org.freedesktop.DBus.Error.Failed"
                logger.warning("UnregisterAgent failed", metadata: [BluetoothLogMetadata.error: "\(name)"])
            } else {
                logger.info("Agent unregistered successfully")
            }
        } catch {
            logger.warning("UnregisterAgent failed", metadata: [BluetoothLogMetadata.error: "\(error)"])
        }

        agentRegistered = false
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

    private func resumeStartIfNeeded(error: Error? = nil) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func cleanup() {
        stopRequested = false
        stopContinuation = nil
        startContinuation = nil
        task?.cancel()
        task = nil
        agentRegistered = false
        deviceRoles.removeAll()
        if let handlerID = messageHandlerID {
            client.removeMessageHandler(handlerID)
            messageHandlerID = nil
        }
        Task { await clearPairingState() }
    }

    private func clearPairingState() async {
        pairingContinuation = nil
        let pending = pendingResponses
        pendingResponses.removeAll()
        for response in pending.values {
            switch response {
            case .pinCode(let continuation):
                continuation.resume(returning: nil)
            case .passkey(let continuation):
                continuation.resume(returning: nil)
            case .confirmation(let continuation):
                continuation.resume(returning: false)
            case .authorization(let continuation):
                continuation.resume(returning: false)
            case .serviceAuthorization(let continuation):
                continuation.resume(returning: false)
            }
        }
    }

    private func resolvePinCode(id: UUID, value: String?) async {
        guard let pending = pendingResponses.removeValue(forKey: id) else { return }
        guard case .pinCode(let continuation) = pending else { return }
        continuation.resume(returning: value)
    }

    private func resolvePasskey(id: UUID, value: UInt32?) async {
        guard let pending = pendingResponses.removeValue(forKey: id) else { return }
        guard case .passkey(let continuation) = pending else { return }
        continuation.resume(returning: value)
    }

    private func resolveConfirmation(id: UUID, accepted: Bool) async {
        guard let pending = pendingResponses.removeValue(forKey: id) else { return }
        guard case .confirmation(let continuation) = pending else { return }
        continuation.resume(returning: accepted)
    }

    private func resolveAuthorization(id: UUID, accepted: Bool) async {
        guard let pending = pendingResponses.removeValue(forKey: id) else { return }
        guard case .authorization(let continuation) = pending else { return }
        continuation.resume(returning: accepted)
    }

    private func resolveServiceAuthorization(id: UUID, accepted: Bool) async {
        guard let pending = pendingResponses.removeValue(forKey: id) else { return }
        guard case .serviceAuthorization(let continuation) = pending else { return }
        continuation.resume(returning: accepted)
    }

    private func scheduleTimeout(id: UUID, kind: PendingTimeoutKind) {
        guard requestTimeoutNanos > 0 else { return }
        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: self?.requestTimeoutNanos ?? 0)
            await self?.timeoutPending(id: id, kind: kind)
        }
    }

    private func timeoutPending(id: UUID, kind: PendingTimeoutKind) async {
        guard pendingResponses[id] != nil else { return }
        switch kind {
        case .pinCode:
            await resolvePinCode(id: id, value: nil)
        case .passkey:
            await resolvePasskey(id: id, value: nil)
        case .confirmation:
            await resolveConfirmation(id: id, accepted: false)
        case .authorization:
            await resolveAuthorization(id: id, accepted: false)
        case .serviceAuthorization:
            await resolveServiceAuthorization(id: id, accepted: false)
        }
    }

    private func peerContext(from message: DBusMessage) -> PeerContext {
        guard let path = message.body.first?.objectPath else { return PeerContext() }
        return peerContext(forDevicePath: path)
    }

    private func peerContext(forDevicePath path: String) -> PeerContext {
        guard let address = deviceAddress(from: path) else { return PeerContext() }

        switch deviceRoles[path] ?? .central {
        case .central:
            return PeerContext(central: Central(id: .address(address)), peripheral: nil)
        case .peripheral:
            return PeerContext(central: nil, peripheral: Peripheral(id: .address(address)))
        }
    }

    private func deviceAddress(from path: String) -> BluetoothAddress? {
        let component = path.split(separator: "/").last.map(String.init) ?? path
        guard component.hasPrefix("dev_") else { return nil }
        let addr = component.dropFirst("dev_".count).replacingOccurrences(of: "_", with: ":").lowercased()
        return BluetoothAddress(addr)
    }

    private func sendReply(
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
            logger.warning("Agent reply failed", metadata: [BluetoothLogMetadata.error: "\(error)"])
        }
    }

    private func sendError(
        _ message: DBusMessage,
        connection: DBusClient.Connection,
        reason: String
    ) async {
        guard !message.flags.contains(.noReplyExpected) else { return }
        do {
            _ = try await connection.send(
                DBusRequest.createError(
                    replyingTo: message,
                    errorName: "org.bluez.Error.Rejected",
                    body: [.string(reason)]
                )
            )
        } catch {
            logger.warning("Agent error reply failed", metadata: [BluetoothLogMetadata.error: "\(error)"])
        }
    }

    private struct AgentConfig: Sendable {
        let capability: String
        let pinCode: String?
        let passkey: UInt32?
        let autoAccept: Bool

        static func load() -> AgentConfig {
            let logger = BluetoothLogger.pairing
            let env = ProcessInfo.processInfo.environment
            let capabilityValue = env["BLUETOOTH_BLUEZ_AGENT_CAPABILITY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = normalizeCapability(capabilityValue)

            if let capabilityValue, !capabilityValue.isEmpty, normalized != capabilityValue {
                logger.warning("Unknown agent capability, using default", metadata: [
                    "requested": "\(capabilityValue)",
                    "using": "\(normalized)"
                ])
            }

            let pin = env["BLUETOOTH_BLUEZ_AGENT_PIN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let pinCode = (pin?.isEmpty == false) ? pin : nil

            let passkeyValue = env["BLUETOOTH_BLUEZ_AGENT_PASSKEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let passkey = passkeyValue.flatMap { UInt32($0) }
            if passkeyValue != nil, passkey == nil {
                logger.warning("Invalid BLUETOOTH_BLUEZ_AGENT_PASSKEY value, ignoring")
            }

            let autoAcceptValue = env["BLUETOOTH_BLUEZ_AGENT_AUTO_ACCEPT"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let autoAccept = autoAcceptValue.map { ["1", "true", "yes", "on"].contains($0) } ?? true

            logger.debug("Agent config loaded", metadata: [
                "capability": "\(normalized)",
                "hasPinCode": "\(pinCode != nil)",
                "hasPasskey": "\(passkey != nil)",
                "autoAccept": "\(autoAccept)"
            ])

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
                "External"
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

    private enum PendingResponse {
        case pinCode(CheckedContinuation<String?, Never>)
        case passkey(CheckedContinuation<UInt32?, Never>)
        case confirmation(CheckedContinuation<Bool, Never>)
        case authorization(CheckedContinuation<Bool, Never>)
        case serviceAuthorization(CheckedContinuation<Bool, Never>)
    }

    private enum PendingTimeoutKind {
        case pinCode
        case passkey
        case confirmation
        case authorization
        case serviceAuthorization
    }
}

#endif
