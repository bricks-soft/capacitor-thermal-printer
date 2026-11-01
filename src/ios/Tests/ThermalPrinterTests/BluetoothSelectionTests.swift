import CoreBluetooth
@testable import ThermalPrinter
import XCTest

final class BluetoothSelectionTests: XCTestCase {
    private func service(_ uuid: String, _ characteristics: [(String, CBCharacteristicProperties)]) -> CBMutableService {
        let service = CBMutableService(type: CBUUID(string: uuid), primary: true)
        service.characteristics = characteristics.map { uuid, properties in
            CBMutableCharacteristic(type: CBUUID(string: uuid), properties: properties, value: nil, permissions: [.writeable])
        }
        return service
    }

    func testPrefersTheKnownPrinterCharacteristic() throws {
        let services = [
            service("180A", [("2A29", [.read])]),
            service("FFF0", [("FFF1", [.write])]),
            service("18F0", [("2AF0", [.notify]), ("2AF1", [.write, .writeWithoutResponse])]),
        ]
        let (characteristic, type) = try XCTUnwrap(EscPosBluetoothConnection.selectCharacteristic(in: services))
        XCTAssertEqual(characteristic.uuid, CBUUID(string: "2AF1"))
        XCTAssertEqual(type, .withoutResponse)
    }

    func testFallsBackToAWritableCharacteristicInAPrinterService() throws {
        let services = [service("E7810A71-73AE-499D-8C15-FAA9AEF0C3F2", [("BEF8D6C9-9C21-4C9E-B632-BD58C1009F9E", [.write])])]
        let (characteristic, type) = try XCTUnwrap(EscPosBluetoothConnection.selectCharacteristic(in: services))
        XCTAssertEqual(characteristic.uuid, CBUUID(string: "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9E"))
        XCTAssertEqual(type, .withResponse)
    }

    func testUsesAnyVendorServiceButNotStandardOnes() throws {
        let vendor = [service("1800", [("2A00", [.write])]), service("ABCD", [("ABCE", [.writeWithoutResponse])])]
        XCTAssertEqual(try XCTUnwrap(EscPosBluetoothConnection.selectCharacteristic(in: vendor)).0.uuid, CBUUID(string: "ABCE"))

        let standardOnly = [service("1800", [("2A00", [.write])]), service("180A", [("2A29", [.read])])]
        XCTAssertNil(EscPosBluetoothConnection.selectCharacteristic(in: standardOnly))
    }
}

final class JavaCompatTests: XCTestCase {
    func testSplitLinesFollowsJavaStringSplit() {
        XCTAssertEqual(JavaString.splitLines(JavaString("")).map(\.string), [""])
        XCTAssertEqual(JavaString.splitLines(JavaString("\n\n")).map(\.string), [])
        XCTAssertEqual(JavaString.splitLines(JavaString("\na\r\nb\rc\n\n")).map(\.string), ["", "a", "b\rc"])
    }

    func testTrimOnlyRemovesControlAndSpace() {
        XCTAssertEqual(JavaString("\u{00A0} x \t\n").trim().string, "\u{00A0} x")
    }

    func testJavaRounding() {
        XCTAssertEqual(JavaMath.round(Float(2.5)), 3)
        XCTAssertEqual(JavaMath.round(Float(-2.5)), -2)
        XCTAssertEqual(JavaMath.round(Float(575.43)), 575)
        XCTAssertEqual(EscPosPrinterSize.mmToPx(72, dpi: 203), 575)
        XCTAssertEqual(EscPosPrinterSize.mmToPx(48, dpi: 203), 384)
    }

    func testPrinterWidthKeepsDantSuRounding() throws {
        let size = try EscPosPrinterSize(printerDpi: 203, printerWidthMM: 72, printerNbrCharactersPerLine: 32)
        XCTAssertEqual(size.printerWidthPx, 582)
        XCTAssertEqual(size.printerCharSizeWidthPx, 17)
    }

    func testUnmappableCharactersBecomeQuestionMarks() throws {
        let encoding = EscPosCharsetEncoding(name: "windows-1252", escPosCharsetId: 16)
        XCTAssertEqual(try encoding.encode(JavaString("é🧾ب")), [0xE9, 0x3F, 0x3F])
        XCTAssertThrowsError(try EscPosCharsetEncoding(name: "nope", escPosCharsetId: 0).encode(JavaString("x")))
    }

    func testJavaCharsetAliases() throws {
        XCTAssertEqual(try EscPosCharsetEncoding.stringEncoding(for: "Cp1256"), try EscPosCharsetEncoding.stringEncoding(for: "windows-1256"))
        XCTAssertEqual(try EscPosCharsetEncoding.stringEncoding(for: "UTF8"), .utf8)
    }
}
