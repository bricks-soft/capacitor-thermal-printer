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

    private func reproduceStaleAcknowledgement(honorsDisconnectBoundary: Bool) throws -> (EscPosBluetoothConnection, TimeInterval, Error?) {
        link.configure {
            $0.discoverBehavior = .found(.withResponse)
            $0.writeResponses = [.late(0.35), .never]
            $0.honorsDisconnectBoundary = honorsDisconnectBoundary
        }
        let connection = makeConnection(EscPosBluetoothTimeouts(connect: 1, discovery: 1, write: 0.2))
        try connection.connect()
        XCTAssertThrowsError(try send(payload(10), over: connection))
        try connection.connect()
        let started = Date()
        var secondError: Error?
        do {
            try send(payload(10, seed: 3), over: connection)
        } catch {
            secondError = error
        }
        return (connection, Date().timeIntervalSince(started), secondError)
    }

    func testStaleAcknowledgementCannotCompleteANewerWrite() throws {
        let (connection, elapsed, error) = try reproduceStaleAcknowledgement(honorsDisconnectBoundary: true)
        XCTAssertEqual((error as? EscPosError)?.message, "Timed out while waiting for the Bluetooth device.")
        XCTAssertGreaterThanOrEqual(elapsed, 0.19)
        XCTAssertEqual(link.snapshot().dropped, 1, "the link drops the old acknowledgement after didDisconnect")
        XCTAssertFalse(connection.isConnected)
    }

    func testStaleAcknowledgementDeliveredAfterReconnectIsIgnoredByToken() throws {
        let (connection, elapsed, error) = try reproduceStaleAcknowledgement(honorsDisconnectBoundary: false)
        XCTAssertEqual((error as? EscPosError)?.message, "Timed out while waiting for the Bluetooth device.")
        XCTAssertGreaterThanOrEqual(elapsed, 0.19)
        XCTAssertGreaterThanOrEqual(connection.ignoredCallbackCount, 1)
    }

    func testAcknowledgementBeforeTheDisconnectCallbackIsIgnored() throws {
        link.configure {
            $0.discoverBehavior = .found(.withResponse)
            $0.writeResponses = [.late(0.3)]
            $0.cancelDisconnectDelay = 0.4
        }
        let connection = makeConnection(EscPosBluetoothTimeouts(connect: 2, discovery: 1, write: 0.2))
        try connection.connect()
        XCTAssertThrowsError(try send(payload(10), over: connection))
        let writesBeforeRetry = link.snapshot().writes.count
        let started = Date()
        try connection.connect()
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.3, "reconnecting waits for the cancelled link's didDisconnect")
        XCTAssertGreaterThanOrEqual(connection.ignoredCallbackCount, 2, "the old acknowledgement and the old disconnect are ignored")
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

    func testInvalidationCancelsAPendingConnection() throws {
        link.configure { $0.connectBehavior = .succeed(after: 0.5) }
        let connection = makeConnection(EscPosBluetoothTimeouts(connect: 0.2, discovery: 1, write: 1))
        XCTAssertThrowsError(try connection.connect())
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertFalse(link.connected, "the cancelled connection attempt never completes")
        XCTAssertFalse(connection.isConnected)
        link.configure { $0.connectBehavior = .succeed(after: 0.01) }
        try connection.connect()
        XCTAssertTrue(connection.isConnected)
    }

    func testLateConnectionFromACancelledAttemptCannotFinishANewConnect() throws {
        link.configure {
            $0.connectBehavior = .succeed(after: 0.35)
            $0.cancelsPendingConnect = false
            $0.honorsDisconnectBoundary = false
        }
        let connection = makeConnection(EscPosBluetoothTimeouts(connect: 0.2, discovery: 1, write: 1))
        XCTAssertThrowsError(try connection.connect())
        link.configure { $0.connectBehavior = .never }
        XCTAssertThrowsError(try connection.connect(), "the old attempt's didConnect must not finish the new connect")
        XCTAssertFalse(connection.isConnected)
        XCTAssertGreaterThanOrEqual(connection.ignoredCallbackCount, 1)
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

    func testLateDiscoveryFromACancelledAttemptCannotFinishANewDiscovery() throws {
        link.configure {
            $0.discoverBehavior = .late(0.35, .withoutResponse)
            $0.honorsDisconnectBoundary = false
        }
        let connection = makeConnection(EscPosBluetoothTimeouts(connect: 1, discovery: 0.2, write: 1))
        XCTAssertThrowsError(try connection.connect())
        link.configure { $0.discoverBehavior = .never }
        XCTAssertThrowsError(try connection.connect(), "the old attempt's discovery must not finish the new one")
        XCTAssertFalse(connection.isConnected)
        XCTAssertGreaterThanOrEqual(connection.ignoredCallbackCount, 1)
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
        link.configure {
            $0.disconnectAfterWrites = firstSegmentChunks
            $0.disconnectDelay = 0.3
        }
        XCTAssertThrowsError(try printer.printFormattedText(Fixtures.appReceiptText(hexImages: hexImages), dotsFeedPaper: 1)) { error in
            XCTAssertEqual((error as? EscPosError)?.message, "Unable to send data to device.", "the link drops while the first segment's pause runs")
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
        EscPosBluetoothCentral.scanDuration = 0.3
    }

    override func tearDown() {
        EscPosBluetoothCentral.authorizationTimeout = savedAuthorizationTimeout
        EscPosBluetoothCentral.stateTimeout = savedStateTimeout
        EscPosBluetoothCentral.scanDuration = savedScanDuration
    }

    static func temporaryStore() -> EscPosKnownPrinterStore {
        EscPosKnownPrinterStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("thermal-printer-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("known.json"))
    }

    static func makeService(authorization: LockedValue<CBManagerAuthorization>, manager: FakeCentralManager, managersMade: LockedValue<Int>) -> (ThermalPrinterService, EscPosBluetoothCentral) {
        let central = EscPosBluetoothCentral(authorization: { authorization.value }, store: temporaryStore()) { central in
            managersMade.value += 1
            manager.central = central
            return manager
        }
        return (ThermalPrinterService(makeBluetoothCentral: { central }), central)
    }

    static func requestPermission(_ service: ThermalPrinterService) -> LockedValue<[ThermalPrinterResult]> {
        let results = LockedValue<[ThermalPrinterResult]>([])
        service.execute("requestBTPermissions", [["type": "bluetooth"]]) { result in
            results.value += [result]
        }
        return results
    }

    static func waitFor(_ results: LockedValue<[ThermalPrinterResult]>, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while results.value.isEmpty && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func answer(_ value: CBManagerAuthorization, state: CBManagerState, authorization: LockedValue<CBManagerAuthorization>, manager: FakeCentralManager, central: EscPosBluetoothCentral) {
        authorization.value = value
        manager.state = state
        central.handleStateUpdate()
    }

    func testAllowGivenAfterTheListingWaitLimitGrantsPermission() {
        EscPosBluetoothCentral.authorizationTimeout = 0.2
        let authorization = LockedValue(CBManagerAuthorization.notDetermined)
        let manager = FakeCentralManager(state: .unknown)
        let made = LockedValue(0)
        let (service, central) = Self.makeService(authorization: authorization, manager: manager, managersMade: made)

        let results = Self.requestPermission(service)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertTrue(results.value.isEmpty, "no answer yet, so no result")
        XCTAssertEqual(made.value, 1, "the request shows the prompt")
        central.handleStateUpdate()
        XCTAssertTrue(results.value.isEmpty, "a state update without an answer does not complete the request")

        answer(.allowedAlways, state: .poweredOn, authorization: authorization, manager: manager, central: central)
        Self.waitFor(results)
        central.handleStateUpdate()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(results.value.count, 1)
        guard case .success(let value)? = results.value.first else { return XCTFail("\(results.value)") }
        XCTAssertEqual(value as? [String: Bool], ["granted": true])
    }

    func testDenyGivenAfterTheListingWaitLimitRefusesPermission() {
        EscPosBluetoothCentral.authorizationTimeout = 0.2
        let authorization = LockedValue(CBManagerAuthorization.notDetermined)
        let manager = FakeCentralManager(state: .unknown)
        let (service, central) = Self.makeService(authorization: authorization, manager: manager, managersMade: LockedValue(0))

        let results = Self.requestPermission(service)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertTrue(results.value.isEmpty)
        answer(.denied, state: .unauthorized, authorization: authorization, manager: manager, central: central)
        Self.waitFor(results)
        central.handleStateUpdate()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(results.value.count, 1)
        guard case .error(let value)? = results.value.first else { return XCTFail("\(results.value)") }
        XCTAssertEqual(value as? [String: Bool], ["granted": false])
    }

    func testUnansweredPromptKeepsTheRequestOpenWithoutBlockingOtherCalls() {
        EscPosBluetoothCentral.authorizationTimeout = 0.2
        let (service, _) = Self.makeService(authorization: LockedValue(.notDetermined), manager: FakeCentralManager(state: .unknown), managersMade: LockedValue(0))

        let results = Self.requestPermission(service)
        let other = LockedValue<[ThermalPrinterResult]>([])
        service.execute("listPrinters", [["type": "usb"]]) { other.value += [$0] }
        Self.waitFor(other, timeout: 1)
        XCTAssertEqual(other.value.count, 1, "the open request does not hold the command queue")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(results.value.isEmpty, "an unanswered prompt is not reported as denied")
    }

    func testTeardownCancelsTheRequestOnceWithoutReportingDenial() {
        let authorization = LockedValue(CBManagerAuthorization.notDetermined)
        let manager = FakeCentralManager(state: .unknown)
        let (service, central) = Self.makeService(authorization: authorization, manager: manager, managersMade: LockedValue(0))

        let results = Self.requestPermission(service)
        Thread.sleep(forTimeInterval: 0.2)
        service.cancelPendingRequests()
        Self.waitFor(results)
        answer(.allowedAlways, state: .poweredOn, authorization: authorization, manager: manager, central: central)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(results.value.count, 1)
        guard case .cancelled? = results.value.first else { return XCTFail("\(results.value)") }
    }

    func testReleasingTheServiceCancelsTheRequest() throws {
        let authorization = LockedValue(CBManagerAuthorization.notDetermined)
        var service: ThermalPrinterService?
        var central: EscPosBluetoothCentral?
        do {
            let made = Self.makeService(authorization: authorization, manager: FakeCentralManager(state: .unknown), managersMade: LockedValue(0))
            service = made.0
            central = made.1
        }
        let results = Self.requestPermission(try XCTUnwrap(service))
        Thread.sleep(forTimeInterval: 0.2)
        service = nil
        Self.waitFor(results)
        authorization.value = .allowedAlways
        central?.handleStateUpdate()
        XCTAssertEqual(results.value.count, 1)
        guard case .cancelled? = results.value.first else { return XCTFail("\(results.value)") }
    }

    func testEveryWaitingRequestGetsTheAnswerOnce() {
        let authorization = LockedValue(CBManagerAuthorization.notDetermined)
        let manager = FakeCentralManager(state: .unknown)
        let made = LockedValue(0)
        let (service, central) = Self.makeService(authorization: authorization, manager: manager, managersMade: made)

        let first = Self.requestPermission(service)
        let second = Self.requestPermission(service)
        Thread.sleep(forTimeInterval: 0.2)
        answer(.allowedAlways, state: .poweredOn, authorization: authorization, manager: manager, central: central)
        Self.waitFor(first)
        Self.waitFor(second)
        answer(.allowedAlways, state: .poweredOn, authorization: authorization, manager: manager, central: central)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(first.value.count, 1)
        XCTAssertEqual(second.value.count, 1)
        XCTAssertEqual(made.value, 1)
        let third = Self.requestPermission(service)
        Self.waitFor(third)
        guard case .success(let value)? = third.value.first else { return XCTFail("\(third.value)") }
        XCTAssertEqual(value as? [String: Bool], ["granted": true], "an earlier answer completes a new request at once")
    }

    func testRestrictedAccessIsRefusedWithoutPrompting() {
        let made = LockedValue(0)
        let (service, _) = Self.makeService(authorization: LockedValue(.restricted), manager: FakeCentralManager(state: .unauthorized), managersMade: made)
        let results = Self.requestPermission(service)
        Self.waitFor(results)
        guard case .error(let value)? = results.value.first else { return XCTFail("\(results.value)") }
        XCTAssertEqual(value as? [String: Bool], ["granted": false])
        XCTAssertEqual(made.value, 0)
    }

    func testListingWithAnUnansweredPromptFailsAfterItsWaitAndKeepsThePromptOpen() {
        EscPosBluetoothCentral.authorizationTimeout = 0.3
        let authorization = LockedValue(CBManagerAuthorization.notDetermined)
        let manager = FakeCentralManager(state: .unknown)
        let (service, central) = Self.makeService(authorization: authorization, manager: manager, managersMade: LockedValue(0))
        EscPosBluetoothCentral.stateTimeout = 0.3

        let listed = service.run("listPrinters", [["type": "bluetooth"]])
        guard case .error(let value) = listed else { return XCTFail("\(listed)") }
        XCTAssertEqual(value as? [String: String], ["error": "Missing permission for Bluetooth!"])
        let results = Self.requestPermission(service)
        answer(.allowedAlways, state: .poweredOn, authorization: authorization, manager: manager, central: central)
        Self.waitFor(results)
        guard case .success? = results.value.first else { return XCTFail("\(results.value)") }
        let relisted = service.run("listPrinters", [["type": "bluetooth"]])
        guard case .success = relisted else { return XCTFail("\(relisted)") }
    }

    func testBluetoothStatesMapToAndroidErrors() {
        let cases: [(CBManagerAuthorization, CBManagerState, String)] = [
            (.allowedAlways, .poweredOff, "Device not enabled Bluetooth!"),
            (.allowedAlways, .unsupported, "Device doesn't support Bluetooth!"),
            (.allowedAlways, .unauthorized, "Missing permission for Bluetooth!"),
            (.denied, .unauthorized, "Missing permission for Bluetooth!"),
        ]
        for (authorization, state, message) in cases {
            let (service, _) = Self.makeService(authorization: LockedValue(authorization), manager: FakeCentralManager(state: state), managersMade: LockedValue(0))
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
        let (service, central) = Self.makeService(authorization: LockedValue(.allowedAlways), manager: manager, managersMade: LockedValue(0))
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

final class BluetoothDiscoveryTests: XCTestCase {
    private var savedScanDuration: TimeInterval = 0

    override func setUp() {
        savedScanDuration = EscPosBluetoothCentral.scanDuration
        EscPosBluetoothCentral.scanDuration = 0.4
    }

    override func tearDown() {
        EscPosBluetoothCentral.scanDuration = savedScanDuration
    }

    private func advertisement(name: String? = nil, services: [String] = [], connectable: Bool? = true) -> [String: Any] {
        var data: [String: Any] = [:]
        if let name = name {
            data[CBAdvertisementDataLocalNameKey] = name
        }
        if !services.isEmpty {
            data[CBAdvertisementDataServiceUUIDsKey] = services.map { CBUUID(string: $0) }
        }
        if let connectable = connectable {
            data[CBAdvertisementDataIsConnectable] = NSNumber(value: connectable)
        }
        return data
    }

    func testListPrintersAppliesTheDiscoveryRuleToScanResults() throws {
        let unnamedPrinter = FakePeripheral(name: nil)
        let namedPrinter = FakePeripheral(name: nil)
        let peripheralNamedPrinter = FakePeripheral(name: "MPT-II")
        let manager = FakeCentralManager(state: .poweredOn)
        manager.advertisements = [
            (unnamedPrinter, advertisement(services: ["18F0"])),
            (namedPrinter, advertisement(name: "Printer001")),
            (peripheralNamedPrinter, advertisement()),
            (FakePeripheral(name: "JBL Flip 6"), advertisement(name: "JBL Flip 6", services: ["FE07"])),
            (FakePeripheral(name: nil), advertisement()),
            (FakePeripheral(name: nil), advertisement(name: "RPP02N", services: ["18F0"], connectable: false)),
        ]
        let (service, _) = BluetoothAuthorizationTests.makeService(authorization: LockedValue(.allowedAlways), manager: manager, managersMade: LockedValue(0))

        let result = service.run("listPrinters", [["type": "bluetooth"]])
        guard case .success(let value) = result, let printers = value as? [[String: Any]] else {
            return XCTFail("\(result)")
        }
        let listed = Dictionary(uniqueKeysWithValues: printers.map { ($0["address"] as? String ?? "", $0["name"] as? String ?? "") })
        XCTAssertEqual(listed.count, 3)
        XCTAssertEqual(listed[unnamedPrinter.identifier.uuidString], "BLE Printer \(unnamedPrinter.identifier.uuidString.prefix(4))")
        XCTAssertEqual(listed[namedPrinter.identifier.uuidString], "Printer001")
        XCTAssertEqual(listed[peripheralNamedPrinter.identifier.uuidString], "MPT-II")
        XCTAssertTrue(printers.allSatisfy { !($0["name"] as? String ?? "").isEmpty }, "every listed device has a name")
        let unnamedEntry = try XCTUnwrap(printers.first { $0["address"] as? String == unnamedPrinter.identifier.uuidString })
        XCTAssertEqual(unnamedEntry["features"] as? [String], ["18F0"])
        XCTAssertEqual(unnamedEntry["type"] as? Int, 2)
    }

    func testScanResponsePacketsCompleteTheListedPrinter() throws {
        let printer = FakePeripheral(name: nil)
        let serviceLater = FakePeripheral(name: nil)
        let vendorLater = FakePeripheral(name: nil)
        let vendorService = "7D9F0001-5F49-4D67-9C46-1E5A4B3F2C10"
        let manager = FakeCentralManager(state: .poweredOn)
        manager.advertisements = [
            (printer, advertisement(services: ["18F0"])),
            (serviceLater, advertisement(name: "SPP-R200III")),
            (vendorLater, advertisement(name: "MPT-III")),
            (printer, advertisement(name: "MPT-II")),
            (serviceLater, advertisement(services: ["FF00"])),
            (vendorLater, advertisement(services: [vendorService])),
        ]
        let (service, _) = BluetoothAuthorizationTests.makeService(authorization: LockedValue(.allowedAlways), manager: manager, managersMade: LockedValue(0))

        let result = service.run("listPrinters", [["type": "bluetooth"]])
        guard case .success(let value) = result, let printers = value as? [[String: Any]] else {
            return XCTFail("\(result)")
        }
        XCTAssertEqual(printers.count, 3)
        let listed = Dictionary(uniqueKeysWithValues: try printers.map { (try XCTUnwrap($0["address"] as? String), $0) })
        let listedPrinter = try XCTUnwrap(listed[printer.identifier.uuidString])
        XCTAssertEqual(listedPrinter["name"] as? String, "MPT-II", "the scan response name replaces the fallback label")
        XCTAssertEqual(listedPrinter["features"] as? [String], ["18F0"], "services from earlier packets are kept")
        let listedLater = try XCTUnwrap(listed[serviceLater.identifier.uuidString])
        XCTAssertEqual(listedLater["name"] as? String, "SPP-R200III")
        XCTAssertEqual(listedLater["features"] as? [String], ["FF00"], "a printer service in a later packet makes the device a candidate")
        let listedVendor = try XCTUnwrap(listed[vendorLater.identifier.uuidString])
        XCTAssertEqual(listedVendor["name"] as? String, "MPT-III")
        XCTAssertEqual(listedVendor["features"] as? [String], [vendorService], "a device listed for its name stays listed when a later packet has only services")
    }

    func testNameSearchStopsWhenTheScanResponseCarriesTheName() {
        let printer = FakePeripheral(name: nil)
        let manager = FakeCentralManager(state: .poweredOn)
        manager.advertisements = [
            (printer, advertisement(services: ["18F0"])),
            (printer, advertisement(name: "MPT-II", services: ["18F0"])),
        ]
        let (_, central) = BluetoothAuthorizationTests.makeService(authorization: LockedValue(.allowedAlways), manager: manager, managersMade: LockedValue(0))
        XCTAssertEqual(central.waitForState(), .poweredOn)

        let started = Date()
        let found = central.scan(duration: 5) { $0.name == "MPT-II" }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the scan ends as soon as the name arrives")
        XCTAssertEqual(found.map(\.name), ["MPT-II"])
        XCTAssertEqual(found.map(\.identifier), [printer.identifier])
    }

    func testFallbackLabelIsStableForAPeripheral() {
        let identifier = UUID(uuidString: "0A1B2C3D-0000-0000-0000-000000000000")!
        XCTAssertEqual(EscPosBluetoothCentral.fallbackName(for: identifier), "BLE Printer 0A1B")
    }
}

final class KnownPrinterStoreTests: XCTestCase {
    func testRemembersPrintersInAFile() throws {
        let store = BluetoothAuthorizationTests.temporaryStore()
        XCTAssertEqual(store.load(), [:])
        let first = UUID()
        let second = UUID()
        store.remember(identifier: first, name: "Printer001")
        store.remember(identifier: second, name: "MPT-II")
        store.remember(identifier: first, name: "Printer001 renamed")
        let reloaded = EscPosKnownPrinterStore(fileURL: store.fileURL)
        XCTAssertEqual(reloaded.load(), [first.uuidString: "Printer001 renamed", second.uuidString: "MPT-II"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testUnreadableFileMeansNoKnownPrinters() throws {
        let store = BluetoothAuthorizationTests.temporaryStore()
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load(), [:])
    }

    func testDefaultLocationIsApplicationSupport() {
        let url = EscPosKnownPrinterStore.applicationSupportFile()
        XCTAssertTrue(url.path.contains("Application Support/ThermalPrinter/"))
        XCTAssertEqual(url.lastPathComponent, "known-bluetooth-printers.json")
    }
}
