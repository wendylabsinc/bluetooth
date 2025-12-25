public enum BluetoothError: Error, Sendable, Equatable {
    case backendUnavailable
    case invalidState(String)
    case notSupported(String)
    case unimplemented(String)
}
