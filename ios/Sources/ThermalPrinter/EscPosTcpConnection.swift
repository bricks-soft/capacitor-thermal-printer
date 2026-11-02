import Foundation
import Network

protocol EscPosNetworkConnection: AnyObject {
    var stateUpdateHandler: ((NWConnection.State) -> Void)? { get set }
    var unsatisfiedReason: NWPath.UnsatisfiedReason? { get }
    func start(queue: DispatchQueue)
    func send(_ data: Data, completion: @escaping (NWError?) -> Void)
    func receive(completion: @escaping (_ isComplete: Bool, _ error: NWError?) -> Void)
    func cancel()
}

final class EscPosNWConnection: EscPosNetworkConnection {
    private let connection: NWConnection

    init(host: String, port: NWEndpoint.Port) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: NWParameters(tls: nil, tcp: tcp))
    }

    var stateUpdateHandler: ((NWConnection.State) -> Void)? {
        get { connection.stateUpdateHandler }
        set { connection.stateUpdateHandler = newValue }
    }

    var unsatisfiedReason: NWPath.UnsatisfiedReason? {
        connection.currentPath?.unsatisfiedReason
    }

    func start(queue: DispatchQueue) {
        connection.start(queue: queue)
    }

    func send(_ data: Data, completion: @escaping (NWError?) -> Void) {
        connection.send(content: data, completion: .contentProcessed(completion))
    }

    func receive(completion: @escaping (Bool, NWError?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, isComplete, error in
            completion(isComplete, error)
        }
    }

    func cancel() {
        connection.cancel()
    }
}

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

        func wait(_ seconds: TimeInterval) {
            _ = semaphore.wait(timeout: .now() + seconds)
        }
    }

    private final class LockedError {
        private let lock = NSLock()
        private var stored: NWError?

        var value: NWError? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func set(_ error: NWError?) {
            lock.lock()
            stored = error
            lock.unlock()
        }
    }

    let address: String
    let port: Int

    private let queue = DispatchQueue(label: "de.paystory.thermal-printer.tcp")
    private let lock = NSLock()
    private let makeConnection: (String, NWEndpoint.Port) -> EscPosNetworkConnection
    private var connection: EscPosNetworkConnection?
    private var ready = false

    init(address: String, port: Int, makeConnection: @escaping (String, NWEndpoint.Port) -> EscPosNetworkConnection = { EscPosNWConnection(host: $0, port: $1) }) {
        self.address = address
        self.port = port
        self.makeConnection = makeConnection
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
        guard (0...65535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw EscPosError.runtime("port out of range:\(port)")
        }
        disconnect()

        let candidate = makeConnection(address, endpointPort)
        let progress = ConnectProgress()

        candidate.stateUpdateHandler = { [weak self, weak candidate] state in
            guard let self = self, let candidate = candidate else { return }
            switch state {
            case .ready:
                self.lock.lock()
                if self.connection === candidate {
                    self.ready = true
                }
                self.lock.unlock()
                progress.settle()
            case .waiting(let error):
                if EscPosTcpConnection.waitingDisposition(for: error, unsatisfiedReason: candidate.unsatisfiedReason) == .awaitLocalNetworkPermission {
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
            progress.wait(min(remaining, 0.05))
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
        let outcome = LockedError()
        current.send(Data(bytes)) { error in
            outcome.set(error)
            done.signal()
        }
        if done.wait(timeout: .now() + EscPosTcpConnection.sendTimeout) == .timedOut {
            disconnect()
            throw EscPosError.connection("Timed out while sending data to device.")
        }
        if let error = outcome.value {
            disconnect()
            throw EscPosError.connection(error.localizedDescription)
        }
    }

    private func receiveLoop(_ current: EscPosNetworkConnection) {
        current.receive { [weak self, weak current] isComplete, error in
            guard let self = self, let current = current else { return }
            if isComplete || error != nil {
                self.markClosed(current)
                return
            }
            self.receiveLoop(current)
        }
    }

    private func markClosed(_ closed: EscPosNetworkConnection) {
        lock.lock()
        if connection === closed {
            ready = false
        }
        lock.unlock()
    }
}
