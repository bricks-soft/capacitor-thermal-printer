import Foundation

class EscPosPrinterSize {
    static let inchToMM: Float = 25.4

    let printerDpi: Int
    let printerWidthMM: Float
    let printerNbrCharactersPerLine: Int
    let printerWidthPx: Int
    let printerCharSizeWidthPx: Int

    init(printerDpi: Int, printerWidthMM: Float, printerNbrCharactersPerLine: Int) throws {
        self.printerDpi = printerDpi
        self.printerWidthMM = printerWidthMM
        self.printerNbrCharactersPerLine = printerNbrCharactersPerLine
        let printingWidthPx = EscPosPrinterSize.mmToPx(printerWidthMM, dpi: printerDpi)
        self.printerWidthPx = printingWidthPx + (printingWidthPx % 8)
        guard printerNbrCharactersPerLine != 0 else {
            throw EscPosError.runtime("/ by zero")
        }
        self.printerCharSizeWidthPx = printingWidthPx / printerNbrCharactersPerLine
    }

    func mmToPx(_ mmSize: Float) -> Int {
        EscPosPrinterSize.mmToPx(mmSize, dpi: printerDpi)
    }

    static func mmToPx(_ mmSize: Float, dpi: Int) -> Int {
        JavaMath.round(mmSize * Float(dpi) / inchToMM)
    }

    func bitmapToBytes(_ bitmap: EscPosBitmap) -> [UInt8] {
        var isSizeEdit = false
        var bitmapWidth = bitmap.width
        var bitmapHeight = bitmap.height
        let maxWidth = printerWidthPx
        let maxHeight = 256

        if bitmapWidth > maxWidth {
            bitmapHeight = JavaMath.round(Float(bitmapHeight) * Float(maxWidth) / Float(bitmapWidth))
            bitmapWidth = maxWidth
            isSizeEdit = true
        }
        if bitmapHeight > maxHeight {
            bitmapWidth = JavaMath.round(Float(bitmapWidth) * Float(maxHeight) / Float(bitmapHeight))
            bitmapHeight = maxHeight
            isSizeEdit = true
        }

        let source = isSizeEdit ? bitmap.scaled(width: bitmapWidth, height: bitmapHeight) : bitmap
        return EscPosPrinterCommands.bitmapToBytes(source)
    }
}
