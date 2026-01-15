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

actor _BlueZPeripheralConnectionEventsController {
    private let client: BlueZClient
    private let objectManagerPath = "/"
    private let adapterPath: String

    private var isRunning = false
    private var continuation: AsyncThrowingStream<PeripheralConnectionEvent, Error>.Continuation?
    private var stopRequested = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var task: Task<Void, Never>?
    private var deviceStates: [String: DeviceState] = [:]
    private var devicePathMap: [String: String] = [:]
    private var messageHandlerID: UUID?

    init(client: BlueZClient, adapterPath: String) {
        self.client = client
        self.adapterPath = adapterPath
    }

    func start() async throws -> AsyncThrowingStream<PeripheralConnectionEvent, Error> {
        guard !isRunning else {
            throw BluetoothError.invalidState("BlueZ connection event stream already running")
        }

        isRunning = true
        deviceStates.removeAll()
        devicePathMap.removeAll()
        stopRequested = false

        task = Task { [weak self] in
            await self?.runDbusEvents()
        }

        return AsyncThrowingStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.stop() }
            }
        }
    }

    private func stop() {
        stopRequested = true
        if let continuation = stopContinuation {
            stopContinuation = nil
            continuation.resume()
        }
    }

    private func finish(error: Error? = nil) {
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
        cleanup()
    }

    private func cleanup() {
        isRunning = false
        continuation = nil
        stopRequested = false
        stopContinuation = nil
        task?.cancel()
        task = nil
        deviceStates.removeAll()
        devicePathMap.removeAll()
        if let handlerID = messageHandlerID {
            client.removeMessageHandler(handlerID)
            messageHandlerID = nil
        }
    }

    private func runDbusEvents() async {
        do {
            let connection = try await client.getConnection()

            let handlerID = client.addMessageHandler { [weak self] message in
                await self?.handleMessage(message)
            }
            messageHandlerID = handlerID

            try await addMatchRules(connection)
            try await loadManagedObjects(connection)
            await waitForStop()

            finish()
        } catch {
            finish(error: error)
        }
    }

    private func addMatchRules(_ connection: DBusClient.Connection) async throws {
        let rules = [
            "type='signal',sender='\(client.busName)',interface='org.freedesktop.DBus.ObjectManager',member='InterfacesAdded'",
            "type='signal',sender='\(client.busName)',interface='org.freedesktop.DBus.ObjectManager',member='InterfacesRemoved'",
            "type='signal',sender='\(client.busName)',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',arg0='org.bluez.Device1'",
        ]

        for rule in rules {
            try await client.addMatchRule(rule)
        }
    }

    private func loadManagedObjects(_ connection: DBusClient.Connection) async throws {
        let request = DBusRequest.createMethodCall(
            destination: client.busName,
            path: objectManagerPath,
            interface: "org.freedesktop.DBus.ObjectManager",
            method: "GetManagedObjects"
        )

        guard let reply = try await connection.send(request),
              reply.messageType == .methodReturn,
              let body = reply.body.first,
              case .dictionary(let objects) = body
        else {
            return
        }

        for (pathValue, interfacesValue) in objects {
            guard case .objectPath(let path) = pathValue else { continue }
            guard isAdapterDevicePath(path) else { continue }
            guard case .dictionary(let interfaces) = interfacesValue else { continue }
            if let props = properties(for: "org.bluez.Device1", in: interfaces) {
                updateDevice(path: path, properties: props, emitInitial: true)
            }
        }
    }

    private func handleMessage(_ message: DBusMessage) async {
        guard message.messageType == .signal else { return }
        guard let interface = message.interface, let member = message.member else { return }

        switch (interface, member) {
        case ("org.freedesktop.DBus.ObjectManager", "InterfacesAdded"):
            guard message.body.count >= 2 else { return }
            guard case .objectPath(let path) = message.body[0] else { return }
            guard isAdapterDevicePath(path) else { return }
            guard case .dictionary(let interfaces) = message.body[1] else { return }
            if let props = properties(for: "org.bluez.Device1", in: interfaces) {
                updateDevice(path: path, properties: props)
            }
        case ("org.freedesktop.DBus.ObjectManager", "InterfacesRemoved"):
            guard message.body.count >= 2 else { return }
            guard case .objectPath(let path) = message.body[0] else { return }
            guard isAdapterDevicePath(path) else { return }
            guard case .array(let values) = message.body[1] else { return }
            if values.contains(where: { value in
                if case .string(let name) = value {
                    return name == "org.bluez.Device1"
                }
                return false
            }) {
                removeDevice(path: path)
            }
        case ("org.freedesktop.DBus.Properties", "PropertiesChanged"):
            guard message.body.count >= 2 else { return }
            guard case .string(let iface) = message.body[0], iface == "org.bluez.Device1" else { return }
            guard case .dictionary(let props) = message.body[1] else { return }
            guard let path = message.path else { return }
            guard isAdapterDevicePath(path) else { return }
            updateDevice(path: path, properties: props)
        default:
            return
        }
    }

    private func updateDevice(
        path: String,
        properties: [DBusValue: DBusValue],
        emitInitial: Bool = false
    ) {
        guard isAdapterDevicePath(path) else { return }
        var address = devicePathMap[path] ?? addressFromPath(path)
        var connectedValue: Bool? = nil
        var pairedValue: Bool? = nil
        var nameUpdate: String? = nil

        for (keyValue, rawValue) in properties {
            guard case .string(let key) = keyValue else { continue }
            let value = client.unwrapVariant(rawValue)

            switch key {
            case "Address":
                if case .string(let addr) = value {
                    address = addr
                    devicePathMap[path] = addr
                }
            case "Name", "Alias":
                if case .string(let name) = value {
                    nameUpdate = sanitizeName(name)
                }
            case "Connected":
                connectedValue = value.boolean
            case "Paired":
                pairedValue = value.boolean
            default:
                break
            }
        }

        guard let address else { return }

        let wasKnown = deviceStates[address] != nil
        var state = deviceStates[address] ?? DeviceState(
            central: Central(id: .address(BluetoothAddress(address))),
            isConnected: false,
            isPaired: false
        )
        let previousConnected = state.isConnected
        let previousPaired = state.isPaired

        if let nameUpdate {
            state.central.name = nameUpdate
        }
        if let connectedValue {
            state.isConnected = connectedValue
        }
        if let pairedValue {
            state.isPaired = pairedValue
        }

        deviceStates[address] = state

        if let connectedValue {
            if !wasKnown && emitInitial && connectedValue {
                emit(.connected(state.central))
            } else if connectedValue != previousConnected {
                emit(connectedValue ? .connected(state.central) : .disconnected(state.central))
            }
        }

        if let pairedValue {
            if !wasKnown && emitInitial && pairedValue {
                emit(.paired(state.central))
            } else if pairedValue != previousPaired {
                emit(pairedValue ? .paired(state.central) : .unpaired(state.central))
            }
        }
    }

    private func removeDevice(path: String) {
        guard isAdapterDevicePath(path) else { return }
        let address = devicePathMap[path] ?? addressFromPath(path)
        guard let address else { return }
        if let state = deviceStates[address], state.isConnected {
            emit(.disconnected(state.central))
        }
        deviceStates[address] = nil
        devicePathMap[path] = nil
    }

    private func emit(_ event: PeripheralConnectionEvent) {
        continuation?.yield(event)
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

    private func sanitizeName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower == "n/a" || lower == "unknown" || lower == "na" {
            return nil
        }
        return trimmed
    }

    private func addressFromPath(_ path: String) -> String? {
        guard let range = path.range(of: "/dev_") else { return nil }
        let suffix = path[range.upperBound...]
        return suffix.replacingOccurrences(of: "_", with: ":")
    }

    private func isAdapterDevicePath(_ path: String) -> Bool {
        path.hasPrefix("\(adapterPath)/dev_")
    }

    private struct DeviceState {
        var central: Central
        var isConnected: Bool
        var isPaired: Bool
    }
}

#endif
