public enum PeripheralConnectionEvent: Sendable, Hashable {
    case connected(Central)
    case disconnected(Central)
}
