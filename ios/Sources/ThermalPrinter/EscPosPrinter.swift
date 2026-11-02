import Foundation

final class EscPosPrinter: EscPosPrinterSize {
    private(set) var printer: EscPosPrinterCommands?

    init(connection: EscPosDeviceConnection?, printerDpi: Int, printerWidthMM: Float, printerNbrCharactersPerLine: Int, charsetEncoding: EscPosCharsetEncoding? = nil) throws {
        let commands = connection.map { EscPosPrinterCommands(printerConnection: $0, charsetEncoding: charsetEncoding) }
        try super.init(printerDpi: printerDpi, printerWidthMM: printerWidthMM, printerNbrCharactersPerLine: printerNbrCharactersPerLine)
        if let commands = commands {
            printer = try commands.connect()
        }
    }

    var encoding: EscPosCharsetEncoding? { printer?.charsetEncoding }

    @discardableResult
    func disconnectPrinter() -> EscPosPrinter {
        printer?.disconnect()
        printer = nil
        return self
    }

    @discardableResult
    func printFormattedText(_ text: String, dotsFeedPaper: Int) throws -> EscPosPrinter {
        guard let printer = printer, printerNbrCharactersPerLine != 0 else { return self }

        let linesParsed = try PrinterTextParser(printer: self).setFormattedText(JavaString(text)).parse()

        try printer.reset()

        for line in linesParsed {
            var lastElement: PrinterTextParserElement?
            for column in line.columns {
                for element in column.elements {
                    try element.print(printer)
                    lastElement = element
                }
            }
            if lastElement is PrinterTextParserString {
                try printer.newLine()
            }
        }

        try printer.feedPaper(dotsFeedPaper)
        return self
    }

    @discardableResult
    func printFormattedTextAndCut(_ text: String, dotsFeedPaper: Int) throws -> EscPosPrinter {
        guard let printer = printer, printerNbrCharactersPerLine != 0 else { return self }
        try printFormattedText(text, dotsFeedPaper: dotsFeedPaper)
        try printer.cutPaper()
        return self
    }
}
