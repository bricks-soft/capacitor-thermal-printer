import Foundation

protocol PrinterTextParserElement: AnyObject {
    func length() throws -> Int
    func print(_ printerSocket: EscPosPrinterCommands) throws
}

final class PrinterTextParser {
    static let tagsAlignLeft = "L"
    static let tagsAlignCenter = "C"
    static let tagsAlignRight = "R"
    static let tagsAlign = [tagsAlignLeft, tagsAlignCenter, tagsAlignRight]

    static let tagsImage = "img"
    static let tagsBarcode = "barcode"
    static let tagsQRCode = "qrcode"

    static let attrBarcodeWidth = "width"
    static let attrBarcodeHeight = "height"
    static let attrBarcodeType = "type"
    static let attrBarcodeTypeEAN13 = "ean13"
    static let attrBarcodeTextPosition = "text"
    static let attrBarcodeTextPositionNone = "none"
    static let attrBarcodeTextPositionAbove = "above"

    static let tagsFormatTextFont = "font"
    static let tagsFormatTextBold = "b"
    static let tagsFormatTextUnderline = "u"
    static let tagsFormatText = [tagsFormatTextFont, tagsFormatTextBold, tagsFormatTextUnderline]

    static let attrFormatTextUnderlineType = "type"
    static let attrFormatTextUnderlineTypeNormal = "normal"
    static let attrFormatTextUnderlineTypeDouble = "double"

    static let attrFormatTextFontSize = "size"
    static let attrFormatTextFontColor = "color"

    static let attrQRCodeSize = "size"

    static func isTagTextFormat(_ name: JavaString) throws -> Bool {
        var tagName = name
        if try tagName.substring(0, 1) == "/" {
            tagName = try tagName.substring(1)
        }
        return tagsFormatText.contains { tagName == $0 }
    }

    let printer: EscPosPrinter
    private var textSize: [[UInt8]] = [EscPosPrinterCommands.textSizeNormal]
    private var textColor: [[UInt8]] = [EscPosPrinterCommands.textColorBlack]
    private var textReverseColor: [[UInt8]] = [EscPosPrinterCommands.textColorReverseOff]
    private var textBold: [[UInt8]] = [EscPosPrinterCommands.textWeightNormal]
    private var textUnderline: [[UInt8]] = [EscPosPrinterCommands.textUnderlineOff]
    private var textDoubleStrike: [[UInt8]] = [EscPosPrinterCommands.textDoubleStrikeOff]
    private var text = JavaString("")

    init(printer: EscPosPrinter) {
        self.printer = printer
    }

    @discardableResult
    func setFormattedText(_ text: JavaString) -> PrinterTextParser {
        self.text = text
        return self
    }

    var lastTextSize: [UInt8] { textSize[textSize.count - 1] }
    var lastTextColor: [UInt8] { textColor[textColor.count - 1] }
    var lastTextReverseColor: [UInt8] { textReverseColor[textReverseColor.count - 1] }
    var lastTextBold: [UInt8] { textBold[textBold.count - 1] }
    var lastTextUnderline: [UInt8] { textUnderline[textUnderline.count - 1] }
    var lastTextDoubleStrike: [UInt8] { textDoubleStrike[textDoubleStrike.count - 1] }

    func addTextSize(_ value: [UInt8]) { textSize.append(value) }
    func addTextColor(_ value: [UInt8]) { textColor.append(value) }
    func addTextReverseColor(_ value: [UInt8]) { textReverseColor.append(value) }
    func addTextBold(_ value: [UInt8]) { textBold.append(value) }
    func addTextUnderline(_ value: [UInt8]) { textUnderline.append(value) }
    func addTextDoubleStrike(_ value: [UInt8]) { textDoubleStrike.append(value) }

    func dropLastTextSize() { if textSize.count > 1 { textSize.removeLast() } }
    func dropLastTextColor() { if textColor.count > 1 { textColor.removeLast() } }
    func dropLastTextReverseColor() { if textReverseColor.count > 1 { textReverseColor.removeLast() } }
    func dropTextBold() { if textBold.count > 1 { textBold.removeLast() } }
    func dropLastTextUnderline() { if textUnderline.count > 1 { textUnderline.removeLast() } }
    func dropLastTextDoubleStrike() { if textDoubleStrike.count > 1 { textDoubleStrike.removeLast() } }

    func parse() throws -> [PrinterTextParserLine] {
        try JavaString.splitLines(text).map { try PrinterTextParserLine(textParser: self, textLine: $0) }
    }
}

final class PrinterTextParserLine {
    let textParser: PrinterTextParser
    let nbrColumns: Int
    var nbrCharColumn: Int
    var nbrCharForgetted: Int
    var nbrCharColumnExceeded: Int
    private(set) var columns: [PrinterTextParserColumn] = []

    init(textParser: PrinterTextParser, textLine: JavaString) throws {
        self.textParser = textParser
        let nbrCharactersPerLine = textParser.printer.printerNbrCharactersPerLine

        var columnsList: [JavaString] = []
        var lastPosition = 0
        for startPosition in PrinterTextParserLine.alignTagPositions(textLine) where startPosition > 0 {
            columnsList.append(try textLine.substring(lastPosition, startPosition))
            lastPosition = startPosition
        }
        columnsList.append(try textLine.substring(lastPosition))

        nbrColumns = columnsList.count
        nbrCharColumn = JavaMath.floorDiv(Float(nbrCharactersPerLine), Float(nbrColumns))
        nbrCharForgetted = nbrCharactersPerLine - nbrCharColumn * nbrColumns
        nbrCharColumnExceeded = 0

        for column in columnsList {
            columns.append(try PrinterTextParserColumn(textParserLine: self, textColumn: column))
        }
    }

    private static func alignTagPositions(_ line: JavaString) -> [Int] {
        let tags = PrinterTextParser.tagsAlign.map { Array("[\($0)]".utf16) }
        var positions: [Int] = []
        var index = 0
        let units = line.units
        while index + 3 <= units.count {
            if tags.contains(where: { units[index..<(index + 3)].elementsEqual($0) }) {
                positions.append(index)
                index += 3
            } else {
                index += 1
            }
        }
        return positions
    }
}

final class PrinterTextParserColumn {
    private static func generateSpace(_ count: Int) -> JavaString {
        JavaString(String(repeating: " ", count: max(0, count)))
    }

    unowned let textParserLine: PrinterTextParserLine
    private(set) var elements: [PrinterTextParserElement] = []

    init(textParserLine: PrinterTextParserLine, textColumn input: JavaString) throws {
        self.textParserLine = textParserLine
        let textParser = textParserLine.textParser
        var textAlign = PrinterTextParser.tagsAlignLeft
        let textUnderlineStartColumn = textParser.lastTextUnderline
        let textDoubleStrikeStartColumn = textParser.lastTextDoubleStrike
        let textColorStartColumn = textParser.lastTextColor
        let textReverseColorStartColumn = textParser.lastTextReverseColor

        var textColumn = input
        if textColumn.length > 2 {
            let prefix = try textColumn.substring(0, 3).uppercased()
            if prefix == "[L]" || prefix == "[C]" || prefix == "[R]" {
                textAlign = try textColumn.substring(1, 2).uppercased().string
                textColumn = try textColumn.substring(3)
            }
        }

        let trimmedTextColumn = textColumn.trim()
        var isImgOrBarcodeLine = false

        if textParserLine.nbrColumns == 1 && trimmedTextColumn.indexOf("<") == 0 {
            let openTagIndex = trimmedTextColumn.indexOf("<")
            let openTagEndIndex = trimmedTextColumn.indexOf(">", from: openTagIndex + 1) + 1
            if openTagIndex < openTagEndIndex {
                let textParserTag = try PrinterTextParserTag(try trimmedTextColumn.substring(openTagIndex, openTagEndIndex))
                let tagName = textParserTag.tagName.string
                if tagName == PrinterTextParser.tagsImage || tagName == PrinterTextParser.tagsBarcode || tagName == PrinterTextParser.tagsQRCode {
                    let closeTag = "</\(tagName)>"
                    let closeTagPosition = trimmedTextColumn.length - JavaString(closeTag).length
                    if try trimmedTextColumn.substring(closeTagPosition) == closeTag {
                        let content = try trimmedTextColumn.substring(openTagEndIndex, closeTagPosition)
                        switch tagName {
                        case PrinterTextParser.tagsImage:
                            appendElement(try PrinterTextParserImg(column: self, textAlign: textAlign, hexadecimalString: content))
                        case PrinterTextParser.tagsBarcode:
                            appendElement(try PrinterTextParserBarcode(column: self, textAlign: textAlign, attributes: textParserTag.attributes, code: content))
                        default:
                            appendElement(try PrinterTextParserImg.qrCode(column: self, textAlign: textAlign, attributes: textParserTag.attributes, data: content))
                        }
                        isImgOrBarcodeLine = true
                    }
                }
            }
        }

        guard !isImgOrBarcodeLine else { return }

        var offset = 0
        while true {
            var openTagIndex = textColumn.indexOf("<", from: offset)
            var closeTagIndex = -1
            if openTagIndex != -1 {
                closeTagIndex = textColumn.indexOf(">", from: openTagIndex)
            } else {
                openTagIndex = textColumn.length
            }
            appendString(try textColumn.substring(offset, openTagIndex))
            if closeTagIndex == -1 {
                break
            }
            closeTagIndex += 1
            let textParserTag = try PrinterTextParserTag(try textColumn.substring(openTagIndex, closeTagIndex))
            if try PrinterTextParser.isTagTextFormat(textParserTag.tagName) {
                applyFormatTag(textParserTag, textParser: textParser)
                offset = closeTagIndex
            } else {
                appendString(JavaString("<"))
                offset = openTagIndex + 1
            }
        }

        var nbrCharForgetted = textParserLine.nbrCharForgetted
        var nbrCharColumnExceeded = textParserLine.nbrCharColumnExceeded
        let nbrCharColumn = textParserLine.nbrCharColumn
        var nbrCharTextWithoutTag = 0
        var leftSpace = 0
        var rightSpace = 0

        for element in elements {
            nbrCharTextWithoutTag += try element.length()
        }

        switch textAlign {
        case PrinterTextParser.tagsAlignLeft:
            rightSpace = nbrCharColumn - nbrCharTextWithoutTag
        case PrinterTextParser.tagsAlignCenter:
            leftSpace = JavaMath.floorDiv(Float(nbrCharColumn) - Float(nbrCharTextWithoutTag), 2)
            rightSpace = nbrCharColumn - nbrCharTextWithoutTag - leftSpace
        case PrinterTextParser.tagsAlignRight:
            leftSpace = nbrCharColumn - nbrCharTextWithoutTag
        default:
            break
        }

        if nbrCharForgetted > 0 {
            nbrCharForgetted -= 1
            rightSpace += 1
        }

        if nbrCharColumnExceeded < 0 {
            leftSpace += nbrCharColumnExceeded
            nbrCharColumnExceeded = 0
            if leftSpace < 1 {
                rightSpace += leftSpace - 1
                leftSpace = 1
            }
        }

        if leftSpace < 0 {
            nbrCharColumnExceeded += leftSpace
            leftSpace = 0
        }
        if rightSpace < 0 {
            nbrCharColumnExceeded += rightSpace
            rightSpace = 0
        }

        if leftSpace > 0 {
            prependElement(PrinterTextParserString(
                column: self,
                text: PrinterTextParserColumn.generateSpace(leftSpace),
                textSize: EscPosPrinterCommands.textSizeNormal,
                textColor: textColorStartColumn,
                textReverseColor: textReverseColorStartColumn,
                textBold: EscPosPrinterCommands.textWeightNormal,
                textUnderline: textUnderlineStartColumn,
                textDoubleStrike: textDoubleStrikeStartColumn
            ))
        }
        if rightSpace > 0 {
            appendElement(PrinterTextParserString(
                column: self,
                text: PrinterTextParserColumn.generateSpace(rightSpace),
                textSize: EscPosPrinterCommands.textSizeNormal,
                textColor: textParser.lastTextColor,
                textReverseColor: textParser.lastTextReverseColor,
                textBold: EscPosPrinterCommands.textWeightNormal,
                textUnderline: textParser.lastTextUnderline,
                textDoubleStrike: textParser.lastTextDoubleStrike
            ))
        }

        textParserLine.nbrCharForgetted = nbrCharForgetted
        textParserLine.nbrCharColumnExceeded = nbrCharColumnExceeded
    }

    private func applyFormatTag(_ tag: PrinterTextParserTag, textParser: PrinterTextParser) {
        let name = tag.tagName.string
        if tag.isCloseTag {
            switch name {
            case PrinterTextParser.tagsFormatTextBold:
                textParser.dropTextBold()
            case PrinterTextParser.tagsFormatTextUnderline:
                textParser.dropLastTextUnderline()
                textParser.dropLastTextDoubleStrike()
            case PrinterTextParser.tagsFormatTextFont:
                textParser.dropLastTextSize()
                textParser.dropLastTextColor()
                textParser.dropLastTextReverseColor()
            default:
                break
            }
            return
        }
        switch name {
        case PrinterTextParser.tagsFormatTextBold:
            textParser.addTextBold(EscPosPrinterCommands.textWeightBold)
        case PrinterTextParser.tagsFormatTextUnderline:
            if let type = tag.attributes[PrinterTextParser.attrFormatTextUnderlineType] {
                switch type {
                case PrinterTextParser.attrFormatTextUnderlineTypeNormal:
                    textParser.addTextUnderline(EscPosPrinterCommands.textUnderlineLarge)
                    textParser.addTextDoubleStrike(textParser.lastTextDoubleStrike)
                case PrinterTextParser.attrFormatTextUnderlineTypeDouble:
                    textParser.addTextUnderline(textParser.lastTextUnderline)
                    textParser.addTextDoubleStrike(EscPosPrinterCommands.textDoubleStrikeOn)
                default:
                    break
                }
            } else {
                textParser.addTextUnderline(EscPosPrinterCommands.textUnderlineLarge)
                textParser.addTextDoubleStrike(textParser.lastTextDoubleStrike)
            }
        case PrinterTextParser.tagsFormatTextFont:
            if let size = tag.attributes[PrinterTextParser.attrFormatTextFontSize] {
                switch size {
                case "tall": textParser.addTextSize(EscPosPrinterCommands.textSizeDoubleHeight)
                case "wide": textParser.addTextSize(EscPosPrinterCommands.textSizeDoubleWidth)
                case "big": textParser.addTextSize(EscPosPrinterCommands.textSizeBig)
                case "big-2": textParser.addTextSize(EscPosPrinterCommands.textSizeBig2)
                case "big-3": textParser.addTextSize(EscPosPrinterCommands.textSizeBig3)
                case "big-4": textParser.addTextSize(EscPosPrinterCommands.textSizeBig4)
                case "big-5": textParser.addTextSize(EscPosPrinterCommands.textSizeBig5)
                case "big-6": textParser.addTextSize(EscPosPrinterCommands.textSizeBig6)
                default: textParser.addTextSize(EscPosPrinterCommands.textSizeNormal)
                }
            } else {
                textParser.addTextSize(textParser.lastTextSize)
            }
            if let color = tag.attributes[PrinterTextParser.attrFormatTextFontColor] {
                switch color {
                case "bg-black":
                    textParser.addTextColor(EscPosPrinterCommands.textColorBlack)
                    textParser.addTextReverseColor(EscPosPrinterCommands.textColorReverseOn)
                case "red":
                    textParser.addTextColor(EscPosPrinterCommands.textColorRed)
                    textParser.addTextReverseColor(EscPosPrinterCommands.textColorReverseOff)
                case "bg-red":
                    textParser.addTextColor(EscPosPrinterCommands.textColorRed)
                    textParser.addTextReverseColor(EscPosPrinterCommands.textColorReverseOn)
                default:
                    textParser.addTextColor(EscPosPrinterCommands.textColorBlack)
                    textParser.addTextReverseColor(EscPosPrinterCommands.textColorReverseOff)
                }
            } else {
                textParser.addTextColor(textParser.lastTextColor)
                textParser.addTextReverseColor(textParser.lastTextReverseColor)
            }
        default:
            break
        }
    }

    private func appendString(_ text: JavaString) {
        let textParser = textParserLine.textParser
        appendElement(PrinterTextParserString(
            column: self,
            text: text,
            textSize: textParser.lastTextSize,
            textColor: textParser.lastTextColor,
            textReverseColor: textParser.lastTextReverseColor,
            textBold: textParser.lastTextBold,
            textUnderline: textParser.lastTextUnderline,
            textDoubleStrike: textParser.lastTextDoubleStrike
        ))
    }

    private func prependElement(_ element: PrinterTextParserElement) {
        elements.insert(element, at: 0)
    }

    private func appendElement(_ element: PrinterTextParserElement) {
        elements.append(element)
    }
}

final class PrinterTextParserTag {
    private(set) var tagName = JavaString("")
    private(set) var attributes: [String: String] = [:]
    private(set) var length = 0
    private(set) var isCloseTag = false

    init(_ rawTag: JavaString) throws {
        let tag = rawTag.trim()
        guard try tag.substring(0, 1) == "<", try tag.substring(tag.length - 1) == ">" else {
            return
        }
        length = tag.length
        let openTagIndex = tag.indexOf("<")
        let closeTagIndex = tag.indexOf(">")
        let nextSpaceIndex = tag.indexOf(" ")
        if nextSpaceIndex != -1 && nextSpaceIndex < closeTagIndex {
            tagName = try tag.substring(openTagIndex + 1, nextSpaceIndex).lowercased()
            var attributesString = try tag.substring(nextSpaceIndex, closeTagIndex).trim()
            while attributesString.contains("='") {
                let egalPos = attributesString.indexOf("='")
                let endPos = attributesString.indexOf("'", from: egalPos + 2)
                let attributeName = try attributesString.substring(0, egalPos)
                let attributeValue = try attributesString.substring(egalPos + 2, endPos)
                if !attributeName.isEmpty {
                    attributes[attributeName.string] = attributeValue.string
                }
                attributesString = try attributesString.substring(endPos + 1).trim()
            }
        } else {
            tagName = try tag.substring(openTagIndex + 1, closeTagIndex).lowercased()
        }
        if try tagName.substring(0, 1) == "/" {
            tagName = try tagName.substring(1)
            isCloseTag = true
        }
    }
}

final class PrinterTextParserString: PrinterTextParserElement {
    private let printer: EscPosPrinter
    private let text: JavaString
    private let textSize: [UInt8]
    private let textColor: [UInt8]
    private let textReverseColor: [UInt8]
    private let textBold: [UInt8]
    private let textUnderline: [UInt8]
    private let textDoubleStrike: [UInt8]

    init(column: PrinterTextParserColumn, text: JavaString, textSize: [UInt8], textColor: [UInt8], textReverseColor: [UInt8], textBold: [UInt8], textUnderline: [UInt8], textDoubleStrike: [UInt8]) {
        self.printer = column.textParserLine.textParser.printer
        self.text = text
        self.textSize = textSize
        self.textColor = textColor
        self.textReverseColor = textReverseColor
        self.textBold = textBold
        self.textUnderline = textUnderline
        self.textDoubleStrike = textDoubleStrike
    }

    func length() throws -> Int {
        var coefficient = 1
        switch textSize {
        case EscPosPrinterCommands.textSizeDoubleWidth, EscPosPrinterCommands.textSizeBig:
            coefficient = 2
        case EscPosPrinterCommands.textSizeBig2:
            coefficient = 3
        case EscPosPrinterCommands.textSizeBig3:
            coefficient = 4
        case EscPosPrinterCommands.textSizeBig4:
            coefficient = 5
        case EscPosPrinterCommands.textSizeBig5:
            coefficient = 6
        case EscPosPrinterCommands.textSizeBig6:
            coefficient = 7
        default:
            break
        }
        if let encoding = printer.encoding {
            return try encoding.encode(text).count * coefficient
        }
        return text.length * coefficient
    }

    func print(_ printerSocket: EscPosPrinterCommands) throws {
        try printerSocket.printText(
            text,
            textSize: textSize,
            textColor: textColor,
            textReverseColor: textReverseColor,
            textBold: textBold,
            textUnderline: textUnderline,
            textDoubleStrike: textDoubleStrike
        )
    }
}

final class PrinterTextParserImg: PrinterTextParserElement {
    static func bitmapToHexadecimalString(_ printerSize: EscPosPrinterSize, _ bitmap: EscPosBitmap) -> String {
        EscPosHex.string(printerSize.bitmapToBytes(bitmap))
    }

    static func qrCode(column: PrinterTextParserColumn, textAlign: String, attributes: [String: String], data: JavaString) throws -> PrinterTextParserImg {
        let printer = column.textParserLine.textParser.printer
        let content = data.trim()
        var size = printer.mmToPx(20)
        if let value = attributes[PrinterTextParser.attrQRCodeSize] {
            guard let millimeters = JavaMath.parseFloat(value) else {
                throw EscPosError.parser("Invalid QR code size value")
            }
            size = printer.mmToPx(millimeters)
        }
        return try PrinterTextParserImg(column: column, textAlign: textAlign, image: EscPosPrinterCommands.qrCodeDataToBytes(content.string, size: size))
    }

    private let elementLength: Int
    let image: [UInt8]

    convenience init(column: PrinterTextParserColumn, textAlign: String, hexadecimalString: JavaString) throws {
        try self.init(column: column, textAlign: textAlign, image: EscPosHex.bytes(hexadecimalString))
    }

    init(column: PrinterTextParserColumn, textAlign: String, image source: [UInt8]) throws {
        let printer = column.textParserLine.textParser.printer
        guard source.count >= 8 else {
            throw EscPosError.runtime("Index \(max(source.count, 4)) out of bounds for length \(source.count)")
        }
        var image = source
        let byteWidth = Int(image[4]) + Int(image[5]) * 256
        let width = byteWidth * 8
        let height = Int(image[6]) + Int(image[7]) * 256
        let nbrByteDiff = JavaMath.floorDiv(Float(printer.printerWidthPx - width), 8)
        var nbrWhiteByteToInsert = 0
        switch textAlign {
        case PrinterTextParser.tagsAlignCenter:
            nbrWhiteByteToInsert = JavaMath.round(Float(nbrByteDiff) / 2)
        case PrinterTextParser.tagsAlignRight:
            nbrWhiteByteToInsert = nbrByteDiff
        default:
            break
        }

        if nbrWhiteByteToInsert > 0 {
            let newByteWidth = byteWidth + nbrWhiteByteToInsert
            var newImage = EscPosPrinterCommands.initGSv0Command(bytesByLine: newByteWidth, bitmapHeight: height)
            for row in 0..<height {
                let sourceStart = byteWidth * row + 8
                let destinationStart = newByteWidth * row + nbrWhiteByteToInsert + 8
                guard sourceStart + byteWidth <= image.count else {
                    throw EscPosError.runtime("arraycopy: last source index \(sourceStart + byteWidth) out of bounds for byte[\(image.count)]")
                }
                newImage.replaceSubrange(destinationStart..<(destinationStart + byteWidth), with: image[sourceStart..<(sourceStart + byteWidth)])
            }
            image = newImage
        }

        elementLength = JavaMath.toInt((Float(byteWidth) * 8 / Float(printer.printerCharSizeWidthPx)).rounded(.up))
        self.image = image
    }

    func length() throws -> Int {
        elementLength
    }

    func print(_ printerSocket: EscPosPrinterCommands) throws {
        try printerSocket.printImage(image)
    }
}

final class PrinterTextParserBarcode: PrinterTextParserElement {
    private let barcode: EscPosBarcode
    private let elementLength: Int
    private let align: [UInt8]

    init(column: PrinterTextParserColumn, textAlign: String, attributes: [String: String], code rawCode: JavaString) throws {
        let printer = column.textParserLine.textParser.printer
        let code = rawCode.trim()

        switch textAlign {
        case PrinterTextParser.tagsAlignCenter:
            align = EscPosPrinterCommands.textAlignCenter
        case PrinterTextParser.tagsAlignRight:
            align = EscPosPrinterCommands.textAlignRight
        default:
            align = EscPosPrinterCommands.textAlignLeft
        }

        elementLength = printer.printerNbrCharactersPerLine

        var height: Float = 10
        if let value = attributes[PrinterTextParser.attrBarcodeHeight] {
            guard let parsed = JavaMath.parseFloat(value) else {
                throw EscPosError.parser("Invalid barcode height value")
            }
            height = parsed
        }

        var width: Float = 0
        if let value = attributes[PrinterTextParser.attrBarcodeWidth] {
            guard let parsed = JavaMath.parseFloat(value) else {
                throw EscPosError.parser("Invalid barcode width value")
            }
            width = parsed
        }

        var textPosition = EscPosPrinterCommands.barcodeTextPositionBelow
        if let value = attributes[PrinterTextParser.attrBarcodeTextPosition] {
            switch value {
            case PrinterTextParser.attrBarcodeTextPositionNone:
                textPosition = EscPosPrinterCommands.barcodeTextPositionNone
            case PrinterTextParser.attrBarcodeTextPositionAbove:
                textPosition = EscPosPrinterCommands.barcodeTextPositionAbove
            default:
                break
            }
        }

        let barcodeType = attributes[PrinterTextParser.attrBarcodeType] ?? PrinterTextParser.attrBarcodeTypeEAN13
        barcode = try EscPosBarcode.make(type: barcodeType, printerSize: printer, code: code, widthMM: width, heightMM: height, textPosition: textPosition)
    }

    func length() throws -> Int {
        elementLength
    }

    func print(_ printerSocket: EscPosPrinterCommands) throws {
        try printerSocket.setAlign(align).printBarcode(barcode)
    }
}
