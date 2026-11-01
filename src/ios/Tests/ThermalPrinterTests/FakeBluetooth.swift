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
    var cancelDisconnectDelay: TimeInterval = 0.05

    private(set) var connected = false
    private var disconnectDue: Date?
    private(set) var canSend = true
    private(set) var writes: [(Data, CBCharacteristicWriteType)] = []
    private(set) var connectCalls = 0
    private(set) var cancelCalls = 0
    private(set) var writesWhileBlocked = 0

    init(queue: EscPosQueue) {
        self.queue = queue
    }

    var isConnected: Bool { connected }

    var canSendWriteWithoutResponse: Bool { canSend }

    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int {
        maxWriteLength
    }

    func connect() {
        connectCalls += 1
        switch connectBehavior {
        case .succeed(let delay):
            let afterPendingDisconnect = disconnectDue.map { max(0, $0.timeIntervalSinceNow) + 0.01 } ?? 0
            queue.async(after: max(delay, afterPendingDisconnect)) {
                self.connected = true
                self.events?.linkDidConnect()
            }
        case .fail:
            queue.async { self.events?.linkDidFailToConnect(FakeLinkError()) }
        case .never:
            break
        }
    }

    func cancel() {
        cancelCalls += 1
        guard connected else { return }
        connected = false
        disconnectDue = Date().addingTimeInterval(cancelDisconnectDelay)
        queue.async(after: cancelDisconnectDelay) {
            self.disconnectDue = nil
            self.events?.linkDidDisconnect(nil)
        }
    }

    func discoverPrinterCharacteristic() {
        switch discoverBehavior {
        case .found(let type):
            queue.async { self.events?.linkDidDiscover(writeType: type, error: nil) }
        case .none:
            queue.async { self.events?.linkDidDiscover(writeType: nil, error: nil) }
        case .never:
            break
        }
    }

    func write(_ data: Data, type: CBCharacteristicWriteType) {
        if type == .withoutResponse && !canSend {
            writesWhileBlocked += 1
        }
        writes.append((data, type))
        if let limit = disconnectAfterWrites, writes.count == limit {
            queue.async {
                self.connected = false
                self.events?.linkDidDisconnect(FakeLinkError())
            }
        }
        if type == .withoutResponse, let delay = readyDelay {
            canSend = false
            queue.async(after: delay) {
                self.canSend = true
                if self.sendsReadyEvent {
                    self.events?.linkIsReadyToSend()
                }
            }
        }
        if type == .withResponse {
            let response = writeResponses.isEmpty ? .ack : writeResponses.removeFirst()
            switch response {
            case .ack:
                queue.async { self.events?.linkDidWrite(nil) }
            case .error:
                queue.async { self.events?.linkDidWrite(FakeLinkError()) }
            case .never:
                break
            case .late(let delay):
                queue.async(after: delay) { self.events?.linkDidWrite(nil) }
            }
        }
    }

    func snapshot() -> (writes: [(Data, CBCharacteristicWriteType)], connectCalls: Int, cancelCalls: Int, writesWhileBlocked: Int) {
        queue.sync { (writes, connectCalls, cancelCalls, writesWhileBlocked) }
    }

    func writtenBytes(from index: Int = 0) -> [UInt8] {
        queue.sync { writes.dropFirst(index).flatMap { [UInt8]($0.0) } }
    }

    func configure(_ change: (FakeBluetoothLink) -> Void) {
        queue.sync { change(self) }
    }
}

final class FakeCentralManager: EscPosCentralManaging {
    private let currentState: LockedValue<CBManagerState>
    private(set) var scans = 0

    init(state: CBManagerState) {
        currentState = LockedValue(state)
    }

    var state: CBManagerState {
        get { currentState.value }
        set { currentState.value = newValue }
    }

    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?) {
        scans += 1
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
