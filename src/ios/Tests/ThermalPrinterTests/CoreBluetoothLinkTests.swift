import CoreBluetooth
import Foundation
@testable import ThermalPrinter
import XCTest

final class StubPeripheralDriver: EscPosPeripheralDriver {
    var isAvailable = true
    var isConnected = false
    var canSendWriteWithoutResponse = true
    var services: [CBService] = []
    var maxWriteLength = 182
    private(set) var connectCalls = 0
    private(set) var cancelCalls = 0
    private(set) var serviceDiscoveries = 0
    private(set) var characteristicDiscoveries = 0
    private(set) var writes: [(Data, CBCharacteristicWriteType)] = []
    var onConnect: (() -> Void)?
    var onCancel: (() -> Void)?
    var onDiscoverServices: (() -> Void)?
    var onDiscoverCharacteristics: (() -> Void)?
    var onWrite: ((CBCharacteristicWriteType) -> Void)?

    func attach(_ delegate: CBPeripheralDelegate) {}

    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { maxWriteLength }

    func connect() {
        connectCalls += 1
        onConnect?()
    }

    func cancelConnection() {
        cancelCalls += 1
        onCancel?()
    }

    func discoverServices() {
        serviceDiscoveries += 1
        onDiscoverServices?()
    }

    func discoverCharacteristics(for service: CBService) {
        characteristicDiscoveries += 1
        onDiscoverCharacteristics?()
    }

    func write(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        writes.append((data, type))
        onWrite?(type)
    }

    static func printerServices(_ properties: CBCharacteristicProperties = [.writeWithoutResponse, .write]) -> [CBService] {
        let service = CBMutableService(type: CBUUID(string: "18F0"), primary: true)
        service.characteristics = [CBMutableCharacteristic(type: CBUUID(string: "2AF1"), properties: properties, value: nil, permissions: [.writeable])]
        return [service]
    }
}

final class RecordingLinkEvents: EscPosBluetoothLinkEvents {
    private(set) var log: [String] = []

    func linkDidConnect(attempt: Int) { log.append("connected \(attempt)") }
    func linkDidFailToConnect(attempt: Int, error: Error?) { log.append("failed \(attempt)") }
    func linkDidDisconnect(attempt: Int, error: Error?) { log.append("disconnected \(attempt)") }
    func linkDidDiscover(attempt: Int, writeType: CBCharacteristicWriteType?, error: Error?) {
        log.append("discovered \(attempt) \(writeType.map { $0 == .withResponse ? "withResponse" : "withoutResponse" } ?? "none")")
    }
    func linkDidWrite(token: Int, error: Error?) { log.append("wrote \(token)\(error == nil ? "" : " error")") }
    func linkIsReadyToSend(attempt: Int) { log.append("ready \(attempt)") }
}

final class CoreBluetoothLinkTests: XCTestCase {
    private var queue: EscPosQueue!
    private var driver: StubPeripheralDriver!
    private var link: EscPosCoreBluetoothLink!
    private var events: RecordingLinkEvents!

    override func setUp() {
        queue = EscPosQueue(label: "test.core-bluetooth-link")
        driver = StubPeripheralDriver()
        link = EscPosCoreBluetoothLink(driver: driver)
        events = RecordingLinkEvents()
        link.events = events
    }

    private func onQueue(_ block: () -> Void) {
        queue.sync(block)
    }

    func testCancelledPendingConnectionDefersTheNextConnectUntilItsDisconnect() {
        onQueue {
            link.connect(attempt: 1)
            link.cancel()
            link.connect(attempt: 2)
            XCTAssertEqual(driver.connectCalls, 1, "the second connect waits for the cancellation")
            XCTAssertTrue(link.isCancelling)

            link.handleConnected()
            link.handleDisconnected(nil)
            XCTAssertEqual(events.log, ["disconnected 1"], "the old completion is not attributed to attempt 2")
            XCTAssertEqual(driver.connectCalls, 2)

            driver.isConnected = true
            link.handleConnected()
            XCTAssertEqual(events.log, ["disconnected 1", "connected 2"])
        }
    }

    func testFailedConnectionEndsTheCancellationOfAPendingConnect() {
        onQueue {
            link.connect(attempt: 1)
            link.cancel()
            link.connect(attempt: 2)
            XCTAssertEqual(driver.connectCalls, 1, "the second connect waits for the cancellation")
            link.handleFailedToConnect(nil)
            XCTAssertEqual(events.log, ["failed 1"])
            XCTAssertEqual(driver.connectCalls, 2)
            link.handleConnected()
            XCTAssertEqual(events.log, ["failed 1", "connected 2"])
        }
    }

    func testCancelledSessionDropsItsCallbacksAndDefersTheReconnect() {
        onQueue {
            driver.services = StubPeripheralDriver.printerServices()
            link.connect(attempt: 1)
            driver.isConnected = true
            link.handleConnected()
            link.discoverPrinterCharacteristic(attempt: 1)
            link.handleServicesDiscovered(error: nil)
            link.handleCharacteristicsDiscovered()
            link.write(Data([1, 2, 3]), type: .withResponse, token: 7)

            link.cancel()
            XCTAssertFalse(link.isConnected, "a link being cancelled is not offered for adoption")
            link.connect(attempt: 2)
            link.handleWriteResponse(error: nil)
            link.handleReadyToSend()
            XCTAssertEqual(driver.connectCalls, 1)

            driver.isConnected = false
            link.handleDisconnected(nil)
            XCTAssertEqual(driver.connectCalls, 2)
            driver.isConnected = true
            link.handleConnected()
            XCTAssertEqual(events.log, ["connected 1", "discovered 1 withoutResponse", "disconnected 1", "connected 2"])
        }
    }

    func testAdoptDuringCancellationWaitsAndReconnects() {
        onQueue {
            link.connect(attempt: 1)
            driver.isConnected = true
            link.handleConnected()
            link.cancel()
            link.adopt(attempt: 2)
            XCTAssertEqual(driver.connectCalls, 1)
            link.handleDisconnected(nil)
            XCTAssertEqual(driver.connectCalls, 2)
            link.handleConnected()
            XCTAssertEqual(events.log, ["connected 1", "disconnected 1", "connected 2"])
        }
    }

    func testLateCallbacksOfACancelledPendingConnectionStayWithIt() {
        onQueue {
            link.connect(attempt: 1)
            link.cancel()
            link.connect(attempt: 2)
        }
        Thread.sleep(forTimeInterval: 2.5)
        onQueue {
            XCTAssertEqual(driver.connectCalls, 1, "time alone does not end the cancellation")
            XCTAssertEqual(events.log, [])
            link.handleConnected()
            XCTAssertEqual(events.log, [], "the old connection's didConnect is not attempt 2's")
            link.handleDisconnected(nil)
            XCTAssertEqual(events.log, ["disconnected 1"])
            XCTAssertEqual(driver.connectCalls, 2)
            driver.isConnected = true
            link.handleConnected()
            XCTAssertEqual(events.log, ["disconnected 1", "connected 2"])
        }
    }

    func testLateCallbacksOfACancelledSessionStayWithIt() {
        onQueue {
            driver.services = StubPeripheralDriver.printerServices([.write])
            link.connect(attempt: 1)
            driver.isConnected = true
            link.handleConnected()
            link.discoverPrinterCharacteristic(attempt: 1)
            link.handleServicesDiscovered(error: nil)
            link.handleCharacteristicsDiscovered()
            link.write(Data([1]), type: .withResponse, token: 7)
            link.cancel()
            link.connect(attempt: 2)
        }
        Thread.sleep(forTimeInterval: 2.5)
        onQueue {
            XCTAssertEqual(driver.connectCalls, 1, "time alone does not end the cancellation")
            link.handleWriteResponse(error: nil)
            link.handleReadyToSend()
            link.handleConnected()
            XCTAssertEqual(events.log, ["connected 1", "discovered 1 withResponse"])
            driver.isConnected = false
            link.handleDisconnected(nil)
            XCTAssertEqual(driver.connectCalls, 2)
            driver.isConnected = true
            link.handleConnected()
            link.discoverPrinterCharacteristic(attempt: 2)
            link.handleServicesDiscovered(error: nil)
            link.handleCharacteristicsDiscovered()
            link.write(Data([2]), type: .withResponse, token: 8)
            link.handleWriteResponse(error: nil)
            XCTAssertEqual(events.log, ["connected 1", "discovered 1 withResponse", "disconnected 1", "connected 2", "discovered 2 withResponse", "wrote 8"])
        }
    }

    func testQueuedConnectTimesOutWhileTheCancellationIsUnfinishedAndTheNextOneSucceeds() throws {
        let central = queue!
        driver.services = StubPeripheralDriver.printerServices()
        var answersConnect = false
        driver.onConnect = { [unowned self] in
            guard answersConnect else { return }
            central.async(after: 0.05) {
                self.driver.isConnected = true
                self.link.handleConnected()
            }
        }
        driver.onDiscoverServices = { [unowned self] in central.async { self.link.handleServicesDiscovered(error: nil) } }
        driver.onDiscoverCharacteristics = { [unowned self] in central.async { self.link.handleCharacteristicsDiscovered() } }
        link.events = nil
        let connection = EscPosBluetoothConnection(link: link, queue: queue, timeouts: EscPosBluetoothTimeouts(connect: 0.3, discovery: 1, write: 1))
        connection.pacesSends = false

        XCTAssertThrowsError(try connection.connect())
        XCTAssertTrue(queue.sync { link.isCancelling })
        XCTAssertThrowsError(try connection.connect(), "a connect queued behind the cancellation fails at its own timeout")
        XCTAssertEqual(queue.sync { driver.connectCalls }, 1)
        queue.sync { link.handleConnected() }
        XCTAssertFalse(connection.isConnected, "the old connection's didConnect is not adopted")

        queue.sync { link.handleDisconnected(nil) }
        XCTAssertFalse(queue.sync { link.isCancelling })
        XCTAssertEqual(queue.sync { driver.connectCalls }, 1, "the timed-out connect was not left queued")
        answersConnect = true
        try connection.connect()
        XCTAssertTrue(connection.isConnected)
        XCTAssertEqual(queue.sync { driver.connectCalls }, 2)
        connection.write([0x1B, 0x40])
        try connection.send()
        XCTAssertEqual(queue.sync { driver.writes.map(\.0) }, [Data([0x1B, 0x40])])
    }

    func testBluetoothOffDuringACancellationFailsTheQueuedConnectWithoutStartingIt() {
        onQueue {
            link.connect(attempt: 1)
            link.cancel()
            link.connect(attempt: 2)
            driver.isAvailable = false
            link.handleUnavailable()
            XCTAssertEqual(events.log, ["disconnected 1", "failed 2"])
            XCTAssertEqual(driver.connectCalls, 1, "nothing starts while Bluetooth is off")
            XCTAssertFalse(link.isCancelling)

            link.connect(attempt: 3)
            XCTAssertEqual(events.log, ["disconnected 1", "failed 2", "failed 3"])
            link.cancel()
            link.handleUnavailable()
            XCTAssertFalse(link.isCancelling, "a connect refused while off leaves nothing to cancel")
            XCTAssertEqual(driver.connectCalls, 1)
            XCTAssertEqual(events.log, ["disconnected 1", "failed 2", "failed 3"], "repeated off updates report nothing new")

            driver.isAvailable = true
            link.handleConnected()
            link.handleDisconnected(nil)
            link.handleFailedToConnect(nil)
            link.handleWriteResponse(error: nil)
            link.handleReadyToSend()
            XCTAssertEqual(events.log, ["disconnected 1", "failed 2", "failed 3"], "late callbacks after power-on are ignored")

            link.connect(attempt: 4)
            XCTAssertEqual(driver.connectCalls, 2)
            link.handleDisconnected(nil)
            driver.isConnected = true
            link.handleConnected()
            XCTAssertEqual(events.log, ["disconnected 1", "failed 2", "failed 3", "connected 4"])
        }
    }

    func testBluetoothOffFailsAPendingConnect() {
        onQueue {
            link.connect(attempt: 1)
            driver.isAvailable = false
            link.handleUnavailable()
            XCTAssertEqual(events.log, ["failed 1"])
            link.cancel()
            XCTAssertFalse(link.isCancelling)
            driver.isAvailable = true
            link.connect(attempt: 2)
            XCTAssertEqual(driver.connectCalls, 2)
            driver.isConnected = true
            link.handleConnected()
            XCTAssertEqual(events.log, ["failed 1", "connected 2"])
        }
    }

    func testBluetoothOffEndsALiveSession() {
        onQueue {
            driver.services = StubPeripheralDriver.printerServices([.write])
            link.connect(attempt: 1)
            driver.isConnected = true
            link.handleConnected()
            link.discoverPrinterCharacteristic(attempt: 1)
            link.handleServicesDiscovered(error: nil)
            link.handleCharacteristicsDiscovered()
            link.write(Data([1]), type: .withResponse, token: 7)
            driver.isConnected = false
            driver.isAvailable = false
            link.handleUnavailable()
            link.handleWriteResponse(error: nil)
            XCTAssertEqual(events.log, ["connected 1", "discovered 1 withResponse", "disconnected 1"])
            XCTAssertFalse(link.isCancelling)
        }
    }

    func testConnectQueuedBehindACancellationFailsWhenBluetoothTurnsOffAndAFreshConnectWorksAfterPowerOn() throws {
        let central = queue!
        driver.services = StubPeripheralDriver.printerServices()
        var answersConnect = false
        driver.onConnect = { [unowned self] in
            guard answersConnect else { return }
            central.async(after: 0.05) {
                self.driver.isConnected = true
                self.link.handleConnected()
            }
        }
        driver.onDiscoverServices = { [unowned self] in central.async { self.link.handleServicesDiscovered(error: nil) } }
        driver.onDiscoverCharacteristics = { [unowned self] in central.async { self.link.handleCharacteristicsDiscovered() } }
        let connection = EscPosBluetoothConnection(link: link, queue: queue, timeouts: EscPosBluetoothTimeouts(connect: 5, discovery: 1, write: 1))
        connection.pacesSends = false
        queue.sync {
            link.connect(attempt: 100)
            link.cancel()
        }

        central.async(after: 0.2) {
            self.driver.isAvailable = false
            self.link.handleUnavailable()
        }
        let started = Date()
        XCTAssertThrowsError(try connection.connect())
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "Bluetooth turning off fails the queued connect at once")
        XCTAssertFalse(queue.sync { link.isCancelling })
        XCTAssertThrowsError(try connection.connect(), "connecting while off fails")
        XCTAssertEqual(queue.sync { driver.connectCalls }, 1)

        queue.sync {
            driver.isAvailable = true
            answersConnect = true
        }
        try connection.connect()
        XCTAssertTrue(connection.isConnected, "no terminal callback is needed after power-on")
        XCTAssertEqual(queue.sync { driver.connectCalls }, 2)
        connection.write([0x1B, 0x40])
        try connection.send()
        XCTAssertEqual(queue.sync { driver.writes.map(\.0) }, [Data([0x1B, 0x40])])
    }

    func testWriteAcknowledgementsKeepTheirOrderWithinASession() {
        onQueue {
            driver.services = StubPeripheralDriver.printerServices([.write])
            link.connect(attempt: 1)
            driver.isConnected = true
            link.handleConnected()
            link.discoverPrinterCharacteristic(attempt: 1)
            link.handleServicesDiscovered(error: nil)
            link.handleCharacteristicsDiscovered()
            link.write(Data([1]), type: .withResponse, token: 10)
            link.write(Data([2]), type: .withResponse, token: 11)
            link.handleWriteResponse(error: nil)
            link.handleWriteResponse(error: nil)
            link.handleWriteResponse(error: nil)
            XCTAssertEqual(events.log, ["connected 1", "discovered 1 withResponse", "wrote 10", "wrote 11"])
        }
    }

    func testConnectionReconnectsThroughTheAdapterAfterACancelledAttempt() throws {
        let central = queue!
        driver.services = StubPeripheralDriver.printerServices()
        var connectNumber = 0
        driver.onConnect = { [unowned self] in
            connectNumber += 1
            let delay = connectNumber == 1 ? 0.4 : 0.05
            central.async(after: delay) {
                self.driver.isConnected = true
                self.link.handleConnected()
            }
        }
        driver.onCancel = { [unowned self] in
            central.async(after: 0.2) {
                self.driver.isConnected = false
                self.link.handleDisconnected(nil)
            }
        }
        driver.onDiscoverServices = { [unowned self] in central.async { self.link.handleServicesDiscovered(error: nil) } }
        driver.onDiscoverCharacteristics = { [unowned self] in central.async { self.link.handleCharacteristicsDiscovered() } }
        link.events = nil
        let connection = EscPosBluetoothConnection(link: link, queue: queue, timeouts: EscPosBluetoothTimeouts(connect: 0.3, discovery: 1, write: 1))
        connection.pacesSends = false

        XCTAssertThrowsError(try connection.connect())
        let started = Date()
        try connection.connect()
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.15, "the reconnect starts after the cancelled attempt's disconnect")
        XCTAssertTrue(connection.isConnected)
        XCTAssertEqual(queue.sync { driver.connectCalls }, 2)
        connection.write([0x1B, 0x40])
        try connection.send()
        XCTAssertEqual(queue.sync { driver.writes.map(\.0) }, [Data([0x1B, 0x40])])
    }
}
