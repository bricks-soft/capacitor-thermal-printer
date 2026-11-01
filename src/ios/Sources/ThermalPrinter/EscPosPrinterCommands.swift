import Foundation

final class EscPosPrinterCommands {
    static let lineFeed: UInt8 = 0x0A

    static let resetPrinter: [UInt8] = [0x1B, 0x40]

    static let textAlignLeft: [UInt8] = [0x1B, 0x61, 0x00]
    static let textAlignCenter: [UInt8] = [0x1B, 0x61, 0x01]
    static let textAlignRight: [UInt8] = [0x1B, 0x61, 0x02]

    static let textWeightNormal: [UInt8] = [0x1B, 0x45, 0x00]
    static let textWeightBold: [UInt8] = [0x1B, 0x45, 0x01]

    static let lineSpacing24: [UInt8] = [0x1B, 0x33, 0x18]
    static let lineSpacing30: [UInt8] = [0x1B, 0x33, 0x1E]

    static let textSizeNormal: [UInt8] = [0x1D, 0x21, 0x00]
    static let textSizeDoubleHeight: [UInt8] = [0x1D, 0x21, 0x01]
    static let textSizeDoubleWidth: [UInt8] = [0x1D, 0x21, 0x10]
    static let textSizeBig: [UInt8] = [0x1D, 0x21, 0x11]
    static let textSizeBig2: [UInt8] = [0x1D, 0x21, 0x22]
    static let textSizeBig3: [UInt8] = [0x1D, 0x21, 0x33]
    static let textSizeBig4: [UInt8] = [0x1D, 0x21, 0x44]
    static let textSizeBig5: [UInt8] = [0x1D, 0x21, 0x55]
    static let textSizeBig6: [UInt8] = [0x1D, 0x21, 0x66]

    static let textUnderlineOff: [UInt8] = [0x1B, 0x2D, 0x00]
    static let textUnderlineOn: [UInt8] = [0x1B, 0x2D, 0x01]
    static let textUnderlineLarge: [UInt8] = [0x1B, 0x2D, 0x02]

    static let textDoubleStrikeOff: [UInt8] = [0x1B, 0x47, 0x00]
    static let textDoubleStrikeOn: [UInt8] = [0x1B, 0x47, 0x01]

    static let textColorBlack: [UInt8] = [0x1B, 0x72, 0x00]
    static let textColorRed: [UInt8] = [0x1B, 0x72, 0x01]

    static let textColorReverseOff: [UInt8] = [0x1D, 0x42, 0x00]
    static let textColorReverseOn: [UInt8] = [0x1D, 0x42, 0x01]

    static let barcodeTypeUPCA = 65
    static let barcodeTypeUPCE = 66
    static let barcodeTypeEAN13 = 67
    static let barcodeTypeEAN8 = 68
    static let barcodeTypeITF = 70
    static let barcodeType128 = 73

    static let barcodeTextPositionNone = 0
    static let barcodeTextPositionAbove = 1
    static let barcodeTextPositionBelow = 2

    let printerConnection: EscPosDeviceConnection
    let charsetEncoding: EscPosCharsetEncoding
    var useEscAsteriskCommand = false

    private var currentTextSize: [UInt8] = []
    private var currentTextColor: [UInt8] = []
    private var currentTextReverseColor: [UInt8] = []
    private var currentTextBold: [UInt8] = []
    private var currentTextUnderline: [UInt8] = []
    private var currentTextDoubleStrike: [UInt8] = []

    init(printerConnection: EscPosDeviceConnection, charsetEncoding: EscPosCharsetEncoding? = nil) {
        self.printerConnection = printerConnection
        self.charsetEncoding = charsetEncoding ?? EscPosCharsetEncoding(name: "windows-1252", escPosCharsetId: 6)
    }

    static func initGSv0Command(bytesByLine: Int, bitmapHeight: Int) -> [UInt8] {
        let xH = bytesByLine / 256
        let xL = bytesByLine - xH * 256
        let yH = bitmapHeight / 256
        let yL = bitmapHeight - yH * 256
        var imageBytes = [UInt8](repeating: 0, count: 8 + bytesByLine * bitmapHeight)
        imageBytes[0] = 0x1D
        imageBytes[1] = 0x76
        imageBytes[2] = 0x30
        imageBytes[3] = 0x00
        imageBytes[4] = UInt8(truncatingIfNeeded: xL)
        imageBytes[5] = UInt8(truncatingIfNeeded: xH)
        imageBytes[6] = UInt8(truncatingIfNeeded: yL)
        imageBytes[7] = UInt8(truncatingIfNeeded: yH)
        return imageBytes
    }

    static func bitmapToBytes(_ bitmap: EscPosBitmap) -> [UInt8] {
        let bitmapWidth = bitmap.width
        let bitmapHeight = bitmap.height
        let bytesByLine = Int((Float(bitmapWidth) / 8).rounded(.up))
        var imageBytes = initGSv0Command(bytesByLine: bytesByLine, bitmapHeight: bitmapHeight)

        var index = 8
        var greyscaleCoefficientInit = 0
        let gradientStep = 6
        let colorLevelStep = 765.0 / Double(15 * gradientStep + gradientStep - 1)

        for posY in 0..<bitmapHeight {
            var greyscaleCoefficient = greyscaleCoefficientInit
            let greyscaleLine = posY % gradientStep
            var column = 0
            while column < bitmapWidth {
                var byte = 0
                for bit in 0..<8 {
                    let posX = column + bit
                    if posX < bitmapWidth {
                        let color = bitmap.pixel(posX, posY)
                        let red = Int((color >> 16) & 255)
                        let green = Int((color >> 8) & 255)
                        let blue = Int(color & 255)
                        if Double(red + green + blue) < Double(greyscaleCoefficient * gradientStep + greyscaleLine) * colorLevelStep {
                            byte |= 1 << (7 - bit)
                        }
                        greyscaleCoefficient += 5
                        if greyscaleCoefficient > 15 {
                            greyscaleCoefficient -= 16
                        }
                    }
                }
                imageBytes[index] = UInt8(truncatingIfNeeded: byte)
                index += 1
                column += 8
            }
            greyscaleCoefficientInit += 2
            if greyscaleCoefficientInit > 15 {
                greyscaleCoefficientInit = 0
            }
        }
        return imageBytes
    }

    static func convertGSv0ToEscAsterisk(_ bytes: [UInt8]) -> [[UInt8]] {
        let xL = Int(bytes[4])
        let xH = Int(bytes[5])
        let yL = Int(bytes[6])
        let yH = Int(bytes[7])
        let bytesByLine = xH * 256 + xL
        let dotsByLine = bytesByLine * 8
        let nH = dotsByLine / 256
        let nL = dotsByLine % 256
        let imageHeight = yH * 256 + yL
        let imageLineHeightCount = Int((Double(imageHeight) / 24.0).rounded(.up))
        let imageBytesSize = 6 + bytesByLine * 24

        var returnedBytes: [[UInt8]] = [lineSpacing24]
        for lineIndex in 0..<imageLineHeightCount {
            let pxBaseRow = lineIndex * 24
            var imageBytes = [UInt8](repeating: 0, count: imageBytesSize)
            imageBytes[0] = 0x1B
            imageBytes[1] = 0x2A
            imageBytes[2] = 0x21
            imageBytes[3] = UInt8(truncatingIfNeeded: nL)
            imageBytes[4] = UInt8(truncatingIfNeeded: nH)
            for byteIndex in 5..<imageBytes.count {
                let imgByte = byteIndex - 5
                let byteRow = imgByte % 3
                let pxColumn = imgByte / 3
                let bitColumn = 1 << (7 - pxColumn % 8)
                let pxRow = pxBaseRow + byteRow * 8
                for bit in 0..<8 {
                    let indexBytes = bytesByLine * (pxRow + bit) + pxColumn / 8 + 8
                    if indexBytes >= bytes.count {
                        break
                    }
                    let isBlack = (Int(bytes[indexBytes]) & bitColumn) == bitColumn
                    if isBlack {
                        imageBytes[byteIndex] |= UInt8(truncatingIfNeeded: 1 << (7 - bit))
                    }
                }
            }
            imageBytes[imageBytes.count - 1] = lineFeed
            returnedBytes.append(imageBytes)
        }
        returnedBytes.append(lineSpacing30)
        return returnedBytes
    }

    static func qrCodeDataToBytes(_ data: String, size: Int) throws -> [UInt8] {
        let matrix = try EscPosQRCode.matrix(for: data)
        let width = matrix.count
        let height = matrix.count
        guard width > 0 else {
            return initGSv0Command(bytesByLine: 0, bitmapHeight: 0)
        }
        let coefficient = JavaMath.round(Float(size) / Float(width))
        let imageWidth = width * coefficient
        let imageHeight = height * coefficient
        let bytesByLine = Int((Float(imageWidth) / 8).rounded(.up))

        if coefficient < 1 {
            return initGSv0Command(bytesByLine: 0, bitmapHeight: 0)
        }

        var imageBytes = initGSv0Command(bytesByLine: bytesByLine, bitmapHeight: imageHeight)
        var index = 8
        for y in 0..<height {
            var lineBytes = [UInt8](repeating: 0, count: bytesByLine)
            var x = -1
            var multipleX = coefficient
            var isBlack = false
            for byteIndex in 0..<bytesByLine {
                var byte = 0
                for bit in 0..<8 {
                    if multipleX == coefficient {
                        x += 1
                        isBlack = x < width && matrix[y][x]
                        multipleX = 0
                    }
                    if isBlack {
                        byte |= 1 << (7 - bit)
                    }
                    multipleX += 1
                }
                lineBytes[byteIndex] = UInt8(truncatingIfNeeded: byte)
            }
            for _ in 0..<coefficient {
                imageBytes.replaceSubrange(index..<(index + lineBytes.count), with: lineBytes)
                index += lineBytes.count
            }
        }
        return imageBytes
    }

    @discardableResult
    func connect() throws -> EscPosPrinterCommands {
        try printerConnection.connect()
        return self
    }

    func disconnect() {
        printerConnection.disconnect()
    }

    @discardableResult
    func reset() -> EscPosPrinterCommands {
        guard printerConnection.isConnected else { return self }
        printerConnection.write(EscPosPrinterCommands.resetPrinter)
        return self
    }

    @discardableResult
    func setAlign(_ align: [UInt8]) -> EscPosPrinterCommands {
        guard printerConnection.isConnected else { return self }
        printerConnection.write(align)
        return self
    }

    @discardableResult
    func printText(
        _ text: JavaString,
        textSize: [UInt8]? = nil,
        textColor: [UInt8]? = nil,
        textReverseColor: [UInt8]? = nil,
        textBold: [UInt8]? = nil,
        textUnderline: [UInt8]? = nil,
        textDoubleStrike: [UInt8]? = nil
    ) throws -> EscPosPrinterCommands {
        guard printerConnection.isConnected else { return self }

        let size = textSize ?? EscPosPrinterCommands.textSizeNormal
        let color = textColor ?? EscPosPrinterCommands.textColorBlack
        let reverseColor = textReverseColor ?? EscPosPrinterCommands.textColorReverseOff
        let bold = textBold ?? EscPosPrinterCommands.textWeightNormal
        let underline = textUnderline ?? EscPosPrinterCommands.textUnderlineOff
        let doubleStrike = textDoubleStrike ?? EscPosPrinterCommands.textDoubleStrikeOff

        let textBytes = try charsetEncoding.encode(text)
        printerConnection.write(charsetEncoding.command)

        if currentTextSize != size {
            printerConnection.write(size)
            currentTextSize = size
        }
        if currentTextDoubleStrike != doubleStrike {
            printerConnection.write(doubleStrike)
            currentTextDoubleStrike = doubleStrike
        }
        if currentTextUnderline != underline {
            printerConnection.write(underline)
            currentTextUnderline = underline
        }
        if currentTextBold != bold {
            printerConnection.write(bold)
            currentTextBold = bold
        }
        if currentTextColor != color {
            printerConnection.write(color)
            currentTextColor = color
        }
        if currentTextReverseColor != reverseColor {
            printerConnection.write(reverseColor)
            currentTextReverseColor = reverseColor
        }

        printerConnection.write(textBytes)
        return self
    }

    @discardableResult
    func printImage(_ image: [UInt8]) throws -> EscPosPrinterCommands {
        guard printerConnection.isConnected else { return self }
        let bytesToPrint = useEscAsteriskCommand ? EscPosPrinterCommands.convertGSv0ToEscAsterisk(image) : [image]
        for bytes in bytesToPrint {
            printerConnection.write(bytes)
            try printerConnection.send()
        }
        return self
    }

    @discardableResult
    func printBarcode(_ barcode: EscPosBarcode) -> EscPosPrinterCommands {
        guard printerConnection.isConnected else { return self }
        let code = barcode.code
        let barcodeLength = barcode.codeLength
        var barcodeCommand: [UInt8] = [0x1D, 0x6B, UInt8(truncatingIfNeeded: barcode.barcodeType), UInt8(truncatingIfNeeded: barcodeLength)]
        for index in 0..<barcodeLength {
            barcodeCommand.append(UInt8(truncatingIfNeeded: code.units[index]))
        }
        printerConnection.write([0x1D, 0x48, UInt8(truncatingIfNeeded: barcode.textPosition)])
        printerConnection.write([0x1D, 0x77, UInt8(truncatingIfNeeded: barcode.colWidth)])
        printerConnection.write([0x1D, 0x68, UInt8(truncatingIfNeeded: barcode.height)])
        printerConnection.write(barcodeCommand)
        return self
    }

    @discardableResult
    func newLine(_ align: [UInt8]? = nil) throws -> EscPosPrinterCommands {
        guard printerConnection.isConnected else { return self }
        printerConnection.write([EscPosPrinterCommands.lineFeed])
        try printerConnection.send()
        if let align = align {
            printerConnection.write(align)
        }
        return self
    }

    @discardableResult
    func feedPaper(_ dots: Int) throws -> EscPosPrinterCommands {
        guard printerConnection.isConnected else { return self }
        if dots > 0 {
            printerConnection.write([0x1B, 0x4A, UInt8(truncatingIfNeeded: dots)])
            try printerConnection.send(dots)
        }
        return self
    }

    @discardableResult
    func cutPaper() throws -> EscPosPrinterCommands {
        guard printerConnection.isConnected else { return self }
        printerConnection.write([0x1D, 0x56, 0x01])
        try printerConnection.send(100)
        return self
    }

    @discardableResult
    func openCashBox() throws -> EscPosPrinterCommands {
        guard printerConnection.isConnected else { return self }
        printerConnection.write([0x1B, 0x70, 0x00, 0x3C, 0xFF])
        try printerConnection.send(100)
        return self
    }
}
