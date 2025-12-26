public enum PeripheralConnectionEvent: Sendable, Hashable {
    case connected(Central)
    case disconnected(Central)
    case paired(Central)
    case unpaired(Central)
}
