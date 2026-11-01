import Foundation

class EscPosBarcode {
    let barcodeType: Int
    var code: JavaString
    let height: Int
    let textPosition: Int
    private(set) var colWidth = 0

    var codeLength: Int { code.length }
    var colsCount: Int { (codeLength + 5) * 11 }

    init(printerSize: EscPosPrinterSize, barcodeType: Int, code: JavaString, widthMM: Float, heightMM: Float, textPosition: Int) throws {
        self.barcodeType = barcodeType
        self.code = code
        self.height = printerSize.mmToPx(heightMM)
        self.textPosition = textPosition
    }

    func computeColWidth(printerSize: EscPosPrinterSize, widthMM requestedWidthMM: Float) throws {
        var widthMM = requestedWidthMM
        if widthMM == 0 {
            widthMM = printerSize.printerWidthMM * 0.7
        }
        let wantedPxWidth = widthMM > printerSize.printerWidthMM ? printerSize.printerWidthPx : printerSize.mmToPx(widthMM)
        var width = JavaMath.round(Double(wantedPxWidth) / Double(colsCount))
        if width * colsCount > printerSize.printerWidthPx {
            width -= 1
        }
        if width == 0 {
            throw EscPosError.barcode("Barcode is too long for the paper size.")
        }
        colWidth = width
    }

    static func make(type: String, printerSize: EscPosPrinterSize, code: JavaString, widthMM: Float, heightMM: Float, textPosition: Int) throws -> EscPosBarcode {
        let barcode: EscPosBarcode
        switch type {
        case "ean8":
            barcode = try EscPosBarcodeNumber(printerSize: printerSize, barcodeType: EscPosPrinterCommands.barcodeTypeEAN8, code: code, widthMM: widthMM, heightMM: heightMM, textPosition: textPosition, fixedLength: 8)
        case "ean13":
            barcode = try EscPosBarcodeNumber(printerSize: printerSize, barcodeType: EscPosPrinterCommands.barcodeTypeEAN13, code: code, widthMM: widthMM, heightMM: heightMM, textPosition: textPosition, fixedLength: 13)
        case "upca":
            barcode = try EscPosBarcodeNumber(printerSize: printerSize, barcodeType: EscPosPrinterCommands.barcodeTypeUPCA, code: code, widthMM: widthMM, heightMM: heightMM, textPosition: textPosition, fixedLength: 12)
        case "upce":
            barcode = try EscPosBarcodeUPCE(printerSize: printerSize, code: code, widthMM: widthMM, heightMM: heightMM, textPosition: textPosition)
        case "128":
            barcode = try EscPosBarcode(printerSize: printerSize, barcodeType: EscPosPrinterCommands.barcodeType128, code: code, widthMM: widthMM, heightMM: heightMM, textPosition: textPosition)
            try barcode.computeColWidth(printerSize: printerSize, widthMM: widthMM)
        default:
            throw EscPosError.parser("Invalid barcode attribute : type")
        }
        return barcode
    }
}

final class EscPosBarcodeNumber: EscPosBarcode {
    private let fixedLength: Int

    override var codeLength: Int { fixedLength }
    override var colsCount: Int { codeLength * 7 + 11 }

    init(printerSize: EscPosPrinterSize, barcodeType: Int, code: JavaString, widthMM: Float, heightMM: Float, textPosition: Int, fixedLength: Int) throws {
        self.fixedLength = fixedLength
        try super.init(printerSize: printerSize, barcodeType: barcodeType, code: code, widthMM: widthMM, heightMM: heightMM, textPosition: textPosition)
        try computeColWidth(printerSize: printerSize, widthMM: widthMM)
        try checkCode()
    }

    private func checkCode() throws {
        let checkedLength = codeLength - 1
        if code.length < checkedLength {
            throw EscPosError.barcode("Code is too short for the barcode type.")
        }
        let digits = try code.substring(0, checkedLength)
        var total = 0
        for index in 0..<checkedLength {
            let position = checkedLength - 1 - index
            guard let digit = EscPosBarcodeNumber.digit(digits.units[position]) else {
                throw EscPosError.barcode("Invalid barcode number")
            }
            total += index % 2 == 0 ? 3 * digit : digit
        }
        var key = String(10 - (total % 10))
        if key.count == 2 {
            key = "0"
        }
        code = JavaString(digits.string + key)
    }

    static func digit(_ unit: UInt16) -> Int? {
        guard let scalar = Unicode.Scalar(unit),
              scalar.properties.generalCategory == .decimalNumber,
              let value = scalar.properties.numericValue
        else {
            return nil
        }
        return Int(value)
    }
}

final class EscPosBarcodeUPCE: EscPosBarcode {
    override var codeLength: Int { 6 }
    override var colsCount: Int { codeLength * 7 + 16 }

    init(printerSize: EscPosPrinterSize, code: JavaString, widthMM: Float, heightMM: Float, textPosition: Int) throws {
        try super.init(printerSize: printerSize, barcodeType: EscPosPrinterCommands.barcodeTypeUPCE, code: code, widthMM: widthMM, heightMM: heightMM, textPosition: textPosition)
        try computeColWidth(printerSize: printerSize, widthMM: widthMM)
        try checkCode()
    }

    private func checkCode() throws {
        if code.length < codeLength {
            throw EscPosError.barcode("Code is too short for the barcode type.")
        }
        code = try code.substring(0, codeLength)
        for unit in code.units where EscPosBarcodeNumber.digit(unit) == nil {
            throw EscPosError.barcode("Invalid barcode number")
        }
    }
}
