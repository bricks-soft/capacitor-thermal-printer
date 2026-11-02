import CoreBluetooth
import Foundation
@testable import ThermalPrinter

struct FakeLinkError: Error {}

final class FakeBluetoothLink: EscPosBluetoothLink {
    enum ConnectBehavior {
        case succeed(after: TimeInterval)
        case fail
        case never
    }

    enum DiscoverBehavior {
        case found(CBCharacteristicWriteType)
        case none
        case never
        case late(TimeInterval, CBCharacteristicWriteType)
    }

    enum WriteResponse {
        case ack
        case error
        case never
        case late(TimeInterval)
    }

    weak var events: EscPosBluetoothLinkEvents?
    let queue: EscPosQueue
    var connectBehavior: ConnectBehavior = .succeed(after: 0.01)
    var discoverBehavior: DiscoverBehavior = .found(.withoutResponse)
    var writeResponses: [WriteResponse] = []
    var maxWriteLength = 20
    var readyDelay: TimeInterval?
    var sendsReadyEvent = true
    var disconnectAfterWrites: Int?
    var disconnectDelay: TimeInterval = 0
    var cancelDisconnectDelay: TimeInterval = 0.05
    var honorsDisconnectBoundary = true
    var cancelsPendingConnect = true

    private(set) var connected = false
    private var session: Int?
    private var closingSession: Int?
    private var pendingConnect: Int?
    private var disconnectDue: Date?
    private(set) var canSend = true
    private(set) var writes: [(Data, CBCharacteristicWriteType)] = []
    private(set) var connectCalls = 0
    private(set) var cancelCalls = 0
    private(set) var writesWhileBlocked = 0
    private(set) var droppedAfterDisconnect = 0

    init(queue: EscPosQueue) {
        self.queue = queue
    }

    var isConnected: Bool { connected }

    var canSendWriteWithoutResponse: Bool { canSend }

    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int {
        maxWriteLength
    }

    func connect(attempt: Int) {
        connectCalls += 1
        pendingConnect = attempt
        switch connectBehavior {
        case .succeed(let delay):
            let afterPendingDisconnect = disconnectDue.map { max(0, $0.timeIntervalSinceNow) + 0.01 } ?? 0
            queue.async(after: max(delay, afterPendingDisconnect)) {
                guard self.pendingConnect == attempt || !self.cancelsPendingConnect else { return }
                self.pendingConnect = nil
                self.connected = true
                self.session = attempt
                self.events?.linkDidConnect(attempt: attempt)
            }
        case .fail:
            queue.async {
                guard self.pendingConnect == attempt else { return }
                self.pendingConnect = nil
                self.events?.linkDidFailToConnect(attempt: attempt, error: FakeLinkError())
            }
        case .never:
            break
        }
    }

    func adopt(attempt: Int) {
        session = attempt
    }

    func cancel() {
        cancelCalls += 1
        if cancelsPendingConnect {
            pendingConnect = nil
        }
        guard connected, let ending = session else { return }
        connected = false
        closingSession = ending
        disconnectDue = Date().addingTimeInterval(cancelDisconnectDelay)
        queue.async(after: cancelDisconnectDelay) {
            self.disconnectDue = nil
            self.closingSession = nil
            if self.session == ending {
                self.session = nil
            }
            self.events?.linkDidDisconnect(attempt: ending, error: nil)
        }
    }

    func discoverPrinterCharacteristic(attempt: Int) {
        switch discoverBehavior {
        case .found(let type):
            deliver(attempt) { $0.linkDidDiscover(attempt: attempt, writeType: type, error: nil) }
        case .none:
            deliver(attempt) { $0.linkDidDiscover(attempt: attempt, writeType: nil, error: nil) }
        case .never:
            break
        case .late(let delay, let type):
            queue.async(after: delay) {
                self.deliverNow(attempt) { $0.linkDidDiscover(attempt: attempt, writeType: type, error: nil) }
            }
        }
    }

    func write(_ data: Data, type: CBCharacteristicWriteType, token: Int) {
        if type == .withoutResponse && !canSend {
            writesWhileBlocked += 1
        }
        writes.append((data, type))
        let writeSession = session ?? -1
        if let limit = disconnectAfterWrites, writes.count == limit {
            queue.async(after: disconnectDelay) {
                self.connected = false
                self.session = nil
                self.events?.linkDidDisconnect(attempt: writeSession, error: FakeLinkError())
            }
        }
        if type == .withoutResponse, let delay = readyDelay {
            canSend = false
            queue.async(after: delay) {
                self.canSend = true
                if self.sendsReadyEvent {
                    self.deliverNow(writeSession) { $0.linkIsReadyToSend(attempt: writeSession) }
                }
            }
        }
        if type == .withResponse {
            let response = writeResponses.isEmpty ? .ack : writeResponses.removeFirst()
            switch response {
            case .ack:
                deliver(writeSession) { $0.linkDidWrite(token: token, error: nil) }
            case .error:
                deliver(writeSession) { $0.linkDidWrite(token: token, error: FakeLinkError()) }
            case .never:
                break
            case .late(let delay):
                queue.async(after: delay) {
                    self.deliverNow(writeSession) { $0.linkDidWrite(token: token, error: nil) }
                }
            }
        }
    }

    private func deliver(_ owner: Int, _ event: @escaping (EscPosBluetoothLinkEvents) -> Void) {
        queue.async { self.deliverNow(owner, event) }
    }

    private func deliverNow(_ owner: Int, _ event: (EscPosBluetoothLinkEvents) -> Void) {
        let sessionOpen = session == owner || closingSession == owner
        guard sessionOpen || !honorsDisconnectBoundary else {
            droppedAfterDisconnect += 1
            return
        }
        if let events = events {
            event(events)
        }
    }

    func snapshot() -> (writes: [(Data, CBCharacteristicWriteType)], connectCalls: Int, cancelCalls: Int, writesWhileBlocked: Int, dropped: Int) {
        queue.sync { (writes, connectCalls, cancelCalls, writesWhileBlocked, droppedAfterDisconnect) }
    }

    func writtenBytes(from index: Int = 0) -> [UInt8] {
        queue.sync { writes.dropFirst(index).flatMap { [UInt8]($0.0) } }
    }

    func configure(_ change: (FakeBluetoothLink) -> Void) {
        queue.sync { change(self) }
    }
}

final class FakePeripheral: EscPosDiscoveredPeripheral {
    let identifier: UUID
    let name: String?

    init(identifier: UUID = UUID(), name: String?) {
        self.identifier = identifier
        self.name = name
    }
}

final class FakeCentralManager: EscPosCentralManaging {
    private let currentState: LockedValue<CBManagerState>
    private let scanCount = LockedValue(0)
    weak var central: EscPosBluetoothCentral?
    var advertisements: [(FakePeripheral, [String: Any])] = []

    init(state: CBManagerState) {
        currentState = LockedValue(state)
    }

    var state: CBManagerState {
        get { currentState.value }
        set { currentState.value = newValue }
    }

    var scans: Int { scanCount.value }

    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?) {
        scanCount.value += 1
        guard let central = central else { return }
        for (index, (peripheral, data)) in advertisements.enumerated() {
            central.queue.async(after: 0.01 * Double(index + 1)) {
                central.record(peripheral, advertisementData: data)
            }
        }
    }

    func stopScan() {}

    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [CBPeripheral] { [] }

    func retrieveConnectedPeripherals(withServices serviceUUIDs: [CBUUID]) -> [CBPeripheral] { [] }

    func connect(_ peripheral: CBPeripheral, options: [String: Any]?) {}

    func cancelPeripheralConnection(_ peripheral: CBPeripheral) {}
}

final class LockedValue<Value> {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
