public enum BluetoothError: Error, Sendable, Equatable {
    case backendUnavailable
    case invalidState(String)
    case notSupported(String)
    case unimplemented(String)
    case notReady(String)
    case connectionFailed(String)
    case invalidPeripheral(String)
    case serviceNotFound(String)
    case characteristicNotFound(String)
    case descriptorNotFound(String)
    case serviceRegistrationFailed(String)
    case notificationFailed(String)
    case l2capChannelError(String)
}
