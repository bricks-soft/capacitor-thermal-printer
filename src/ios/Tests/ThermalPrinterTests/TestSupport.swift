import Foundation
@testable import ThermalPrinter
import XCTest

final class CaptureConnection: EscPosDeviceConnection {
    struct Send: Equatable {
        let hex: String
        let wait: Int
    }

    private(set) var sends: [Send] = []
    private(set) var all: [UInt8] = []
    private var connected = false

    override init() {
        super.init()
        pacesSends = false
    }

    override var isConnected: Bool { connected }

    @discardableResult
    override func connect() throws -> EscPosDeviceConnection {
        connected = true
        clearBuffer()
        return self
    }

    @discardableResult
    override func disconnect() -> EscPosDeviceConnection {
        connected = false
        return super.disconnect()
    }

    override func send(_ addWaitingTime: Int = 0) throws {
        let pending = data
        try super.send(addWaitingTime)
        sends.append(Send(hex: EscPosHex.string(pending), wait: addWaitingTime + pending.count / 16))
    }

    override func transmit(_ bytes: [UInt8]) throws {
        all.append(contentsOf: bytes)
    }

    var pendingHex: String { EscPosHex.string(data) }
}

struct ReferenceCase {
    let name: String
    let action: String
    let compare: String
    let data: [String: Any]
    let images: [String]
    let image: String?
    let expected: [String: Any]

    var expectedError: String? { (expected["error"] as? [String: Any])?["error"] as? String }
    var expectedBytes: String? { expected["bytes"] as? String }
    var expectedPending: String? { expected["pending"] as? String }
    var expectedResult: Any? { expected["result"] }

    var expectedSends: [CaptureConnection.Send] {
        (expected["sends"] as? [[String: Any]] ?? []).map {
            CaptureConnection.Send(hex: $0["hex"] as? String ?? "", wait: ($0["wait"] as? NSNumber)?.intValue ?? -1)
        }
    }
}

enum Fixtures {
    static var directory: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    }

    static func image(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("images").appendingPathComponent(name))
    }

    static func dataURL(_ name: String) throws -> String {
        "data:image/png;base64," + (try image(name)).base64EncodedString()
    }

    static func referenceCases() throws -> [ReferenceCase] {
        let data = try Data(contentsOf: directory.appendingPathComponent("android-reference.json"))
        let list = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return list.map { item in
            ReferenceCase(
                name: item["name"] as? String ?? "",
                action: item["action"] as? String ?? "",
                compare: item["compare"] as? String ?? "bytes",
                data: item["data"] as? [String: Any] ?? [:],
                images: item["images"] as? [String] ?? [],
                image: item["image"] as? String,
                expected: item["expected"] as? [String: Any] ?? [:]
            )
        }
    }

    static func referenceCase(_ name: String) throws -> ReferenceCase {
        try XCTUnwrap(try referenceCases().first { $0.name == name }, "missing reference case \(name)")
    }

    static func appReceiptText(hexImages: [String]) -> String {
        hexImages.map { "[C]<img>\($0)</img>" }.joined(separator: "\n") + "\n\n\n\n"
    }
}

func errorMessage(_ result: ThermalPrinterResult) -> String? {
    guard case .error(let payload) = result else { return nil }
    if let message = payload as? String { return message }
    return (payload as? [String: Any])?["error"] as? String
}
