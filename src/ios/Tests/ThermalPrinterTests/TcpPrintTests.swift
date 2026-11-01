import Foundation
import Network
@testable import ThermalPrinter
import XCTest

final class FakeNetworkPrinter {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-printer")
    private let lock = NSLock()
    private var buffers: [Data] = []
    private var connections: [NWConnection] = []
    private let ready = DispatchSemaphore(value: 0)

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.ready.signal()
            }
        }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut {
            throw NSError(domain: "FakeNetworkPrinter", code: 1, userInfo: [NSLocalizedDescriptionKey: "listener did not start"])
        }
    }

    var port: Int { Int(listener.port?.rawValue ?? 0) }

    var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffers.count
    }

    var received: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffers.reduce(Data(), +)
    }

    func received(onConnection index: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        return index < buffers.count ? buffers[index] : Data()
    }

    func waitForBytes(_ count: Int, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while received.count < count && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    func closeClients() {
        lock.lock()
        let open = connections
        connections = []
        lock.unlock()
        open.forEach { $0.cancel() }
    }

    func stop() {
        closeClients()
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        let index = buffers.count
        buffers.append(Data())
        connections.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        receive(connection, index: index)
    }

    private func receive(_ connection: NWConnection, index: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.lock.lock()
                self.buffers[index].append(data)
                self.lock.unlock()
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, index: index)
        }
    }
}

final class TcpPrintTests: XCTestCase {
    private var printer: FakeNetworkPrinter!

    override func setUpWithError() throws {
        printer = try FakeNetworkPrinter()
    }

    override func tearDown() {
        printer.stop()
        printer = nil
    }

    private func target(_ extra: [String: Any] = [:]) -> [String: Any] {
        var data: [String: Any] = [
            "type": "tcp",
            "id": "fake-lan-printer",
            "address": "127.0.0.1",
            "port": printer.port,
            "printerWidthMM": 72,
        ]
        extra.forEach { data[$0.key] = $0.value }
        return data
    }

    func testAppReceiptPrintsOverTcpWithAndroidBytes() throws {
        let reference = try Fixtures.referenceCase("app receipt 72mm (Bricks print path)")
        let service = ThermalPrinterService()

        var hexImages: [String] = []
        for image in reference.images {
            let result = service.run("bitmapToHexadecimalString", [target(["base64": try Fixtures.dataURL(image)])])
            guard case .success(let value) = result, let hex = value as? String else {
                return XCTFail("bitmapToHexadecimalString failed: \(result)")
            }
            hexImages.append(hex)
        }

        let result = service.run("printFormattedText", [target([
            "text": Fixtures.appReceiptText(hexImages: hexImages),
            "dotsFeedPaper": 1,
        ])])
        guard case .success(nil) = result else {
            return XCTFail("printFormattedText failed: \(result)")
        }

        let expected = try XCTUnwrap(reference.expectedBytes)
        printer.waitForBytes(expected.count / 2)
        XCTAssertEqual(EscPosHex.string([UInt8](printer.received)), expected)
        XCTAssertEqual(printer.connectionCount, 1, "bitmap conversion and printing share the cached connection, as on Android")
    }

    func testFormattedTextAndCutOverTcp() throws {
        let reference = try Fixtures.referenceCase("dantsu readme order and cut")
        let service = ThermalPrinterService()
        let result = service.run("printFormattedTextAndCut", [target(reference.data.merging(["port": printer.port, "address": "127.0.0.1"]) { $1 })])
        guard case .success = result else {
            return XCTFail("printFormattedTextAndCut failed: \(result)")
        }
        let expected = try XCTUnwrap(reference.expectedBytes)
        printer.waitForBytes(expected.count / 2)
        XCTAssertEqual(EscPosHex.string([UInt8](printer.received)), expected)
    }

    func testReconnectsAfterThePrinterClosesTheSocket() throws {
        let service = ThermalPrinterService()
        let first = service.run("printFormattedText", [target(["text": "[L]first", "dotsFeedPaper": 0])])
        guard case .success = first else { return XCTFail("\(first)") }
        printer.waitForBytes(1)
        printer.closeClients()
        Thread.sleep(forTimeInterval: 0.5)

        let second = service.run("printFormattedText", [target(["text": "[L]second", "dotsFeedPaper": 0])])
        guard case .success = second else { return XCTFail("\(second)") }
        let deadline = Date().addingTimeInterval(5)
        while printer.connectionCount < 2 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(printer.connectionCount, 2)
        let secondPayload = printer.received(onConnection: 1)
        XCTAssertTrue(String(decoding: secondPayload, as: UTF8.self).contains("second"))
    }

    func testRefusedConnectionReportsAndroidMessage() throws {
        let port = printer.port
        printer.stop()
        Thread.sleep(forTimeInterval: 0.2)
        let service = ThermalPrinterService()
        let result = service.run("printFormattedText", [["type": "tcp", "id": "gone", "address": "127.0.0.1", "port": port, "text": "[L]x"]])
        guard case .error(let payload) = result else { return XCTFail("expected an error, got \(result)") }
        XCTAssertEqual(payload as? [String: String], ["error": "Unable to connect to TCP device."])
    }

    func testGetEncodingAndDisconnectOverTcp() throws {
        let service = ThermalPrinterService()
        let encoding = service.run("getEncoding", [target(["charsetEncoding": ["charsetName": "windows-1256", "charsetId": 50]])])
        guard case .success(let value) = encoding, let dictionary = value as? [String: Any] else {
            return XCTFail("\(encoding)")
        }
        XCTAssertEqual(dictionary["name"] as? String, "windows-1256")
        XCTAssertEqual(dictionary["command"] as? [Int], [27, 116, 50])

        let disconnected = service.run("disconnectPrinter", [target()])
        guard case .success(nil) = disconnected else { return XCTFail("\(disconnected)") }
    }
}

final class CommandContractTests: XCTestCase {
    func testMissingTypeIsAStringError() {
        let result = ThermalPrinterService().run("printFormattedText", [["id": "x", "text": "[L]x"]])
        guard case .error(let payload) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(payload as? String, "No value for type")
    }

    func testUnknownPrinterUsesTheAndroidNotFoundShape() {
        let result = ThermalPrinterService().run("printFormattedText", [["type": "usb", "id": "1234", "text": "[L]x"]])
        guard case .error(let payload) = result else { return XCTFail("\(result)") }
        let dictionary = payload as? [String: String]
        XCTAssertEqual(dictionary, ["error": "Device not found or not connected!", "type": "usb", "id": "1234"])
    }

    func testUsbListIsEmpty() {
        let result = ThermalPrinterService().run("listPrinters", [["type": "usb"]])
        guard case .success(let value) = result else { return XCTFail("\(result)") }
        XCTAssertEqual((value as? [[String: Any]])?.count, 0)
    }

    func testNumericIdIsCoercedLikeAndroid() {
        let result = ThermalPrinterService().run("requestPermissions", [["type": "usb", "id": 7]])
        guard case .error(let payload) = result else { return XCTFail("\(result)") }
        XCTAssertEqual((payload as? [String: String])?["id"], "7")
    }

    func testBadBase64IsAnError() {
        let result = ThermalPrinterService().run("bitmapToHexadecimalString", [["type": "tcp", "id": "x", "address": "127.0.0.1", "base64": "data:image/png;base64,@@@@@"]])
        XCTAssertEqual(errorMessage(result), "bad base-64")
    }

    func testArgumentsFollowOrgJsonCoercion() {
        let arguments = ThermalPrinterArguments([
            "int": 72.9,
            "string": "58",
            "bool": true,
            "null": NSNull(),
        ])
        XCTAssertEqual(arguments.optInt("int", 0), 72)
        XCTAssertEqual(arguments.optInt("string", 0), 58)
        XCTAssertEqual(arguments.optInt("bool", 5), 5)
        XCTAssertEqual(arguments.optInt("missing", 32), 32)
        XCTAssertEqual(arguments.optString("bool"), "true")
        XCTAssertEqual(try arguments.getString("null"), "null")
        XCTAssertEqual(arguments.optDouble("string", 0), 58)
        XCTAssertTrue(arguments.has("null"))
    }
}
