import Foundation

struct EscPosError: Error, Equatable {
    enum Kind: Equatable {
        case connection
        case parser
        case encoding
        case barcode
        case runtime
    }

    let kind: Kind
    let message: String

    static func connection(_ message: String) -> EscPosError { EscPosError(kind: .connection, message: message) }
    static func parser(_ message: String) -> EscPosError { EscPosError(kind: .parser, message: message) }
    static func encoding(_ message: String) -> EscPosError { EscPosError(kind: .encoding, message: message) }
    static func barcode(_ message: String) -> EscPosError { EscPosError(kind: .barcode, message: message) }
    static func runtime(_ message: String) -> EscPosError { EscPosError(kind: .runtime, message: message) }
}

struct JavaString: Equatable {
    var units: [UInt16]

    init(_ string: String) {
        units = Array(string.utf16)
    }

    init<S: Sequence>(units: S) where S.Element == UInt16 {
        self.units = Array(units)
    }

    var length: Int { units.count }

    var isEmpty: Bool { units.isEmpty }

    var string: String { String(decoding: units, as: UTF16.self) }

    func indexOf(_ needle: String, from: Int = 0) -> Int {
        let pattern = Array(needle.utf16)
        let start = max(0, from)
        if pattern.isEmpty {
            return start <= length ? start : length
        }
        guard pattern.count <= length else { return -1 }
        var index = start
        let first = pattern[0]
        while index + pattern.count <= length {
            if units[index] == first && units[index..<(index + pattern.count)].elementsEqual(pattern) {
                return index
            }
            index += 1
        }
        return -1
    }

    func contains(_ needle: String) -> Bool {
        indexOf(needle) != -1
    }

    func substring(_ begin: Int, _ end: Int? = nil) throws -> JavaString {
        let finish = end ?? length
        guard begin >= 0, finish <= length, begin <= finish else {
            throw EscPosError.runtime("begin \(begin), end \(finish), length \(length)")
        }
        return JavaString(units: units[begin..<finish])
    }

    func trim() -> JavaString {
        var start = 0
        var finish = length
        while start < finish && units[start] <= 0x20 {
            start += 1
        }
        while finish > start && units[finish - 1] <= 0x20 {
            finish -= 1
        }
        return JavaString(units: units[start..<finish])
    }

    func lowercased() -> JavaString { JavaString(string.lowercased()) }

    func uppercased() -> JavaString { JavaString(string.uppercased()) }

    static func == (lhs: JavaString, rhs: String) -> Bool {
        lhs.units.elementsEqual(rhs.utf16)
    }

    static func splitLines(_ text: JavaString) -> [JavaString] {
        var parts: [JavaString] = []
        var start = 0
        var index = 0
        var matched = false
        let units = text.units
        while index < units.count {
            if units[index] == 0x0A {
                parts.append(JavaString(units: units[start..<index]))
                index += 1
                start = index
                matched = true
            } else if units[index] == 0x0D && index + 1 < units.count && units[index + 1] == 0x0A {
                parts.append(JavaString(units: units[start..<index]))
                index += 2
                start = index
                matched = true
            } else {
                index += 1
            }
        }
        if !matched {
            return [text]
        }
        parts.append(JavaString(units: units[start..<units.count]))
        while let last = parts.last, last.isEmpty {
            parts.removeLast()
        }
        return parts
    }
}

enum JavaMath {
    static func round(_ value: Float) -> Int {
        if value.isNaN { return 0 }
        return saturatingInt32((Double(value) + 0.5).rounded(.down))
    }

    static func round(_ value: Double) -> Int {
        if value.isNaN { return 0 }
        let rounded = (value + 0.5).rounded(.down)
        if rounded >= Double(Int64.max) { return Int(Int64.max) }
        if rounded <= Double(Int64.min) { return Int(Int64.min) }
        return Int(rounded)
    }

    static func toInt(_ value: Float) -> Int {
        if value.isNaN { return 0 }
        return saturatingInt32(Double(value).rounded(.towardZero))
    }

    static func toInt(_ value: Double) -> Int {
        if value.isNaN { return 0 }
        return saturatingInt32(value.rounded(.towardZero))
    }

    static func floorDiv(_ numerator: Float, _ denominator: Float) -> Int {
        toInt((numerator / denominator).rounded(.down))
    }

    static func parseFloat(_ string: String) -> Float? {
        var text = JavaString(string).trim().string
        if let last = text.last, "fFdD".contains(last) {
            text.removeLast()
        }
        if text.isEmpty || text.lowercased().hasPrefix("inf") || text.lowercased().hasPrefix("+inf") || text.lowercased().hasPrefix("-inf") {
            return nil
        }
        return Float(text)
    }

    static func parseDouble(_ string: String) -> Double? {
        var text = JavaString(string).trim().string
        if let last = text.last, "fFdD".contains(last) {
            text.removeLast()
        }
        if text.isEmpty { return nil }
        return Double(text)
    }

    private static func saturatingInt32(_ value: Double) -> Int {
        if value >= Double(Int32.max) { return Int(Int32.max) }
        if value <= Double(Int32.min) { return Int(Int32.min) }
        return Int(value)
    }
}

enum EscPosHex {
    private static let digits = Array("0123456789abcdef".utf8)

    static func string(_ bytes: [UInt8]) -> String {
        var output = [UInt8]()
        output.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    static func bytes(_ hex: JavaString) throws -> [UInt8] {
        let count = hex.length / 2
        var bytes = [UInt8](repeating: 0, count: count)
        let units = hex.units
        for index in 0..<count {
            let high = units[index * 2]
            let low = units[index * 2 + 1]
            guard let highValue = value(high), let lowValue = value(low) else {
                let pair = JavaString(units: [high, low]).string
                throw EscPosError.runtime("For input string: \"\(pair)\" under radix 16")
            }
            bytes[index] = UInt8(highValue << 4 | lowValue)
        }
        return bytes
    }

    private static func value(_ unit: UInt16) -> UInt8? {
        switch unit {
        case 0x30...0x39: return UInt8(unit - 0x30)
        case 0x41...0x46: return UInt8(unit - 0x41 + 10)
        case 0x61...0x66: return UInt8(unit - 0x61 + 10)
        default: return nil
        }
    }
}
