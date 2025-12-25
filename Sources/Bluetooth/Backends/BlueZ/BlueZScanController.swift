#if os(Linux)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

actor _BlueZScanController {
    private var isScanning = false
    private var continuation: AsyncThrowingStream<ScanResult, Error>.Continuation?

    func startScan(
        filter: ScanFilter?,
        parameters: ScanParameters
    ) async throws -> AsyncThrowingStream<ScanResult, Error> {
        if isScanning {
            throw BluetoothError.invalidState("BlueZ scan already in progress")
        }

        isScanning = true
        _ = filter
        _ = parameters

        return AsyncThrowingStream { continuation in
            self.attach(continuation)
        }
    }

    func stopScan() {
        finish()
    }

    func emit(_ result: ScanResult) {
        continuation?.yield(result)
    }

    func finish(error: Error? = nil) {
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }

        cleanup()
    }

    private func attach(_ continuation: AsyncThrowingStream<ScanResult, Error>.Continuation) {
        self.continuation = continuation
        continuation.onTermination = { @Sendable _ in
            Task {
                await self.cleanup()
            }
        }
    }

    private func cleanup() {
        isScanning = false
        continuation = nil
    }
}

#endif
