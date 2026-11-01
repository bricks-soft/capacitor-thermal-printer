import Darwin
import Foundation
import Network
@testable import ThermalPrinter
import XCTest

final class ScriptedConnection: EscPosDeviceConnection {
    private(set) var sentPayloads: [[UInt8]] = []
    private var connected = false
    private let disconnectAfterSends: Int?

    init(disconnectAfterSends: Int?) {
        self.disconnectAfterSends = disconnectAfterSends
        super.init()
        pacesSends = false
    }

    override var isConnected: Bool { connected }

    @discardableResult
    override func connect() throws -> EscPosDeviceConnection {
        connected = true
        return self
    }

    @discardableResult
    override func disconnect() -> EscPosDeviceConnection {
        connected = false
        return super.disconnect()
    }

    override func transmit(_ bytes: [UInt8]) throws {
        sentPayloads.append(bytes)
        if let limit = disconnectAfterSends, sentPayloads.count == limit {
            connected = false
        }
    }
}

final class DisconnectPropagationTests: XCTestCase {
    private func receiptData(images: [String], cut: Bool = false) throws -> ([String: Any], Int) {
        let reference = try Fixtures.referenceCase("app receipt 72mm (Bricks print path)")
        let printer = try ThermalPrinterService().makePrinter(connection: CaptureConnection(), data: ThermalPrinterArguments(reference.data))
        let hexImages = try images.map { name -> String in
            let bitmap = try XCTUnwrap(EscPosBitmap.decode(try Fixtures.image(name)))
            return PrinterTextParserImg.bitmapToHexadecimalString(printer, bitmap)
        }
        let data: [String: Any] = [
            "type": "tcp",
            "id": "scripted",
            "address": "127.0.0.1",
            "printerWidthMM": 72,
            "text": Fixtures.appReceiptText(hexImages: hexImages),
            "dotsFeedPaper": 1,
        ]
        return (data, hexImages.count)
    }

    private func runPrint(_ action: String, _ data: [String: Any], connection: ScriptedConnection) -> [ThermalPrinterResult] {
        let service = ThermalPrinterService(makeTcpConnection: { _, _ in connection })
        let results = LockedValue<[ThermalPrinterResult]>([])
        let done = expectation(description: action)
        service.execute(action, [data]) { result in
            results.value.append(result)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        Thread.sleep(forTimeInterval: 0.2)
        return results.value
    }

    func testDisconnectBetweenSegmentsReportsOneError() throws {
        let reference = try Fixtures.referenceCase("app receipt 72mm (Bricks print path)")
        let (data, _) = try receiptData(images: reference.images)
        let connection = ScriptedConnection(disconnectAfterSends: 1)
        let results = runPrint("printFormattedText", data, connection: connection)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first.flatMap(errorMessage), "Unable to send data to device.")
        XCTAssertEqual(connection.sentPayloads.count, 1)
        XCTAssertTrue(connection.data.isEmpty)
    }

    func testDisconnectBeforeFeedReportsOneError() throws {
        let reference = try Fixtures.referenceCase("app receipt 72mm (Bricks print path)")
        let (data, segments) = try receiptData(images: reference.images)
        let connection = ScriptedConnection(disconnectAfterSends: segments)
        let results = runPrint("printFormattedText", data, connection: connection)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first.flatMap(errorMessage), "Unable to send data to device.")
        XCTAssertEqual(connection.sentPayloads.count, segments)
        XCTAssertFalse(connection.sentPayloads.contains([0x1B, 0x4A, 0x01]))
    }

    func testDisconnectBeforeCutReportsOneError() throws {
        let reference = try Fixtures.referenceCase("app receipt 72mm (Bricks print path)")
        let (data, segments) = try receiptData(images: reference.images)
        let connection = ScriptedConnection(disconnectAfterSends: segments + 1)
        let results = runPrint("printFormattedTextAndCut", data, connection: connection)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first.flatMap(errorMessage), "Unable to send data to device.")
        XCTAssertEqual(connection.sentPayloads.last, [0x1B, 0x4A, 0x01])
        XCTAssertFalse(connection.sentPayloads.contains([0x1D, 0x56, 0x01]))
    }

    func testUninterruptedPrintReportsOneSuccess() throws {
        let reference = try Fixtures.referenceCase("app receipt 72mm (Bricks print path)")
        let (data, segments) = try receiptData(images: reference.images)
        let connection = ScriptedConnection(disconnectAfterSends: nil)
        let results = runPrint("printFormattedText", data, connection: connection)
        XCTAssertEqual(results.count, 1)
        guard case .success(nil) = results.first else { return XCTFail("\(results)") }
        XCTAssertEqual(connection.sentPayloads.count, segments + 1)
        XCTAssertEqual(EscPosHex.string(connection.sentPayloads.flatMap { $0 }), reference.expectedBytes)
    }
}

final class MemoryTests: XCTestCase {
    func testParserLinesColumnsAndImagesAreReleasedAfterPrinting() throws {
        let reference = try Fixtures.referenceCase("app receipt 72mm (Bricks print path)")
        weak var weakParser: PrinterTextParser?
        weak var weakLine: PrinterTextParserLine?
        weak var weakColumn: PrinterTextParserColumn?
        weak var weakImage: PrinterTextParserElement?
        weak var weakPrinter: EscPosPrinter?

        try autoreleasepool {
            let connection = CaptureConnection()
            let printer = try ThermalPrinterService().makePrinter(connection: connection, data: ThermalPrinterArguments(reference.data))
            let hexImages = try reference.images.map { name -> String in
                let bitmap = try XCTUnwrap(EscPosBitmap.decode(try Fixtures.image(name)))
                return PrinterTextParserImg.bitmapToHexadecimalString(printer, bitmap)
            }
            let parser = PrinterTextParser(printer: printer).setFormattedText(JavaString(Fixtures.appReceiptText(hexImages: hexImages)))
            let lines = try parser.parse()
            for line in lines {
                for column in line.columns {
                    for element in column.elements {
                        try element.print(try XCTUnwrap(printer.printer))
                    }
                }
            }
            weakParser = parser
            weakLine = lines.first
            weakColumn = lines.first?.columns.first
            weakImage = lines.first?.columns.first?.elements.first
            weakPrinter = printer
            XCTAssertTrue(weakImage is PrinterTextParserImg)
        }

        XCTAssertNil(weakParser)
        XCTAssertNil(weakLine)
        XCTAssertNil(weakColumn)
        XCTAssertNil(weakImage)
        XCTAssertNil(weakPrinter)
    }

    func testRepeatedLongReceiptsDoNotGrowMemory() throws {
        let reference = try Fixtures.referenceCase("app receipt 72mm (Bricks print path)")
        let sizing = try ThermalPrinterService().makePrinter(connection: CaptureConnection(), data: ThermalPrinterArguments(reference.data))
        let hexImages = try reference.images.map { name -> String in
            let bitmap = try XCTUnwrap(EscPosBitmap.decode(try Fixtures.image(name)))
            return PrinterTextParserImg.bitmapToHexadecimalString(sizing, bitmap)
        }
        let longReceipt = Fixtures.appReceiptText(hexImages: Array(repeating: hexImages, count: 4).flatMap { $0 })

        func printOnce() throws {
            try autoreleasepool {
                let printer = try ThermalPrinterService().makePrinter(connection: CaptureConnection(), data: ThermalPrinterArguments(reference.data))
                try printer.printFormattedText(longReceipt, dotsFeedPaper: 1)
            }
        }

        for _ in 0..<3 {
            try printOnce()
        }
        let before = MemoryTests.footprint()
        for _ in 0..<25 {
            try printOnce()
        }
        let growth = MemoryTests.footprint() - before
        XCTAssertLessThan(growth, 20 * 1024 * 1024, "footprint grew \(growth / 1024) KB over 25 long receipts")
    }

    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}

final class FakeNetworkConnection: EscPosNetworkConnection {
    typealias Step = (after: TimeInterval, state: NWConnection.State, reason: NWPath.UnsatisfiedReason?)

    var stateUpdateHandler: ((NWConnection.State) -> Void)?
    private(set) var unsatisfiedReason: NWPath.UnsatisfiedReason?
    private let script: [Step]
    private let lock = NSLock()
    private var cancels = 0
    private var sentData = Data()
    private var receiver: ((Bool, NWError?) -> Void)?
    private var queue: DispatchQueue?

    init(script: [Step]) {
        self.script = script
    }

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancels
    }

    var sent: Data {
        lock.lock()
        defer { lock.unlock() }
        return sentData
    }

    func start(queue: DispatchQueue) {
        self.queue = queue
        for step in script {
            queue.asyncAfter(deadline: .now() + step.after) { [weak self] in
                guard let self = self else { return }
                self.unsatisfiedReason = step.reason
                self.stateUpdateHandler?(step.state)
            }
        }
    }

    func send(_ data: Data, completion: @escaping (NWError?) -> Void) {
        lock.lock()
        sentData.append(data)
        lock.unlock()
        queue?.async { completion(nil) }
    }

    func receive(completion: @escaping (Bool, NWError?) -> Void) {
        lock.lock()
        receiver = completion
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancels += 1
        lock.unlock()
    }

    func closeFromPrinter() {
        lock.lock()
        let pending = receiver
        receiver = nil
        lock.unlock()
        queue?.async { pending?(true, nil) }
    }
}

final class TcpWaitingTests: XCTestCase {
    private var savedConnectTimeout: TimeInterval = 0
    private var savedPermissionTimeout: TimeInterval = 0

    override func setUp() {
        savedConnectTimeout = EscPosTcpConnection.connectTimeout
        savedPermissionTimeout = EscPosTcpConnection.localNetworkPermissionTimeout
    }

    override func tearDown() {
        EscPosTcpConnection.connectTimeout = savedConnectTimeout
        EscPosTcpConnection.localNetworkPermissionTimeout = savedPermissionTimeout
    }

    private func makeConnection(_ fake: FakeNetworkConnection) -> EscPosTcpConnection {
        let connection = EscPosTcpConnection(address: "192.168.1.50", port: 9100) { _, _ in fake }
        connection.pacesSends = false
        return connection
    }

    func testLocalNetworkPermissionKeepsTheConnectionWaiting() {
        XCTAssertEqual(EscPosTcpConnection.waitingDisposition(for: .posix(.ECONNREFUSED), unsatisfiedReason: .localNetworkDenied), .awaitLocalNetworkPermission)
        XCTAssertEqual(EscPosTcpConnection.waitingDisposition(for: .dns(EscPosTcpConnection.localNetworkPolicyDenied), unsatisfiedReason: nil), .awaitLocalNetworkPermission)
    }

    func testOtherWaitingReasonsFailLikeAndroid() {
        XCTAssertEqual(EscPosTcpConnection.waitingDisposition(for: .posix(.ECONNREFUSED), unsatisfiedReason: nil), .fail)
        XCTAssertEqual(EscPosTcpConnection.waitingDisposition(for: .posix(.ENETUNREACH), unsatisfiedReason: .notAvailable), .fail)
        XCTAssertEqual(EscPosTcpConnection.waitingDisposition(for: .dns(-65554), unsatisfiedReason: nil), .fail)
    }

    func testPermissionGrantedWhileWaitingConnects() throws {
        EscPosTcpConnection.connectTimeout = 0.1
        EscPosTcpConnection.localNetworkPermissionTimeout = 3
        let fake = FakeNetworkConnection(script: [
            (0.02, .preparing, nil),
            (0.05, .waiting(.posix(.ECONNREFUSED)), .localNetworkDenied),
            (0.5, .ready, nil),
        ])
        let connection = makeConnection(fake)
        let started = Date()
        try connection.connect()
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.45)
        XCTAssertTrue(connection.isConnected)
        XCTAssertEqual(fake.cancelCount, 0)

        connection.write([0x1B, 0x40])
        try connection.send()
        XCTAssertEqual([UInt8](fake.sent), [0x1B, 0x40])
    }

    func testPermissionWaitTimesOutAndCleansUp() {
        EscPosTcpConnection.connectTimeout = 0.1
        EscPosTcpConnection.localNetworkPermissionTimeout = 0.4
        let fake = FakeNetworkConnection(script: [
            (0.05, .waiting(.posix(.ECONNREFUSED)), .localNetworkDenied),
            (0.8, .ready, nil),
        ])
        let connection = makeConnection(fake)
        let started = Date()
        XCTAssertThrowsError(try connection.connect()) { error in
            XCTAssertEqual((error as? EscPosError)?.message, "Unable to connect to TCP device.")
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.35)
        XCTAssertLessThan(elapsed, 0.75)
        XCTAssertEqual(fake.cancelCount, 1)
        XCTAssertNil(fake.stateUpdateHandler)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertFalse(connection.isConnected, "a ready state after cleanup must not revive the connection")
    }

    func testOtherWaitingFailsWithoutWaitingForTheTimeout() {
        EscPosTcpConnection.connectTimeout = 2
        let fake = FakeNetworkConnection(script: [(0.05, .waiting(.posix(.ECONNREFUSED)), nil)])
        let connection = makeConnection(fake)
        let started = Date()
        XCTAssertThrowsError(try connection.connect())
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertEqual(fake.cancelCount, 1)
    }

    func testNoProgressFailsAtTheConnectTimeout() {
        EscPosTcpConnection.connectTimeout = 0.3
        let fake = FakeNetworkConnection(script: [(0.02, .preparing, nil)])
        let connection = makeConnection(fake)
        let started = Date()
        XCTAssertThrowsError(try connection.connect())
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.28)
        XCTAssertLessThan(elapsed, 1)
        XCTAssertEqual(fake.cancelCount, 1)
    }

    func testPrinterClosingTheSocketMarksTheConnectionClosed() throws {
        let fake = FakeNetworkConnection(script: [(0.01, .ready, nil)])
        let connection = makeConnection(fake)
        try connection.connect()
        XCTAssertTrue(connection.isConnected)
        fake.closeFromPrinter()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(connection.isConnected)
    }

    func testUnreachablePrinterFailsWithinTheConnectTimeout() {
        EscPosTcpConnection.connectTimeout = 1
        let connection = EscPosTcpConnection(address: "192.0.2.1", port: 9100)
        let started = Date()
        XCTAssertThrowsError(try connection.connect()) { error in
            XCTAssertEqual((error as? EscPosError)?.message, "Unable to connect to TCP device.")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertFalse(connection.isConnected)
    }
}
