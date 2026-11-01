import Foundation
import Network

final class EscPosTcpConnection: EscPosDeviceConnection {
    static var connectTimeout: TimeInterval = 5
    static var sendTimeout: TimeInterval = 30

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
        tcp.connectionTimeout = max(1, Int(EscPosTcpConnection.connectTimeout.rounded(.up)))
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        let candidate = NWConnection(host: NWEndpoint.Host(address), port: endpointPort, using: parameters)
        let settled = DispatchSemaphore(value: 0)
        var didSettle = false

        candidate.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.lock.lock()
                self.ready = true
                self.lock.unlock()
                if !didSettle {
                    didSettle = true
                    settled.signal()
                }
            case .failed, .cancelled, .waiting:
                self.markClosed(candidate)
                if !didSettle {
                    didSettle = true
                    settled.signal()
                }
            default:
                break
            }
        }

        lock.lock()
        connection = candidate
        ready = false
        lock.unlock()

        candidate.start(queue: queue)

        let result = settled.wait(timeout: .now() + EscPosTcpConnection.connectTimeout)
        if result == .timedOut || !isConnected {
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
