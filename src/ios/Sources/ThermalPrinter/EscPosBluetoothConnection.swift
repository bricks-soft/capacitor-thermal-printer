import CoreBluetooth
import Foundation

protocol EscPosBluetoothLinkEvents: AnyObject {
    func linkDidConnect(attempt: Int)
    func linkDidFailToConnect(attempt: Int, error: Error?)
    func linkDidDisconnect(attempt: Int, error: Error?)
    func linkDidDiscover(attempt: Int, writeType: CBCharacteristicWriteType?, error: Error?)
    func linkDidWrite(token: Int, error: Error?)
    func linkIsReadyToSend(attempt: Int)
}

protocol EscPosBluetoothLink: AnyObject {
    var events: EscPosBluetoothLinkEvents? { get set }
    var isConnected: Bool { get }
    var canSendWriteWithoutResponse: Bool { get }
    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int
    func connect(attempt: Int)
    func adopt(attempt: Int)
    func cancel()
    func discoverPrinterCharacteristic(attempt: Int)
    func write(_ data: Data, type: CBCharacteristicWriteType, token: Int)
}

struct EscPosBluetoothTimeouts {
    var connect: TimeInterval = 10
    var discovery: TimeInterval = 10
    var write: TimeInterval = 10
    var readinessPoll: TimeInterval = 0.05
}

final class EscPosBluetoothConnection: EscPosDeviceConnection, EscPosBluetoothLinkEvents {
    private enum OperationKind {
        case connect
        case discovery
        case write
    }

    private final class Operation {
        let kind: OperationKind
        let token: Int
        let semaphore = DispatchSemaphore(value: 0)
        var finished = false
        var error: Error?

        init(kind: OperationKind, token: Int) {
            self.kind = kind
            self.token = token
        }
    }

    private struct LinkFailure: Error {}

    let link: EscPosBluetoothLink
    private let queue: EscPosQueue
    private let timeouts: EscPosBluetoothTimeouts
    private let onConnected: (() -> Void)?
    private var attempt = 0
    private var lastToken = 0
    private var linkUp = false
    private var tearingDown = false
    private var writeType: CBCharacteristicWriteType?
    private var current: Operation?
    private var readiness: DispatchSemaphore?
    private var ignoredCallbacks = 0

    init(link: EscPosBluetoothLink, queue: EscPosQueue, timeouts: EscPosBluetoothTimeouts = EscPosBluetoothTimeouts(), onConnected: (() -> Void)? = nil) {
        self.link = link
        self.queue = queue
        self.timeouts = timeouts
        self.onConnected = onConnected
        super.init()
        queue.sync { link.events = self }
    }

    override var isConnected: Bool {
        queue.sync { linkUp && link.isConnected && writeType != nil }
    }

    var ignoredCallbackCount: Int {
        queue.sync { ignoredCallbacks }
    }

    @discardableResult
    override func connect() throws -> EscPosDeviceConnection {
        if isConnected {
            return self
        }
        do {
            let connecting = queue.sync { () -> Operation? in
                attempt = nextToken()
                writeType = nil
                if link.isConnected && !tearingDown {
                    linkUp = true
                    link.adopt(attempt: attempt)
                    return nil
                }
                linkUp = false
                let operation = begin(.connect, token: attempt)
                link.connect(attempt: attempt)
                return operation
            }
            if let operation = connecting {
                try waitFor(operation, timeout: timeouts.connect)
            }
            let discovery = queue.sync { () -> Operation in
                let operation = begin(.discovery, token: attempt)
                link.discoverPrinterCharacteristic(attempt: attempt)
                return operation
            }
            try waitFor(discovery, timeout: timeouts.discovery)
            guard isConnected else {
                throw LinkFailure()
            }
        } catch {
            invalidate()
            throw EscPosError.connection("Unable to connect to bluetooth device.")
        }
        onConnected?()
        clearBuffer()
        return self
    }

    @discardableResult
    override func disconnect() -> EscPosDeviceConnection {
        invalidate()
        return super.disconnect()
    }

    override func transmit(_ bytes: [UInt8]) throws {
        let target: (CBCharacteristicWriteType, Int)? = queue.sync {
            guard linkUp, link.isConnected, let type = writeType else { return nil }
            return (type, max(20, link.maximumWriteValueLength(for: type)))
        }
        guard let (type, chunkSize) = target else {
            throw EscPosError.connection("Unable to send data to device.")
        }
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            let chunk = Data(bytes[offset..<end])
            if type == .withoutResponse {
                try waitUntilReadyToWrite()
                try queue.sync {
                    guard linkUp else { throw EscPosError.connection("Bluetooth device disconnected.") }
                    link.write(chunk, type: .withoutResponse, token: nextToken())
                }
            } else {
                let operation = try queue.sync { () -> Operation in
                    guard linkUp else { throw EscPosError.connection("Bluetooth device disconnected.") }
                    let operation = begin(.write, token: nextToken())
                    link.write(chunk, type: .withResponse, token: operation.token)
                    return operation
                }
                do {
                    try waitFor(operation, timeout: timeouts.write)
                } catch let failure as EscPosError {
                    throw failure
                } catch {
                    throw EscPosError.connection(error.localizedDescription)
                }
            }
            offset = end
        }
        if !queue.sync({ linkUp }) {
            throw EscPosError.connection("Bluetooth device disconnected.")
        }
    }

    func linkDidConnect(attempt connected: Int) {
        guard connected == attempt, let operation = current, operation.kind == .connect, operation.token == connected else {
            ignoredCallbacks += 1
            return
        }
        linkUp = true
        finish(operation, error: nil)
    }

    func linkDidFailToConnect(attempt failed: Int, error: Error?) {
        guard failed == attempt, let operation = current, operation.kind == .connect, operation.token == failed else {
            ignoredCallbacks += 1
            return
        }
        finish(operation, error: error ?? LinkFailure())
    }

    func linkDidDisconnect(attempt ended: Int, error: Error?) {
        guard ended == attempt else {
            tearingDown = false
            ignoredCallbacks += 1
            return
        }
        linkUp = false
        writeType = nil
        readiness?.signal()
        if let operation = current {
            finish(operation, error: error ?? LinkFailure())
        }
    }

    func linkDidDiscover(attempt discovered: Int, writeType found: CBCharacteristicWriteType?, error: Error?) {
        guard discovered == attempt, let operation = current, operation.kind == .discovery, operation.token == discovered else {
            ignoredCallbacks += 1
            return
        }
        if error == nil, let found = found {
            writeType = found
            finish(operation, error: nil)
        } else {
            finish(operation, error: error ?? LinkFailure())
        }
    }

    func linkDidWrite(token: Int, error: Error?) {
        guard let operation = current, operation.kind == .write, operation.token == token else {
            ignoredCallbacks += 1
            return
        }
        finish(operation, error: error)
    }

    func linkIsReadyToSend(attempt ready: Int) {
        guard ready == attempt else {
            ignoredCallbacks += 1
            return
        }
        readiness?.signal()
    }

    private func nextToken() -> Int {
        lastToken += 1
        return lastToken
    }

    private func begin(_ kind: OperationKind, token: Int) -> Operation {
        let operation = Operation(kind: kind, token: token)
        current = operation
        return operation
    }

    private func finish(_ operation: Operation, error: Error?) {
        guard !operation.finished else { return }
        operation.finished = true
        operation.error = error
        if current === operation {
            current = nil
        }
        operation.semaphore.signal()
    }

    private func waitFor(_ operation: Operation, timeout: TimeInterval) throws {
        if operation.semaphore.wait(timeout: .now() + timeout) == .timedOut {
            queue.sync {
                finish(operation, error: EscPosError.connection("Timed out while waiting for the Bluetooth device."))
            }
        }
        if let error = queue.sync({ operation.error }) {
            throw error
        }
    }

    private func waitUntilReadyToWrite() throws {
        let deadline = Date().addingTimeInterval(timeouts.write)
        while true {
            let (ready, connected, semaphore) = queue.sync { () -> (Bool, Bool, DispatchSemaphore) in
                let semaphore = DispatchSemaphore(value: 0)
                readiness = semaphore
                return (link.canSendWriteWithoutResponse, linkUp, semaphore)
            }
            if !connected {
                throw EscPosError.connection("Bluetooth device disconnected.")
            }
            if ready {
                return
            }
            if Date() >= deadline {
                throw EscPosError.connection("Timed out while sending data to device.")
            }
            _ = semaphore.wait(timeout: .now() + timeouts.readinessPoll)
        }
    }

    private func invalidate() {
        queue.sync {
            if link.isConnected {
                tearingDown = true
            }
            attempt = nextToken()
            linkUp = false
            writeType = nil
            if let operation = current {
                finish(operation, error: LinkFailure())
            }
            readiness?.signal()
            link.cancel()
        }
    }
}
