public enum PeripheralConnectionState: Sendable, Hashable {
    case connecting
    case connected
    case disconnected(reason: String?)
}

