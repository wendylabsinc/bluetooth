#if os(Linux)
  #if canImport(FoundationEssentials)
    import FoundationEssentials
    import Foundation
  #else
    import Foundation
  #endif

  import Logging
  import NIOCore
  import NIOFoundationCompat
  import NIOPosix

  #if canImport(Glibc)
    import Glibc
    private let system_close = Glibc.close
    private let system_connect = Glibc.connect
    private let system_bind = Glibc.bind
    private let system_send = Glibc.send
  #elseif canImport(Musl)
    import Musl
    private let system_close = Musl.close
    private let system_connect = Musl.connect
    private let system_bind = Musl.bind
    private let system_send = Musl.send
  #endif

  private let logger = BluetoothLogger.l2cap

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
    /// Shared event loop group for L2CAP channel I/O
    static let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

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
        logger.trace(
          "Trying to bind listener",
          metadata: [
            "addressType": "\(addressType)"
          ])
        let fd = try createSocket()

        switch bindAndListen(fd: fd, addressType: addressType) {
        case .success(let psm):
          logger.debug(
            "L2CAP listener created",
            metadata: [
              BluetoothLogMetadata.psm: "\(psm.rawValue)",
              "addressType": "\(addressType)",
              "fd": "\(fd)",
            ])
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
    ) async {
      while true {
        let clientFD = await acceptConnection(listenerFD: listener.fd)

        if clientFD < 0 {
          let err = -clientFD
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
        logger.debug(
          "Accepted L2CAP connection",
          metadata: [
            BluetoothLogMetadata.psm: "\(listener.psm.rawValue)",
            "fd": "\(clientFD)",
            "outgoingMTU": "\(mtus.outgoing)",
            "incomingMTU": "\(mtus.incoming)",
          ])

        do {
          let channel = try await BlueZL2CAPChannel.create(
            fd: clientFD,
            psm: listener.psm,
            mtu: mtus.outgoing,
            incomingMTU: mtus.incoming,
            eventLoopGroup: eventLoopGroup
          )
          continuation.yield(channel)
        } catch {
          closeSocket(clientFD)
          continuation.finish(throwing: error)
          return
        }
      }

      continuation.finish()
    }

    /// Accepts a connection on the listener socket using NIO's event loop for non-blocking I/O.
    private static func acceptConnection(listenerFD: Int32) async -> Int32 {
      await withCheckedContinuation { continuation in
        eventLoopGroup.next().execute {
          var addr = sockaddr_l2()
          var length = socklen_t(MemoryLayout<sockaddr_l2>.size)
          let clientFD = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
              accept(listenerFD, $0, &length)
            }
          }

          if clientFD < 0 {
            continuation.resume(returning: -errno)
          } else {
            continuation.resume(returning: clientFD)
          }
        }
      }
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
      try await connectChannel(
        address: address,
        addressTypes: addressTypes.isEmpty ? [.public, .random] : addressTypes,
        psm: psm,
        parameters: parameters
      )
    }

    static func addressTypeCandidates(preferred: BlueZAddressType?) -> [BlueZAddressType] {
      if let preferred {
        return [preferred]
      }
      return [.public, .random]
    }

    private static func connectChannel(
      address: String,
      addressTypes: [BlueZAddressType],
      psm: L2CAPPSM,
      parameters: L2CAPChannelParameters
    ) async throws -> BlueZL2CAPChannel {
      let parsedAddress = try parseAddress(address)
      var lastError: BluetoothError?

      for addressType in addressTypes {
        let fd: Int32
        do {
          fd = try createSocket()
        } catch {
          lastError =
            error as? BluetoothError ?? BluetoothError.invalidState("L2CAP socket failed: \(error)")
          continue
        }

        do {
          try applySecurityIfNeeded(fd: fd, parameters: parameters)
          try await connectSocket(
            fd: fd, address: parsedAddress, addressType: addressType, psm: psm)
          let mtus = readMTU(fd: fd)
          logger.debug(
            "Connected L2CAP channel",
            metadata: [
              BluetoothLogMetadata.psm: "\(psm.rawValue)",
              BluetoothLogMetadata.deviceAddress: "\(address)",
              "outgoingMTU": "\(mtus.outgoing)",
              "incomingMTU": "\(mtus.incoming)",
            ])
          return try await BlueZL2CAPChannel.create(
            fd: fd,
            psm: psm,
            mtu: mtus.outgoing,
            incomingMTU: mtus.incoming,
            eventLoopGroup: eventLoopGroup
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
      // NOTE: On Glibc, SOCK_SEQPACKET is imported as an enum-like type requiring
      // `.rawValue` to get the CInt value. On Musl, it's imported directly as a
      // CInt-compatible constant. We normalize both to Int32 for the socket() call.
      #if canImport(Glibc)
        let socketType = Int32(SOCK_SEQPACKET.rawValue)
      #elseif canImport(Musl)
        let socketType = SOCK_SEQPACKET
      #endif
      let fd = socket(
        BlueZL2CAPConstants.afBluetooth,
        socketType,
        BlueZL2CAPConstants.btProtoL2CAP
      )
      if fd < 0 {
        throw systemError("L2CAP socket", errnoCode: errno)
      }
      return fd
    }

    private static func connectSocket(
      fd: Int32,
      address: bdaddr_t,
      addressType: BlueZAddressType,
      psm: L2CAPPSM
    ) async throws {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        eventLoopGroup.next().execute {
          var addr = makeSockaddrL2(
            psm: psm.rawValue,
            address: address,
            addressType: addressType
          )
          let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
              system_connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_l2>.size))
            }
          }
          if result != 0 {
            continuation.resume(throwing: systemError("L2CAP connect", errnoCode: errno))
          } else {
            continuation.resume()
          }
        }
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
          system_bind(fd, $0, socklen_t(MemoryLayout<sockaddr_l2>.size))
        }
      }
      if bindResult != 0 {
        return .failure(errno)
      }

      // Set BT_RCVMTU AFTER bind - this is critical for BLE L2CAP CoC
      // The socket must be bound to an LE address type first before the kernel
      // recognizes it as a BLE socket and accepts the MTU setting.
      var mtu: UInt16 = 672
      _ = withUnsafePointer(to: &mtu) { ptr in
        setsockopt(
          fd,
          BlueZL2CAPConstants.solBluetooth,
          BlueZL2CAPConstants.btRcvMTU,
          ptr,
          socklen_t(MemoryLayout<UInt16>.size)
        )
      }

      // Also try setting L2CAP_OPTIONS.imtu for classic L2CAP compatibility
      var options = l2cap_options()
      options.imtu = mtu
      options.omtu = mtu
      _ = withUnsafePointer(to: &options) { ptr in
        setsockopt(
          fd,
          BlueZL2CAPConstants.solL2CAP,
          BlueZL2CAPConstants.l2capOptions,
          ptr,
          socklen_t(MemoryLayout<l2cap_options>.size)
        )
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
      // Try BLE L2CAP CoC socket options first (BT_RCVMTU/BT_SNDMTU)
      var rcvMtu: UInt16 = 0
      var sndMtu: UInt16 = 0
      var rcvLen = socklen_t(MemoryLayout<UInt16>.size)
      var sndLen = socklen_t(MemoryLayout<UInt16>.size)

      let rcvResult = withUnsafeMutablePointer(to: &rcvMtu) { ptr in
        getsockopt(fd, BlueZL2CAPConstants.solBluetooth, BlueZL2CAPConstants.btRcvMTU, ptr, &rcvLen)
      }
      let sndResult = withUnsafeMutablePointer(to: &sndMtu) { ptr in
        getsockopt(fd, BlueZL2CAPConstants.solBluetooth, BlueZL2CAPConstants.btSndMTU, ptr, &sndLen)
      }

      if rcvResult == 0 && sndResult == 0 && rcvMtu > 0 && sndMtu > 0 {
        logger.trace(
          "BLE CoC MTU negotiated",
          metadata: [
            "receiveMTU": "\(rcvMtu)",
            "sendMTU": "\(sndMtu)",
          ])
        return (Int(sndMtu), Int(rcvMtu))
      }

      // Fallback to classic L2CAP options
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
        logger.trace(
          "Using default MTU",
          metadata: [
            "mtu": "\(BlueZL2CAPConstants.defaultMTU)"
          ])
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
      _ = system_close(fd)
    }

    fileprivate static func systemError(
      _ action: String,
      errnoCode: Int32
    ) -> BluetoothError {
      let message = String(cString: strerror(errnoCode))
      return BluetoothError.invalidState("\(action) failed: \(message) (errno \(errnoCode))")
    }
  }

  /// L2CAP channel implementation using NIO's NIOAsyncChannel for async I/O.
  ///
  /// This implementation uses NIOPipeBootstrap to wrap the L2CAP socket file descriptor
  /// and NIOAsyncChannel for structured concurrency-based communication.
  final class BlueZL2CAPChannel: L2CAPChannel, Sendable {
    let psm: L2CAPPSM
    let mtu: Int

    private let asyncChannel: NIOAsyncChannel<ByteBuffer, ByteBuffer>

    init(
      asyncChannel: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
      psm: L2CAPPSM,
      mtu: Int
    ) {
      self.asyncChannel = asyncChannel
      self.psm = psm
      self.mtu = mtu
    }

    static func create(
      fd: Int32,
      psm: L2CAPPSM,
      mtu: Int,
      incomingMTU: Int,
      eventLoopGroup: EventLoopGroup
    ) async throws -> BlueZL2CAPChannel {
      // Set socket to non-blocking mode for NIO
      let flags = fcntl(fd, F_GETFL, 0)
      _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

      let asyncChannel = try await NIOPipeBootstrap(group: eventLoopGroup)
        .takingOwnershipOfDescriptor(inputOutput: fd) { channel in
          channel.eventLoop.makeCompletedFuture {
            try NIOAsyncChannel(
              wrappingChannelSynchronously: channel,
              configuration: NIOAsyncChannel.Configuration(
                inboundType: ByteBuffer.self,
                outboundType: ByteBuffer.self
              )
            )
          }
        }

      logger.debug(
        "Created L2CAP channel with NIOAsyncChannel",
        metadata: [
          BluetoothLogMetadata.psm: "\(psm.rawValue)",
          "fd": "\(fd)",
          "mtu": "\(mtu)",
          "incomingMTU": "\(incomingMTU)",
        ])

      return BlueZL2CAPChannel(
        asyncChannel: asyncChannel,
        psm: psm,
        mtu: mtu
      )
    }

    func send(_ data: Data) async throws {
      if data.count > mtu {
        throw BluetoothError.invalidState("L2CAP payload exceeds MTU (\(data.count) > \(mtu))")
      }

      var buffer = ByteBufferAllocator().buffer(capacity: data.count)
      buffer.writeBytes(data)

      try await asyncChannel.channel.writeAndFlush(buffer)

      logger.trace(
        "Sent L2CAP data",
        metadata: [
          BluetoothLogMetadata.bytesCount: "\(data.count)"
        ])
    }

    func incoming() -> AsyncThrowingStream<Data, Error> {
      logger.debug(
        "Creating L2CAP incoming stream",
        metadata: [
          BluetoothLogMetadata.psm: "\(psm.rawValue)"
        ])

      return AsyncThrowingStream { continuation in
        let task = Task {
          do {
            try await self.asyncChannel.executeThenClose { inbound, _ in
              for try await buffer in inbound {
                let data = Data(buffer: buffer)
                logger.trace(
                  "Received L2CAP data",
                  metadata: [
                    BluetoothLogMetadata.bytesCount: "\(data.count)"
                  ])
                continuation.yield(data)
              }
            }
            continuation.finish()
          } catch {
            logger.debug(
              "L2CAP incoming stream ended",
              metadata: [
                BluetoothLogMetadata.error: "\(error)"
              ])
            continuation.finish(throwing: error)
          }
        }

        continuation.onTermination = { _ in
          task.cancel()
        }
      }
    }

    func close() async {
      logger.debug(
        "Closing L2CAP channel",
        metadata: [
          BluetoothLogMetadata.psm: "\(psm.rawValue)"
        ])
      asyncChannel.channel.close(mode: .all, promise: nil)
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
    // BLE L2CAP CoC MTU socket options
    static let btRcvMTU: Int32 = 13
    static let btSndMTU: Int32 = 14
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
