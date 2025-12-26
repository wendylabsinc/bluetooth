#if os(Linux)
#if canImport(FoundationEssentials)
import FoundationEssentials
import Foundation
#else
import Foundation
#endif

#if canImport(Glibc)
import Glibc
#endif

enum BlueZAddressType: UInt8, Sendable {
    case `public` = 0x01
    case random = 0x02

    init?(bluezString: String) {
        switch bluezString {
        case "public":
            self = .public
        case "random":
            self = .random
        default:
            return nil
        }
    }
}

enum BlueZL2CAP {
    struct Listener: Sendable {
        let fd: Int32
        let psm: L2CAPPSM
        let parameters: L2CAPChannelParameters
        let addressType: BlueZAddressType
    }

    static func createListener(parameters: L2CAPChannelParameters) throws -> Listener {
        let addressTypes: [BlueZAddressType] = [.public, .random]
        var lastError: BluetoothError?

        for addressType in addressTypes {
            let fd = try createSocket()
            switch bindAndListen(fd: fd, addressType: addressType) {
            case .success(let psm):
                return Listener(fd: fd, psm: psm, parameters: parameters, addressType: addressType)
            case .failure(let err):
                closeSocket(fd)
                lastError = systemError("L2CAP bind/listen", errnoCode: err)
                if err == EINVAL || err == EADDRNOTAVAIL {
                    continue
                }
                throw lastError ?? BluetoothError.invalidState("L2CAP bind/listen failed")
            }
        }

        throw lastError ?? BluetoothError.invalidState("L2CAP bind/listen failed")
    }

    static func acceptLoop(
        listener: Listener,
        continuation: AsyncThrowingStream<any L2CAPChannel, Error>.Continuation
    ) {
        while true {
            var addr = sockaddr_l2()
            var length = socklen_t(MemoryLayout<sockaddr_l2>.size)
            let clientFD = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listener.fd, $0, &length)
                }
            }

            if clientFD < 0 {
                let err = errno
                if err == EINTR {
                    continue
                }
                if err == EBADF || err == EINVAL {
                    break
                }
                continuation.finish(throwing: systemError("L2CAP accept", errnoCode: err))
                return
            }

            do {
                try applySecurityIfNeeded(fd: clientFD, parameters: listener.parameters)
            } catch {
                closeSocket(clientFD)
                continuation.finish(throwing: error)
                return
            }

            let mtus = readMTU(fd: clientFD)
            let channel = BlueZL2CAPChannel(
                fd: clientFD,
                psm: listener.psm,
                mtu: mtus.outgoing,
                incomingMTU: mtus.incoming
            )
            continuation.yield(channel)
        }

        continuation.finish()
    }

    static func closeListener(_ listener: Listener) {
        closeSocket(listener.fd)
    }

    static func openChannel(
        address: String,
        addressTypes: [BlueZAddressType],
        psm: L2CAPPSM,
        parameters: L2CAPChannelParameters
    ) async throws -> any L2CAPChannel {
        try await runBlocking {
            try connectChannel(
                address: address,
                addressTypes: addressTypes.isEmpty ? [.public, .random] : addressTypes,
                psm: psm,
                parameters: parameters
            )
        }
    }

    static func addressTypeCandidates(preferred: BlueZAddressType?) -> [BlueZAddressType] {
        if let preferred {
            return [preferred]
        }
        return [.public, .random]
    }

    private static func runBlocking<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func connectChannel(
        address: String,
        addressTypes: [BlueZAddressType],
        psm: L2CAPPSM,
        parameters: L2CAPChannelParameters
    ) throws -> BlueZL2CAPChannel {
        let parsedAddress = try parseAddress(address)
        var lastError: BluetoothError?

        for addressType in addressTypes {
            let fd = try createSocket()
            do {
                try applySecurityIfNeeded(fd: fd, parameters: parameters)
                try connect(fd: fd, address: parsedAddress, addressType: addressType, psm: psm)
                let mtus = readMTU(fd: fd)
                return BlueZL2CAPChannel(
                    fd: fd,
                    psm: psm,
                    mtu: mtus.outgoing,
                    incomingMTU: mtus.incoming
                )
            } catch let error as BluetoothError {
                closeSocket(fd)
                lastError = error
            } catch {
                closeSocket(fd)
                lastError = BluetoothError.invalidState("L2CAP connect failed: \(error)")
            }
        }

        throw lastError ?? BluetoothError.invalidState("L2CAP connect failed")
    }

    private static func createSocket() throws -> Int32 {
        let fd = socket(
            BlueZL2CAPConstants.afBluetooth,
            Int32(SOCK_SEQPACKET.rawValue),
            BlueZL2CAPConstants.btProtoL2CAP
        )
        if fd < 0 {
            throw systemError("L2CAP socket", errnoCode: errno)
        }
        return fd
    }

    private static func connect(
        fd: Int32,
        address: bdaddr_t,
        addressType: BlueZAddressType,
        psm: L2CAPPSM
    ) throws {
        var addr = makeSockaddrL2(
            psm: psm.rawValue,
            address: address,
            addressType: addressType
        )
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_l2>.size))
            }
        }
        if result != 0 {
            throw systemError("L2CAP connect", errnoCode: errno)
        }
    }

    private enum BindResult {
        case success(L2CAPPSM)
        case failure(Int32)
    }

    private static func bindAndListen(
        fd: Int32,
        addressType: BlueZAddressType
    ) -> BindResult {
        var addr = makeSockaddrL2(
            psm: 0,
            address: .any,
            addressType: addressType
        )

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_l2>.size))
            }
        }
        if bindResult != 0 {
            return .failure(errno)
        }

        if listen(fd, BlueZL2CAPConstants.listenBacklog) != 0 {
            return .failure(errno)
        }

        var boundAddr = sockaddr_l2()
        var length = socklen_t(MemoryLayout<sockaddr_l2>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }

        if nameResult != 0 {
            return .failure(errno)
        }

        let psmValue = UInt16(littleEndian: boundAddr.l2_psm)
        return .success(L2CAPPSM(rawValue: psmValue))
    }

    private static func applySecurityIfNeeded(
        fd: Int32,
        parameters: L2CAPChannelParameters
    ) throws {
        guard parameters.requiresEncryption else { return }
        var security = bt_security(level: BlueZL2CAPConstants.btSecurityMedium, key_size: 0)
        let result = withUnsafePointer(to: &security) { ptr in
            setsockopt(
                fd,
                BlueZL2CAPConstants.solBluetooth,
                BlueZL2CAPConstants.btSecurity,
                ptr,
                socklen_t(MemoryLayout<bt_security>.size)
            )
        }
        if result == 0 {
            return
        }

        let initialErrno = errno
        if initialErrno == EINVAL {
            var level = Int32(BlueZL2CAPConstants.btSecurityMedium)
            let fallback = withUnsafePointer(to: &level) { ptr in
                setsockopt(
                    fd,
                    BlueZL2CAPConstants.solBluetooth,
                    BlueZL2CAPConstants.btSecurity,
                    ptr,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }
            if fallback == 0 {
                return
            }
            let fallbackErrno = errno
            throw systemError("L2CAP security", errnoCode: fallbackErrno)
        }
        throw systemError("L2CAP security", errnoCode: initialErrno)
    }

    private static func readMTU(fd: Int32) -> (outgoing: Int, incoming: Int) {
        var options = l2cap_options()
        var length = socklen_t(MemoryLayout<l2cap_options>.size)
        let result = withUnsafeMutablePointer(to: &options) { ptr in
            getsockopt(
                fd,
                BlueZL2CAPConstants.solL2CAP,
                BlueZL2CAPConstants.l2capOptions,
                ptr,
                &length
            )
        }

        guard result == 0 else {
            return (BlueZL2CAPConstants.defaultMTU, BlueZL2CAPConstants.defaultMTU)
        }

        let outgoing = options.omtu == 0 ? BlueZL2CAPConstants.defaultMTU : Int(options.omtu)
        let incoming = options.imtu == 0 ? BlueZL2CAPConstants.defaultMTU : Int(options.imtu)
        return (outgoing, incoming)
    }

    private static func parseAddress(_ address: String) throws -> bdaddr_t {
        let parts = address.split(separator: ":")
        guard parts.count == 6 else {
            throw BluetoothError.invalidState("Invalid Bluetooth address: \(address)")
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(6)
        for part in parts {
            guard let byte = UInt8(part, radix: 16) else {
                throw BluetoothError.invalidState("Invalid Bluetooth address: \(address)")
            }
            bytes.append(byte)
        }
        bytes.reverse()
        return bdaddr_t(bytes)
    }

    private static func makeSockaddrL2(
        psm: UInt16,
        address: bdaddr_t,
        addressType: BlueZAddressType
    ) -> sockaddr_l2 {
        var addr = sockaddr_l2()
        addr.l2_family = sa_family_t(BlueZL2CAPConstants.afBluetooth)
        addr.l2_psm = psm.littleEndian
        addr.l2_bdaddr = address
        addr.l2_cid = 0
        addr.l2_bdaddr_type = addressType.rawValue
        return addr
    }

    private static func closeSocket(_ fd: Int32) {
        _ = shutdown(fd, Int32(SHUT_RDWR))
        _ = Glibc.close(fd)
    }

    fileprivate static func systemError(
        _ action: String,
        errnoCode: Int32
    ) -> BluetoothError {
        let message = String(cString: strerror(errnoCode))
        return BluetoothError.invalidState("\(action) failed: \(message) (errno \(errnoCode))")
    }
}

final class BlueZL2CAPChannel: L2CAPChannel, @unchecked Sendable {
    let psm: L2CAPPSM
    let mtu: Int

    private let fd: Int32
    private let incomingMTU: Int
    private let lock = NSLock()
    private var closed = false
    private var incomingStream: AsyncThrowingStream<Data, Error>?
    private var incomingTask: Task<Void, Never>?

    init(fd: Int32, psm: L2CAPPSM, mtu: Int, incomingMTU: Int) {
        self.fd = fd
        self.psm = psm
        self.mtu = mtu
        self.incomingMTU = incomingMTU
    }

    func send(_ data: Data) async throws {
        if data.count > mtu {
            throw BluetoothError.invalidState("L2CAP payload exceeds MTU (\(data.count) > \(mtu))")
        }

        let isClosed = withLock { closed }
        if isClosed {
            throw BluetoothError.invalidState("L2CAP channel closed")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let fd = fd
            let payload = data
            Task.detached {
                let result = payload.withUnsafeBytes { buffer in
                    guard let base = buffer.baseAddress else { return 0 }
                    return Glibc.send(fd, base, buffer.count, Int32(MSG_NOSIGNAL))
                }
                if result < 0 {
                    let err = errno
                    continuation.resume(throwing: BlueZL2CAP.systemError("L2CAP send", errnoCode: err))
                    return
                }
                if result != payload.count {
                    continuation.resume(throwing: BluetoothError.invalidState("L2CAP send truncated"))
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    func incoming() -> AsyncThrowingStream<Data, Error> {
        if withLock({ closed }) {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: BluetoothError.invalidState("L2CAP channel closed"))
            }
        }

        var continuation: AsyncThrowingStream<Data, Error>.Continuation?
        let stream = withLock { () -> AsyncThrowingStream<Data, Error> in
            if let existing = incomingStream {
                return existing
            }

            let stream = AsyncThrowingStream<Data, Error> { streamContinuation in
                continuation = streamContinuation
            }
            incomingStream = stream
            return stream
        }

        if let continuation {
            continuation.onTermination = { [weak self] _ in
                self?.closeAsync()
            }
            startReadLoop(
                fd: fd,
                bufferSize: max(incomingMTU, 1),
                continuation: continuation
            )
        }

        return stream
    }

    func close() async {
        closeNow()
    }

    private func closeAsync() {
        Task { await close() }
    }

    private func closeNow() {
        let shouldClose = withLock { () -> Bool in
            if closed {
                return false
            }
            closed = true
            return true
        }

        guard shouldClose else { return }

        _ = shutdown(fd, Int32(SHUT_RDWR))
        _ = Glibc.close(fd)
        let task = withLock { () -> Task<Void, Never>? in
            let task = incomingTask
            incomingTask = nil
            return task
        }
        task?.cancel()
    }

    private func startReadLoop(
        fd: Int32,
        bufferSize: Int,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) {
        let task = Task.detached {
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while true {
                let bytesRead = buffer.withUnsafeMutableBytes { ptr -> Int in
                    guard let base = ptr.baseAddress else { return -1 }
                    return recv(fd, base, ptr.count, 0)
                }

                if bytesRead > 0 {
                    continuation.yield(Data(buffer[0..<bytesRead]))
                    continue
                }

                if bytesRead == 0 {
                    break
                }

                let err = errno
                if err == EINTR {
                    continue
                }
                if err == EBADF || err == ENOTCONN || err == ECONNRESET {
                    break
                }
                continuation.finish(throwing: BlueZL2CAP.systemError("L2CAP receive", errnoCode: err))
                return
            }
            continuation.finish()
        }

        withLock {
            incomingTask = task
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private enum BlueZL2CAPConstants {
    static let afBluetooth: Int32 = 31
    static let btProtoL2CAP: Int32 = 0
    static let solBluetooth: Int32 = 274
    static let btSecurity: Int32 = 4
    static let btSecurityMedium: UInt8 = 2
    static let solL2CAP: Int32 = 6
    static let l2capOptions: Int32 = 0x01
    static let defaultMTU: Int = 672
    static let listenBacklog: Int32 = 5
}

private struct bdaddr_t: Sendable {
    var b: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    init(_ bytes: [UInt8]) {
        self.b = (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5])
    }

    static var any: bdaddr_t {
        bdaddr_t([0, 0, 0, 0, 0, 0])
    }
}

private struct sockaddr_l2: Sendable {
    var l2_family: sa_family_t = 0
    var l2_psm: UInt16 = 0
    var l2_bdaddr: bdaddr_t = .any
    var l2_cid: UInt16 = 0
    var l2_bdaddr_type: UInt8 = 0
    var l2_pad: UInt8 = 0
}

private struct l2cap_options: Sendable {
    var omtu: UInt16 = 0
    var imtu: UInt16 = 0
    var flush_to: UInt16 = 0
    var mode: UInt8 = 0
    var fcs: UInt8 = 0
    var max_tx: UInt8 = 0
    var txwin_size: UInt16 = 0
}

private struct bt_security: Sendable {
    var level: UInt8 = 0
    var key_size: UInt8 = 0
}

#endif
