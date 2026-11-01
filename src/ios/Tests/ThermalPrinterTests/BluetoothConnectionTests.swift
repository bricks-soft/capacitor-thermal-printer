import CoreBluetooth
import Foundation
@testable import ThermalPrinter
import XCTest

final class BluetoothConnectionTests: XCTestCase {
    private var queue: EscPosQueue!
    private var link: FakeBluetoothLink!
    private var connected = 0

    override func setUp() {
        queue = EscPosQueue(label: "test.bluetooth")
        link = FakeBluetoothLink(queue: queue)
        connected = 0
    }

    private func makeConnection(_ timeouts: EscPosBluetoothTimeouts = EscPosBluetoothTimeouts(connect: 1, discovery: 1, write: 1)) -> EscPosBluetoothConnection {
        let connection = EscPosBluetoothConnection(link: link, queue: queue, timeouts: timeouts) { [weak self] in
            self?.connected += 1
        }
        connection.pacesSends = false
        return connection
    }

    private func payload(_ count: Int, seed: UInt8 = 1) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) }
    }

    private func send(_ bytes: [UInt8], over connection: EscPosBluetoothConnection) throws {
        connection.write(bytes)
        try connection.send()
    }

    func testChunksWritesByMaximumWriteValueLength() throws {
        let connection = makeConnection()
        try connection.connect()
        let bytes = payload(45)
        try send(bytes, over: connection)
        let state = link.snapshot()
        XCTAssertEqual(state.writes.map(\.0.count), [20, 20, 5])
        XCTAssertTrue(state.writes.allSatisfy { $0.1 == .withoutResponse })
        XCTAssertEqual(link.writtenBytes(), bytes)
        XCTAssertEqual(connected, 1)
    }

    func testUsesTheNegotiatedWriteLength() throws {
        link.configure { $0.maxWriteLength = 182 }
        let connection = makeConnection()
        try connection.connect()
        try send(payload(400), over: connection)
        XCTAssertEqual(link.snapshot().writes.map(\.0.count), [182, 182, 36])
    }

    func testWaitsForFlowControlBeforeEachWriteWithoutResponse() throws {
        link.configure { $0.readyDelay = 0.02 }
        let connection = makeConnection()
        try connection.connect()
        let started = Date()
        try send(payload(100), over: connection)
        let state = link.snapshot()
        XCTAssertEqual(state.writes.count, 5)
        XCTAssertEqual(state.writesWhileBlocked, 0)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.08)
    }

    func testKeepsWritingWhenTheReadinessCallbackNeverArrives() throws {
        link.configure {
            $0.readyDelay = 0.02
            $0.sendsReadyEvent = false
        }
        let connection = makeConnection()
        try connection.connect()
        try send(payload(60), over: connection)
        let state = link.snapshot()
        XCTAssertEqual(state.writes.count, 3)
        XCTAssertEqual(state.writesWhileBlocked, 0)
    }

    func testStalledFlowControlTimesOutClearsTheJobAndInvalidatesTheLink() throws {
        link.configure { $0.readyDelay = 60 }
        let connection = makeConnection(EscPosBluetoothTimeouts(connect: 1, discovery: 1, write: 0.3))
        try connection.connect()
        XCTAssertThrowsError(try send(payload(45), over: connection)) { error in
            XCTAssertEqual((error as? EscPosError)?.message, "Timed out while sending data to device.")
        }
        XCTAssertTrue(connection.data.isEmpty)
        XCTAssertFalse(connection.isConnected)
        XCTAssertEqual(link.snapshot().cancelCalls, 1)
        XCTAssertEqual(link.snapshot().writes.count, 1)
    }

    func testWritesWithResponseWaitForEachAcknowledgement() throws {
        link.configure { $0.discoverBehavior = .found(.withResponse) }
        let connection = makeConnection()
        try connection.connect()
        let bytes = payload(45)
        try send(bytes, over: connection)
        let state = link.snapshot()
        XCTAssertEqual(state.writes.map(\.0.count), [20, 20, 5])
        XCTAssertTrue(state.writes.allSatisfy { $0.1 == .withResponse })
        XCTAssertEqual(link.writtenBytes(), bytes)
    }

    func testWriteErrorClearsTheJobAndTheRetrySendsOnlyItsOwnBytes() throws {
        link.configure {
            $0.discoverBehavior = .found(.withResponse)
            $0.writeResponses = [.ack, .error]
        }
        let connection = makeConnection()
        try connection.connect()
        XCTAssertThrowsError(try send(payload(45, seed: 1), over: connection))
        XCTAssertTrue(connection.data.isEmpty)
        XCTAssertFalse(connection.isConnected)
        let writesBeforeRetry = link.snapshot().writes.count
        XCTAssertEqual(writesBeforeRetry, 2)

        try connection.connect()
        let retry = payload(30, seed: 9)
        try send(retry, over: connection)
        XCTAssertEqual(link.writtenBytes(from: writesBeforeRetry), retry)
        XCTAssertEqual(link.snapshot().connectCalls, 2)
        XCTAssertEqual(connected, 2)
    }

    func testLateAcknowledgementCannotCompleteTheNextOperation() throws {
        link.configure {
            $0.discoverBehavior = .found(.withResponse)
            $0.writeResponses = [.late(0.5)]
        }
        let connection = makeConnection(EscPosBluetoothTimeouts(connect: 3, discovery: 1, write: 0.2))
        try connection.connect()
        XCTAssertThrowsError(try send(payload(10), over: connection)) { error in
            XCTAssertEqual((error as? EscPosError)?.message, "Timed out while waiting for the Bluetooth device.")
        }
        let writesBeforeRetry = link.snapshot().writes.count

        link.configure { $0.connectBehavior = .succeed(after: 0.8) }
        let started = Date()
        try connection.connect()
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.7, "the late acknowledgement at 0.5 s must not finish the reconnect")
        XCTAssertGreaterThanOrEqual(connection.ignoredCallbackCount, 2, "the late write acknowledgement and the cancelled link's disconnect are ignored")

        let retry = payload(25, seed: 4)
        try send(retry, over: connection)
        XCTAssertEqual(link.writtenBytes(from: writesBeforeRetry), retry)
    }

    func testConnectTimeoutInvalidatesTheLink() throws {
        link.configure { $0.connectBehavior = .never }
        let connection = makeConnection(EscPosBluetoothTimeouts(connect: 0.3, discovery: 1, write: 1))
        let started = Date()
        XCTAssertThrowsError(try connection.connect()) { error in
            XCTAssertEqual((error as? EscPosError)?.message, "Unable to connect to bluetooth device.")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(link.snapshot().cancelCalls, 1)
        XCTAssertFalse(connection.isConnected)
        XCTAssertEqual(connected, 0)
    }

    func testLateConnectionAfterTimeoutIsIgnored() throws {
        link.configure { $0.connectBehavior = .succeed(after: 0.5) }
        let connection = makeConnection(EscPosBluetoothTimeouts(connect: 0.2, discovery: 1, write: 1))
        XCTAssertThrowsError(try connection.connect())
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(connection.ignoredCallbackCount, 1)
        XCTAssertFalse(connection.isConnected)
    }

    func testDiscoveryTimeoutInvalidatesTheLink() throws {
        link.configure { $0.discoverBehavior = .never }
        let connection = makeConnection(EscPosBluetoothTimeouts(connect: 1, discovery: 0.3, write: 1))
        XCTAssertThrowsError(try connection.connect()) { error in
            XCTAssertEqual((error as? EscPosError)?.message, "Unable to connect to bluetooth device.")
        }
        XCTAssertEqual(link.snapshot().cancelCalls, 1)
        XCTAssertFalse(connection.isConnected)
    }

    func testDeviceWithoutAPrinterCharacteristicIsRejected() throws {
        link.configure { $0.discoverBehavior = .none }
        let connection = makeConnection()
        XCTAssertThrowsError(try connection.connect())
        XCTAssertFalse(connection.isConnected)
    }

    func testFailedConnectionAttemptIsReported() throws {
        link.configure { $0.connectBehavior = .fail }
        let connection = makeConnection()
        XCTAssertThrowsError(try connection.connect()) { error in
            XCTAssertEqual((error as? EscPosError)?.message, "Unable to connect to bluetooth device.")
        }
    }

    func testDisconnectDuringTransmitFailsTheSend() throws {
        link.configure {
            $0.readyDelay = 0.02
            $0.disconnectAfterWrites = 2
        }
        let connection = makeConnection()
        try connection.connect()
        XCTAssertThrowsError(try send(payload(100), over: connection)) { error in
            XCTAssertEqual((error as? EscPosError)?.message, "Bluetooth device disconnected.")
        }
        XCTAssertTrue(connection.data.isEmpty)
        XCTAssertFalse(connection.isConnected)
    }

    func testAppReceiptOverBluetoothMatchesAndroidBytes() throws {
        link.configure {
            $0.maxWriteLength = 182
            $0.readyDelay = 0.001
        }
        let reference = try Fixtures.referenceCase("app receipt 72mm (Bricks print path)")
        let connection = makeConnection()
        let printer = try ThermalPrinterService().makePrinter(connection: connection, data: ThermalPrinterArguments(reference.data))
        let hexImages = try reference.images.map { name -> String in
            let bitmap = try XCTUnwrap(EscPosBitmap.decode(try Fixtures.image(name)))
            return PrinterTextParserImg.bitmapToHexadecimalString(printer, bitmap)
        }
        try printer.printFormattedText(Fixtures.appReceiptText(hexImages: hexImages), dotsFeedPaper: 1)
        XCTAssertEqual(EscPosHex.string(link.writtenBytes()), reference.expectedBytes)
        XCTAssertEqual(link.snapshot().writesWhileBlocked, 0)
    }

    func testDisconnectBetweenReceiptSegmentsFailsThePrint() throws {
        let reference = try Fixtures.referenceCase("app receipt 72mm (Bricks print path)")
        let connection = makeConnection()
        connection.pacesSends = true
        let printer = try ThermalPrinterService().makePrinter(connection: connection, data: ThermalPrinterArguments(reference.data))
        let hexImages = try reference.images.map { name -> String in
            let bitmap = try XCTUnwrap(EscPosBitmap.decode(try Fixtures.image(name)))
            return PrinterTextParserImg.bitmapToHexadecimalString(printer, bitmap)
        }
        let firstSegmentChunks = (2 + hexImages[0].count / 2 + 19) / 20
        link.configure { $0.disconnectAfterWrites = firstSegmentChunks }
        XCTAssertThrowsError(try printer.printFormattedText(Fixtures.appReceiptText(hexImages: hexImages), dotsFeedPaper: 1)) { error in
            XCTAssertEqual((error as? EscPosError)?.kind, .connection)
        }
        XCTAssertEqual(link.snapshot().writes.count, firstSegmentChunks)
        XCTAssertTrue(connection.data.isEmpty)
    }
}

final class BluetoothAuthorizationTests: XCTestCase {
    private var savedAuthorizationTimeout: TimeInterval = 0
    private var savedStateTimeout: TimeInterval = 0
    private var savedScanDuration: TimeInterval = 0

    override func setUp() {
        savedAuthorizationTimeout = EscPosBluetoothCentral.authorizationTimeout
        savedStateTimeout = EscPosBluetoothCentral.stateTimeout
        savedScanDuration = EscPosBluetoothCentral.scanDuration
        EscPosBluetoothCentral.authorizationTimeout = 2
        EscPosBluetoothCentral.stateTimeout = 2
        EscPosBluetoothCentral.scanDuration = 0.2
    }

    override func tearDown() {
        EscPosBluetoothCentral.authorizationTimeout = savedAuthorizationTimeout
        EscPosBluetoothCentral.stateTimeout = savedStateTimeout
        EscPosBluetoothCentral.scanDuration = savedScanDuration
    }

    private func makeService(authorization: LockedValue<CBManagerAuthorization>, manager: FakeCentralManager, managersMade: LockedValue<Int>) -> (ThermalPrinterService, EscPosBluetoothCentral) {
        let defaults = UserDefaults(suiteName: "thermal-printer-tests-\(UUID().uuidString)")!
        let central = EscPosBluetoothCentral(authorization: { authorization.value }, defaults: defaults) { _ in
            managersMade.value += 1
            return manager
        }
        return (ThermalPrinterService(makeBluetoothCentral: { central }), central)
    }

    func testPromptAnsweredWithAllowGrantsPermission() {
        let authorization = LockedValue(CBManagerAuthorization.notDetermined)
        let manager = FakeCentralManager(state: .unknown)
        let made = LockedValue(0)
        let (service, central) = makeService(authorization: authorization, manager: manager, managersMade: made)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            authorization.value = .allowedAlways
            manager.state = .poweredOn
            central.handleStateUpdate()
        }
        let result = service.run("requestBTPermissions", [["type": "bluetooth"]])
        guard case .success(let value) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(value as? [String: Bool], ["granted": true])
        XCTAssertEqual(made.value, 1)
    }

    func testPromptAnsweredWithDenyRefusesPermission() {
        let authorization = LockedValue(CBManagerAuthorization.notDetermined)
        let manager = FakeCentralManager(state: .unknown)
        let made = LockedValue(0)
        let (service, central) = makeService(authorization: authorization, manager: manager, managersMade: made)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            authorization.value = .denied
            manager.state = .unauthorized
            central.handleStateUpdate()
        }
        let result = service.run("requestBTPermissions", [["type": "bluetooth"]])
        guard case .error(let value) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(value as? [String: Bool], ["granted": false])
    }

    func testRestrictedAccessIsRefusedWithoutPrompting() {
        let made = LockedValue(0)
        let (service, _) = makeService(authorization: LockedValue(.restricted), manager: FakeCentralManager(state: .unauthorized), managersMade: made)
        let result = service.run("requestBTPermissions", [["type": "bluetooth"]])
        guard case .error(let value) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(value as? [String: Bool], ["granted": false])
        XCTAssertEqual(made.value, 0)
    }

    func testUnansweredPromptTimesOut() {
        EscPosBluetoothCentral.authorizationTimeout = 0.5
        let (service, _) = makeService(authorization: LockedValue(.notDetermined), manager: FakeCentralManager(state: .unknown), managersMade: LockedValue(0))
        let started = Date()
        let result = service.run("requestBTPermissions", [["type": "bluetooth"]])
        guard case .error(let value) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(value as? [String: Bool], ["granted": false])
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testBluetoothStatesMapToAndroidErrors() {
        let cases: [(CBManagerAuthorization, CBManagerState, String)] = [
            (.allowedAlways, .poweredOff, "Device not enabled Bluetooth!"),
            (.allowedAlways, .unsupported, "Device doesn't support Bluetooth!"),
            (.allowedAlways, .unauthorized, "Missing permission for Bluetooth!"),
            (.denied, .unauthorized, "Missing permission for Bluetooth!"),
        ]
        for (authorization, state, message) in cases {
            let (service, _) = makeService(authorization: LockedValue(authorization), manager: FakeCentralManager(state: state), managersMade: LockedValue(0))
            let result = service.run("listPrinters", [["type": "bluetooth"]])
            guard case .error(let value) = result else {
                XCTFail("\(state.rawValue): \(result)")
                continue
            }
            XCTAssertEqual(value as? [String: String], ["error": message], "state \(state.rawValue)")
        }
    }

    func testListingWaitsForBluetoothToPowerOn() {
        let manager = FakeCentralManager(state: .unknown)
        let (service, central) = makeService(authorization: LockedValue(.allowedAlways), manager: manager, managersMade: LockedValue(0))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            manager.state = .poweredOn
            central.handleStateUpdate()
        }
        let result = service.run("listPrinters", [["type": "bluetooth"]])
        guard case .success(let value) = result else { return XCTFail("\(result)") }
        XCTAssertEqual((value as? [[String: Any]])?.count, 0)
        XCTAssertEqual(manager.scans, 1)
    }
}
