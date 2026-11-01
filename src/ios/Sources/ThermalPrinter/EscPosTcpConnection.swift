import Foundation
import Network

final class EscPosTcpConnection: EscPosDeviceConnection {
    static var connectTimeout: TimeInterval = 5
    static var localNetworkPermissionTimeout: TimeInterval = 60
    static var sendTimeout: TimeInterval = 30
    static let localNetworkPolicyDenied: Int32 = -65570

    enum WaitingDisposition: Equatable {
        case awaitLocalNetworkPermission
        case fail
    }

    static func waitingDisposition(for error: NWError, unsatisfiedReason: NWPath.UnsatisfiedReason?) -> WaitingDisposition {
        if unsatisfiedReason == .localNetworkDenied {
            return .awaitLocalNetworkPermission
        }
        if case .dns(let code) = error, code == localNetworkPolicyDenied {
            return .awaitLocalNetworkPermission
        }
        return .fail
    }

    private final class ConnectProgress {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var settled = false
        private var permissionPending = false

        var isSettled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return settled
        }

        var isPermissionPending: Bool {
            lock.lock()
            defer { lock.unlock() }
            return permissionPending
        }

        func settle() {
            lock.lock()
            let first = !settled
            settled = true
            lock.unlock()
            if first {
                semaphore.signal()
            }
        }

        func markPermissionPending() {
            lock.lock()
            permissionPending = true
            lock.unlock()
        }

        func wait(_ seconds: TimeInterval) -> DispatchTimeoutResult {
            semaphore.wait(timeout: .now() + seconds)
        }
    }

    let address: String
    let port: Int

    private let queue = DispatchQueue(label: "de.paystory.thermal-printer.tcp")
    private let lock = NSLock()
    private var connection: NWConnection?
    private var ready = false

    init(address: String, port: Int) {
        self.address = address
        self.port = port
    }

    override var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connection != nil && ready
    }

    @discardableResult
    override func connect() throws -> EscPosDeviceConnection {
        if isConnected {
            return self
        }
        guard (0...65535).contains(port) else {
            throw EscPosError.runtime("port out of range:\(port)")
        }
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw EscPosError.runtime("port out of range:\(port)")
        }
        disconnect()

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        let candidate = NWConnection(host: NWEndpoint.Host(address), port: endpointPort, using: parameters)
        let progress = ConnectProgress()

        candidate.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.lock.lock()
                self.ready = true
                self.lock.unlock()
                progress.settle()
            case .waiting(let error):
                if EscPosTcpConnection.waitingDisposition(for: error, unsatisfiedReason: candidate.currentPath?.unsatisfiedReason) == .awaitLocalNetworkPermission {
                    progress.markPermissionPending()
                } else {
                    self.markClosed(candidate)
                    progress.settle()
                }
            case .failed, .cancelled:
                self.markClosed(candidate)
                progress.settle()
            default:
                break
            }
        }

        lock.lock()
        connection = candidate
        ready = false
        lock.unlock()

        candidate.start(queue: queue)

        let started = Date()
        while !progress.isSettled {
            let limit = progress.isPermissionPending ? EscPosTcpConnection.localNetworkPermissionTimeout : EscPosTcpConnection.connectTimeout
            let remaining = started.addingTimeInterval(limit).timeIntervalSinceNow
            if remaining <= 0 {
                break
            }
            _ = progress.wait(min(remaining, 0.25))
        }
        if !isConnected {
            disconnect()
            throw EscPosError.connection("Unable to connect to TCP device.")
        }
        receiveLoop(candidate)
        clearBuffer()
        return self
    }

    @discardableResult
    override func disconnect() -> EscPosDeviceConnection {
        clearBuffer()
        lock.lock()
        let current = connection
        connection = nil
        ready = false
        lock.unlock()
        current?.stateUpdateHandler = nil
        current?.cancel()
        return self
    }

    override func transmit(_ bytes: [UInt8]) throws {
        lock.lock()
        let current = connection
        lock.unlock()
        guard let current = current else {
            throw EscPosError.connection("Unable to send data to device.")
        }
        let done = DispatchSemaphore(value: 0)
        var sendError: NWError?
        current.send(content: Data(bytes), completion: .contentProcessed { error in
            sendError = error
            done.signal()
        })
        if done.wait(timeout: .now() + EscPosTcpConnection.sendTimeout) == .timedOut {
            disconnect()
            throw EscPosError.connection("Timed out while sending data to device.")
        }
        if let error = sendError {
            disconnect()
            throw EscPosError.connection(error.localizedDescription)
        }
    }

    private func receiveLoop(_ current: NWConnection) {
        current.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            guard let self = self else { return }
            if isComplete || error != nil {
                self.markClosed(current)
                return
            }
            self.receiveLoop(current)
        }
    }

    private func markClosed(_ closed: NWConnection) {
        lock.lock()
        if connection === closed {
            ready = false
        }
        lock.unlock()
    }
}
