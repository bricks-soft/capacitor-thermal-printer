import Foundation

struct EscPosCharsetEncoding: Equatable {
    let name: String
    let command: [UInt8]

    init(name: String, escPosCharsetId: Int) {
        self.name = name
        self.command = [0x1B, 0x74, UInt8(truncatingIfNeeded: escPosCharsetId)]
    }

    func encode(_ text: JavaString) throws -> [UInt8] {
        let encoding = try EscPosCharsetEncoding.stringEncoding(for: name)
        if let data = text.string.data(using: encoding, allowLossyConversion: false), !EscPosCharsetEncoding.hasLoneSurrogate(text) {
            return EscPosCharsetEncoding.dropByteOrderMark([UInt8](data), encoding: encoding)
        }
        var bytes: [UInt8] = []
        var index = 0
        let units = text.units
        while index < units.count {
            let unit = units[index]
            var codePointUnits = [unit]
            if UTF16.isLeadSurrogate(unit), index + 1 < units.count, UTF16.isTrailSurrogate(units[index + 1]) {
                codePointUnits.append(units[index + 1])
            }
            index += codePointUnits.count
            let isLoneSurrogate = codePointUnits.count == 1 && (UTF16.isLeadSurrogate(unit) || UTF16.isTrailSurrogate(unit))
            if !isLoneSurrogate,
               let data = String(decoding: codePointUnits, as: UTF16.self).data(using: encoding, allowLossyConversion: false) {
                bytes.append(contentsOf: EscPosCharsetEncoding.dropByteOrderMark([UInt8](data), encoding: encoding))
            } else {
                bytes.append(contentsOf: EscPosCharsetEncoding.replacement(for: encoding))
            }
        }
        return bytes
    }

    static func stringEncoding(for charsetName: String) throws -> String.Encoding {
        for candidate in candidates(for: charsetName) {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(candidate as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
            }
        }
        throw EscPosError.encoding(charsetName)
    }

    private static func candidates(for charsetName: String) -> [String] {
        let trimmed = charsetName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let lower = trimmed.lowercased()
        var names = [trimmed]
        if let digits = suffixDigits(lower, prefixes: ["cp", "ibm", "ibm-", "cp-"]) {
            if digits.count == 4, digits.hasPrefix("12") {
                names.append("windows-\(digits)")
            } else {
                names.append("IBM\(digits)")
                names.append("cp\(digits)")
            }
        }
        if let digits = suffixDigits(lower, prefixes: ["windows-", "windows"]) {
            names.append("windows-\(digits)")
        }
        if let digits = suffixDigits(lower, prefixes: ["iso8859_", "iso8859-", "iso-8859_", "iso_8859-", "iso_8859_"]) {
            names.append("ISO-8859-\(digits)")
        }
        if lower == "utf8" { names.append("UTF-8") }
        if lower == "ascii" || lower == "us-ascii" { names.append("US-ASCII") }
        return names
    }

    private static func suffixDigits(_ name: String, prefixes: [String]) -> String? {
        for prefix in prefixes where name.hasPrefix(prefix) {
            let rest = String(name.dropFirst(prefix.count))
            if !rest.isEmpty, rest.allSatisfy({ $0.isASCII && $0.isNumber }) {
                return rest
            }
        }
        return nil
    }

    private static func hasLoneSurrogate(_ text: JavaString) -> Bool {
        var index = 0
        let units = text.units
        while index < units.count {
            let unit = units[index]
            if UTF16.isLeadSurrogate(unit) {
                if index + 1 < units.count, UTF16.isTrailSurrogate(units[index + 1]) {
                    index += 2
                    continue
                }
                return true
            }
            if UTF16.isTrailSurrogate(unit) {
                return true
            }
            index += 1
        }
        return false
    }

    private static func dropByteOrderMark(_ bytes: [UInt8], encoding: String.Encoding) -> [UInt8] {
        if encoding == .utf8, bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return Array(bytes.dropFirst(3))
        }
        return bytes
    }

    private static func replacement(for encoding: String.Encoding) -> [UInt8] {
        if let data = "?".data(using: encoding, allowLossyConversion: false) {
            return dropByteOrderMark([UInt8](data), encoding: encoding)
        }
        return [0x3F]
    }
}
