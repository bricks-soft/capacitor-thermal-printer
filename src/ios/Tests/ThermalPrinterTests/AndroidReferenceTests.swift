import CoreImage
import Foundation
@testable import ThermalPrinter
import XCTest

final class AndroidReferenceTests: XCTestCase {
    func testEveryReferenceCaseMatchesAndroid() throws {
        let cases = try Fixtures.referenceCases()
        XCTAssertGreaterThanOrEqual(cases.count, 40)
        for referenceCase in cases {
            try check(referenceCase)
        }
    }

    func testAppReceiptMatchesAndroidByteForByte() throws {
        let referenceCase = try Fixtures.referenceCase("app receipt 72mm (Bricks print path)")
        let connection = CaptureConnection()
        let printer = try ThermalPrinterService().makePrinter(connection: connection, data: ThermalPrinterArguments(referenceCase.data))
        let hexImages = try referenceCase.images.map { name -> String in
            let bitmap = try XCTUnwrap(EscPosBitmap.decode(try Fixtures.image(name)))
            return PrinterTextParserImg.bitmapToHexadecimalString(printer, bitmap)
        }
        try printer.printFormattedText(Fixtures.appReceiptText(hexImages: hexImages), dotsFeedPaper: 1)
        XCTAssertEqual(EscPosHex.string(connection.all), referenceCase.expectedBytes)
        XCTAssertEqual(connection.sends.count, 5)
        XCTAssertEqual(connection.sends.first?.hex, "1b40" + hexImages[0])
        XCTAssertEqual(connection.sends.last, CaptureConnection.Send(hex: "1b4a01", wait: 1))
    }

    private func check(_ referenceCase: ReferenceCase, file: StaticString = #filePath, line: UInt = #line) throws {
        let name = referenceCase.name
        let service = ThermalPrinterService()
        let data = ThermalPrinterArguments(referenceCase.data)
        let connection = CaptureConnection()
        let printer: EscPosPrinter
        do {
            printer = try service.makePrinter(connection: connection, data: data)
        } catch let failure as ThermalPrinterFailure {
            let message = (failure.payload as? [String: Any])?["error"] as? String
            XCTAssertEqual(message, referenceCase.expectedError, name, file: file, line: line)
            return
        }

        switch referenceCase.action {
        case "bitmapToHexadecimalString":
            let bitmap = try XCTUnwrap(EscPosBitmap.decode(try Fixtures.image(XCTUnwrap(referenceCase.image))), name)
            let hex = PrinterTextParserImg.bitmapToHexadecimalString(printer, bitmap)
            let expected = try XCTUnwrap(referenceCase.expectedResult as? String, name)
            if referenceCase.compare == "header" {
                XCTAssertEqual(String(hex.prefix(16)), String(expected.prefix(16)), name, file: file, line: line)
                XCTAssertEqual(hex.count, expected.count, name, file: file, line: line)
            } else {
                XCTAssertEqual(hex, expected, name, file: file, line: line)
            }
            return
        case "getEncoding":
            guard case .success(let value) = service.encodingResult(printer), let result = value as? [String: Any] else {
                return XCTFail("\(name): no encoding", file: file, line: line)
            }
            let expected = try XCTUnwrap(referenceCase.expectedResult as? [String: Any], name)
            XCTAssertEqual(result["name"] as? String, expected["name"] as? String, name, file: file, line: line)
            XCTAssertEqual(result["command"] as? [Int], (expected["command"] as? [NSNumber])?.map(\.intValue), name, file: file, line: line)
            return
        case "receipt":
            let hexImages = try referenceCase.images.map { image -> String in
                let bitmap = try XCTUnwrap(EscPosBitmap.decode(try Fixtures.image(image)), name)
                return PrinterTextParserImg.bitmapToHexadecimalString(printer, bitmap)
            }
            try printer.printFormattedText(Fixtures.appReceiptText(hexImages: hexImages), dotsFeedPaper: data.optInt("dotsFeedPaper", 20))
        default:
            do {
                _ = try service.printFormattedText(referenceCase.action, data, printer: printer)
            } catch let failure as ThermalPrinterFailure {
                XCTAssertEqual(errorMessage(.error(failure.payload)), referenceCase.expectedError, name, file: file, line: line)
                XCTAssertEqual(EscPosHex.string(connection.all), referenceCase.expectedBytes, name, file: file, line: line)
                XCTAssertEqual(connection.sends, referenceCase.expectedSends, name, file: file, line: line)
                return
            }
        }
        compareOutput(referenceCase, connection: connection, file: file, line: line)
    }

    private func compareOutput(_ referenceCase: ReferenceCase, connection: CaptureConnection, file: StaticString, line: UInt) {
        let name = referenceCase.name
        XCTAssertNil(referenceCase.expectedError, "\(name): Android failed with \(referenceCase.expectedError ?? "")", file: file, line: line)
        if referenceCase.compare == "qrcode" {
            XCTAssertEqual(connection.sends.count, referenceCase.expectedSends.count, name, file: file, line: line)
            let text = referenceCase.data["text"] as? String ?? ""
            let payload = text.components(separatedBy: ">").dropFirst().first?.components(separatedBy: "<").first ?? ""
            let mine = connection.sends.first.map { QRCodeReader.read(rasterHex: $0.hex) } ?? nil
            let android = referenceCase.expectedSends.first.map { QRCodeReader.read(rasterHex: $0.hex) } ?? nil
            XCTAssertEqual(mine, payload, "\(name): the iOS QR code scans back to its payload", file: file, line: line)
            XCTAssertEqual(android, payload, "\(name): the Android QR code scans back to its payload", file: file, line: line)
            return
        }
        XCTAssertEqual(EscPosHex.string(connection.all), referenceCase.expectedBytes, name, file: file, line: line)
        XCTAssertEqual(connection.pendingHex, referenceCase.expectedPending, name, file: file, line: line)
        XCTAssertEqual(connection.sends, referenceCase.expectedSends, name, file: file, line: line)
    }
}

extension AndroidReferenceTests {
    func testErrorCasesReportTheAndroidMessage() throws {
        for referenceCase in try Fixtures.referenceCases() where referenceCase.expectedError != nil && referenceCase.action.hasPrefix("printFormattedText") {
            let connection = CaptureConnection()
            let service = ThermalPrinterService()
            let data = ThermalPrinterArguments(referenceCase.data)
            let result: ThermalPrinterResult
            do {
                let printer = try service.makePrinter(connection: connection, data: data)
                result = try service.printFormattedText(referenceCase.action, data, printer: printer)
            } catch let failure as ThermalPrinterFailure {
                result = .error(failure.payload)
            }
            XCTAssertEqual(errorMessage(result), referenceCase.expectedError, referenceCase.name)
            guard case .error(let payload) = result else { continue }
            XCTAssertNotNil(payload as? [String: Any], "\(referenceCase.name): Android reports {error} objects for print failures")
        }
    }
}

enum QRCodeReader {
    static func read(rasterHex: String) -> String? {
        var hex = rasterHex
        if hex.hasPrefix("1b40") {
            hex.removeFirst(4)
        }
        guard let raster = try? EscPosHex.bytes(JavaString(hex)), raster.count > 8, raster[0] == 0x1D, raster[1] == 0x76 else {
            return nil
        }
        let bytesByLine = Int(raster[4]) + Int(raster[5]) * 256
        let height = Int(raster[6]) + Int(raster[7]) * 256
        let width = bytesByLine * 8
        let border = 40
        let canvasWidth = width + 2 * border
        let canvasHeight = height + 2 * border
        var gray = [UInt8](repeating: 255, count: canvasWidth * canvasHeight)
        for y in 0..<height {
            for x in 0..<width where raster[8 + y * bytesByLine + x / 8] & (0x80 >> UInt8(x % 8)) != 0 {
                gray[(y + border) * canvasWidth + x + border] = 0
            }
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData),
              let image = CGImage(width: canvasWidth, height: canvasHeight, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: canvasWidth, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        else {
            return nil
        }
        return (detector.features(in: CIImage(cgImage: image)).first as? CIQRCodeFeature)?.messageString
    }
}
