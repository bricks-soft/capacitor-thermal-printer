import CoreBluetooth
import Foundation

protocol EscPosBluetoothLinkEvents: AnyObject {
    func linkDidConnect()
    func linkDidFailToConnect(_ error: Error?)
    func linkDidDisconnect(_ error: Error?)
    func linkDidDiscover(writeType: CBCharacteristicWriteType?, error: Error?)
    func linkDidWrite(_ error: Error?)
    func linkIsReadyToSend()
}

protocol EscPosBluetoothLink: AnyObject {
    var events: EscPosBluetoothLinkEvents? { get set }
    var isConnected: Bool { get }
    var canSendWriteWithoutResponse: Bool { get }
    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int
    func connect()
    func cancel()
    func discoverPrinterCharacteristic()
    func write(_ data: Data, type: CBCharacteristicWriteType)
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
        let semaphore = DispatchSemaphore(value: 0)
        var finished = false
        var error: Error?

        init(kind: OperationKind) {
            self.kind = kind
        }
    }

    private struct LinkFailure: Error {}

    let link: EscPosBluetoothLink
    private let queue: EscPosQueue
    private let timeouts: EscPosBluetoothTimeouts
    private let onConnected: (() -> Void)?
    private var linkUp = false
    private var writeType: CBCharacteristicWriteType?
    private var current: Operation?
    private var readiness: DispatchSemaphore?
    private var cancelPending = false
    private(set) var ignoredCallbacks = 0

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
            let alreadyLinked = queue.sync { () -> Bool in
                writeType = nil
                if link.isConnected && !cancelPending {
                    linkUp = true
                }
                return linkUp
            }
            if !alreadyLinked {
                let operation = queue.sync { () -> Operation in
                    let operation = begin(.connect)
                    link.connect()
                    return operation
                }
                try waitFor(operation, timeout: timeouts.connect)
            }
            let discovery = queue.sync { () -> Operation in
                let operation = begin(.discovery)
                link.discoverPrinterCharacteristic()
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
                    link.write(chunk, type: .withoutResponse)
                }
            } else {
                let operation = try queue.sync { () -> Operation in
                    guard linkUp else { throw EscPosError.connection("Bluetooth device disconnected.") }
                    let operation = begin(.write)
                    link.write(chunk, type: .withResponse)
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

    func linkDidConnect() {
        guard current?.kind == .connect else {
            ignoredCallbacks += 1
            return
        }
        linkUp = true
        complete(.connect, error: nil)
    }

    func linkDidFailToConnect(_ error: Error?) {
        complete(.connect, error: error ?? LinkFailure())
    }

    func linkDidDisconnect(_ error: Error?) {
        if cancelPending {
            cancelPending = false
            ignoredCallbacks += 1
            return
        }
        let wasUp = linkUp
        linkUp = false
        writeType = nil
        readiness?.signal()
        guard let operation = current else { return }
        if operation.kind == .connect && !wasUp {
            ignoredCallbacks += 1
            return
        }
        finish(operation, error: error ?? LinkFailure())
    }

    func linkDidDiscover(writeType discovered: CBCharacteristicWriteType?, error: Error?) {
        guard current?.kind == .discovery else {
            ignoredCallbacks += 1
            return
        }
        if error == nil, let discovered = discovered {
            writeType = discovered
            complete(.discovery, error: nil)
        } else {
            complete(.discovery, error: error ?? LinkFailure())
        }
    }

    func linkDidWrite(_ error: Error?) {
        complete(.write, error: error)
    }

    func linkIsReadyToSend() {
        readiness?.signal()
    }

    private func begin(_ kind: OperationKind) -> Operation {
        let operation = Operation(kind: kind)
        current = operation
        return operation
    }

    private func complete(_ kind: OperationKind, error: Error?) {
        guard let operation = current, operation.kind == kind, !operation.finished else {
            ignoredCallbacks += 1
            return
        }
        finish(operation, error: error)
    }

    private func finish(_ operation: Operation, error: Error?) {
        operation.finished = true
        operation.error = error
        if current === operation {
            current = nil
        }
        operation.semaphore.signal()
    }

    private func waitFor(_ operation: Operation, timeout: TimeInterval) throws {
        if operation.semaphore.wait(timeout: .now() + timeout) == .timedOut {
            let completedLate = queue.sync { () -> Bool in
                if operation.finished {
                    return true
                }
                operation.finished = true
                operation.error = EscPosError.connection("Timed out while waiting for the Bluetooth device.")
                if current === operation {
                    current = nil
                }
                return false
            }
            if !completedLate {
                throw operation.error ?? LinkFailure()
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
                cancelPending = true
            }
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
