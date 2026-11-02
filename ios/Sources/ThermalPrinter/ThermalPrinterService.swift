import CoreBluetooth
import Foundation

enum ThermalPrinterResult {
    case success(Any?)
    case error(Any)
    case cancelled
}

struct ThermalPrinterFailure: Error {
    let payload: Any
}

struct ThermalPrinterJSONError: Error {
    let message: String
}

struct ThermalPrinterArguments {
    let values: [String: Any]

    init(_ values: [String: Any]) {
        self.values = values
    }

    func has(_ key: String) -> Bool {
        values[key] != nil
    }

    func getString(_ key: String) throws -> String {
        guard let value = values[key] else {
            throw ThermalPrinterJSONError(message: "No value for \(key)")
        }
        return ThermalPrinterArguments.javaString(value)
    }

    func optString(_ key: String, _ fallback: String = "") -> String {
        guard let value = values[key] else { return fallback }
        return ThermalPrinterArguments.javaString(value)
    }

    func optInt(_ key: String, _ fallback: Int) -> Int {
        guard let value = values[key] else { return fallback }
        if ThermalPrinterArguments.isBoolean(value) { return fallback }
        if let number = value as? NSNumber { return JavaMath.toInt(number.doubleValue) }
        if let string = value as? String, let parsed = JavaMath.parseDouble(string) { return JavaMath.toInt(parsed) }
        return fallback
    }

    func optDouble(_ key: String, _ fallback: Double) -> Double {
        guard let value = values[key] else { return fallback }
        if ThermalPrinterArguments.isBoolean(value) { return fallback }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String, let parsed = JavaMath.parseDouble(string) { return parsed }
        return fallback
    }

    func getDouble(_ key: String) throws -> Double {
        guard let value = values[key] else {
            throw ThermalPrinterJSONError(message: "No value for \(key)")
        }
        if !ThermalPrinterArguments.isBoolean(value) {
            if let number = value as? NSNumber { return number.doubleValue }
            if let string = value as? String, let parsed = JavaMath.parseDouble(string) { return parsed }
        }
        throw ThermalPrinterJSONError(message: "Value \(ThermalPrinterArguments.javaString(value)) at \(key) cannot be converted to double")
    }

    func optObject(_ key: String) -> ThermalPrinterArguments? {
        guard let object = values[key] as? [String: Any] else { return nil }
        return ThermalPrinterArguments(object)
    }

    private static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func javaString(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber {
            if isBoolean(number) { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        return String(describing: value)
    }
}

final class ThermalPrinterService {
    private let queue = DispatchQueue(label: "de.paystory.thermal-printer.commands")
    private var connections: [String: EscPosDeviceConnection] = [:]
    private var bluetoothCentral: EscPosBluetoothCentral?
    private let makeBluetoothCentral: () -> EscPosBluetoothCentral
    private let makeTcpConnection: (String, Int) -> EscPosDeviceConnection

    init(
        makeBluetoothCentral: @escaping () -> EscPosBluetoothCentral = { EscPosBluetoothCentral() },
        makeTcpConnection: @escaping (String, Int) -> EscPosDeviceConnection = { EscPosTcpConnection(address: $0, port: $1) }
    ) {
        self.makeBluetoothCentral = makeBluetoothCentral
        self.makeTcpConnection = makeTcpConnection
    }

    deinit {
        bluetoothCentral?.cancelAuthorizationRequests()
    }

    private var bluetooth: EscPosBluetoothCentral {
        if let central = bluetoothCentral {
            return central
        }
        let central = makeBluetoothCentral()
        bluetoothCentral = central
        return central
    }

    func execute(_ action: String, _ arguments: [Any], completion: @escaping (ThermalPrinterResult) -> Void) {
        queue.async {
            if action == "requestBTPermissions", arguments.first is [String: Any] {
                self.requestBTPermissions(completion)
                return
            }
            completion(self.run(action, arguments))
        }
    }

    func cancelPendingRequests() {
        queue.async {
            self.bluetoothCentral?.cancelAuthorizationRequests()
        }
    }

    func run(_ action: String, _ arguments: [Any]) -> ThermalPrinterResult {
        guard let object = arguments.first as? [String: Any] else {
            return .error("Value at 0 is not a JSONObject")
        }
        let data = ThermalPrinterArguments(object)
        do {
            switch action {
            case "listPrinters":
                return try listPrinters(data)
            case "printFormattedText", "printFormattedTextAndCut":
                return try printFormattedText(action, data)
            case "getEncoding":
                return try getEncoding(data)
            case "disconnectPrinter":
                return try disconnectPrinter(data)
            case "requestPermissions":
                return try requestUSBPermissions(data)
            case "bitmapToHexadecimalString":
                return try bitmapToHexadecimalString(data)
            default:
                return .error("Invalid action")
            }
        } catch let failure as ThermalPrinterFailure {
            return .error(failure.payload)
        } catch let failure as ThermalPrinterJSONError {
            return .error(failure.message)
        } catch let failure as EscPosError {
            return .error(["error": failure.message])
        } catch {
            return .error(["error": error.localizedDescription])
        }
    }

    private func requestBTPermissions(_ completion: @escaping (ThermalPrinterResult) -> Void) {
        bluetooth.requestAuthorization { answer in
            switch answer {
            case .some(.allowedAlways):
                completion(.success(["granted": true]))
            case .none:
                completion(.cancelled)
            default:
                completion(.error(["granted": false]))
            }
        }
    }

    private func listPrinters(_ data: ThermalPrinterArguments) throws -> ThermalPrinterResult {
        let type = try data.getString("type")
        guard type == "bluetooth" else {
            return .success([[String: Any]]())
        }
        try checkBluetooth()
        let printers: [[String: Any]] = bluetooth.listDevices().map { device in
            var printer: [String: Any] = [
                "address": device.identifier.uuidString,
                "type": 2,
            ]
            if let name = device.name {
                printer["name"] = name
            }
            if !device.services.isEmpty {
                printer["features"] = device.services.map(\.uuidString)
            }
            return printer
        }
        return .success(printers)
    }

    private func printFormattedText(_ action: String, _ data: ThermalPrinterArguments) throws -> ThermalPrinterResult {
        try printFormattedText(action, data, printer: getPrinter(data))
    }

    func printFormattedText(_ action: String, _ data: ThermalPrinterArguments, printer: EscPosPrinter) throws -> ThermalPrinterResult {
        do {
            let dotsFeedPaper = data.has("mmFeedPaper")
                ? printer.mmToPx(Float(try data.getDouble("mmFeedPaper")))
                : data.optInt("dotsFeedPaper", 20)
            let text = try data.getString("text")
            if action.hasSuffix("Cut") {
                try printer.printFormattedTextAndCut(text, dotsFeedPaper: dotsFeedPaper)
            } else {
                try printer.printFormattedText(text, dotsFeedPaper: dotsFeedPaper)
            }
            return .success(nil)
        } catch let failure as EscPosError {
            printer.printer?.printerConnection.clearBuffer()
            throw ThermalPrinterFailure(payload: ["error": failure.message])
        } catch let failure as ThermalPrinterJSONError {
            printer.printer?.printerConnection.clearBuffer()
            throw ThermalPrinterFailure(payload: ["error": failure.message])
        }
    }

    private func getEncoding(_ data: ThermalPrinterArguments) throws -> ThermalPrinterResult {
        try encodingResult(getPrinter(data))
    }

    func encodingResult(_ printer: EscPosPrinter) -> ThermalPrinterResult {
        guard let encoding = printer.encoding else {
            return .success("null")
        }
        return .success([
            "name": encoding.name,
            "command": encoding.command.map { Int(Int8(bitPattern: $0)) },
        ])
    }

    private func disconnectPrinter(_ data: ThermalPrinterArguments) throws -> ThermalPrinterResult {
        let printer = try getPrinter(data)
        printer.disconnectPrinter()
        return .success(nil)
    }

    private func requestUSBPermissions(_ data: ThermalPrinterArguments) throws -> ThermalPrinterResult {
        _ = try getPrinterConnection(data)
        return .error(["error": "USB printers are not supported on iOS."])
    }

    private func bitmapToHexadecimalString(_ data: ThermalPrinterArguments) throws -> ThermalPrinterResult {
        let encoded = try data.getString("base64")
        let payload: Substring
        if let comma = encoded.firstIndex(of: ",") {
            payload = encoded[encoded.index(after: comma)...]
        } else {
            payload = Substring(encoded)
        }
        guard let bytes = ThermalPrinterService.decodeBase64(payload) else {
            return .error(["error": "bad base-64"])
        }
        let printer = try getPrinter(data)
        guard let bitmap = EscPosBitmap.decode(bytes) else {
            return .error(["error": "Unable to decode the image."])
        }
        return .success(PrinterTextParserImg.bitmapToHexadecimalString(printer, bitmap))
    }

    static func decodeBase64(_ text: Substring) -> Data? {
        var cleaned = text.filter { !$0.isWhitespace }
        let remainder = cleaned.count % 4
        if remainder == 1 {
            return nil
        }
        if remainder > 0 {
            cleaned.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: cleaned)
    }

    func getPrinter(_ data: ThermalPrinterArguments) throws -> EscPosPrinter {
        let connection = try getPrinterConnection(data)
        return try makePrinter(connection: connection, data: data)
    }

    func makePrinter(connection: EscPosDeviceConnection, data: ThermalPrinterArguments) throws -> EscPosPrinter {
        var charsetEncoding: EscPosCharsetEncoding?
        if let charset = data.optObject("charsetEncoding") {
            charsetEncoding = EscPosCharsetEncoding(
                name: charset.optString("charsetName", "windows-1252"),
                escPosCharsetId: charset.optInt("charsetId", 16)
            )
        }
        do {
            return try EscPosPrinter(
                connection: connection,
                printerDpi: data.optInt("printerDpi", 203),
                printerWidthMM: Float(data.optDouble("printerWidthMM", 48)),
                printerNbrCharactersPerLine: data.optInt("printerNbrCharactersPerLine", 32),
                charsetEncoding: charsetEncoding
            )
        } catch let failure as EscPosError {
            throw ThermalPrinterFailure(payload: ["error": failure.message])
        }
    }

    private func getPrinterConnection(_ data: ThermalPrinterArguments) throws -> EscPosDeviceConnection {
        let type = try data.getString("type")
        let id = try data.getString("id")
        let hashKey = "\(type)-\(id)"
        guard let connection = try getDevice(
            hashKey: hashKey,
            type: type,
            id: data.optString("id"),
            address: data.optString("address"),
            port: data.optInt("port", 9100)
        ) else {
            throw ThermalPrinterFailure(payload: [
                "error": "Device not found or not connected!",
                "type": type,
                "id": id,
            ])
        }
        connections[hashKey] = connection
        return connection
    }

    private func getDevice(hashKey: String, type: String, id: String, address: String, port: Int) throws -> EscPosDeviceConnection? {
        if let existing = connections[hashKey] {
            if existing.isConnected {
                return existing
            }
            connections.removeValue(forKey: hashKey)
        }

        switch type {
        case "bluetooth":
            try checkBluetooth()
            if id == "first" {
                for peripheral in bluetooth.candidatesForFirst() {
                    let connection = bluetooth.connection(for: peripheral)
                    if (try? connection.connect()) != nil {
                        return connection
                    }
                }
                return nil
            }
            guard let peripheral = bluetooth.findPeripheral(id: id, address: address) else {
                return nil
            }
            return bluetooth.connection(for: peripheral)
        case "tcp":
            return makeTcpConnection(address, port)
        default:
            return nil
        }
    }

    private func checkBluetooth() throws {
        if bluetooth.authorization == .notDetermined {
            _ = bluetooth.waitForAuthorization()
        }
        switch bluetooth.authorization {
        case .denied, .restricted, .notDetermined:
            throw ThermalPrinterFailure(payload: ["error": "Missing permission for Bluetooth!"])
        default:
            break
        }
        switch bluetooth.waitForState() {
        case .poweredOn:
            return
        case .unsupported:
            throw ThermalPrinterFailure(payload: ["error": "Device doesn't support Bluetooth!"])
        case .unauthorized:
            throw ThermalPrinterFailure(payload: ["error": "Missing permission for Bluetooth!"])
        default:
            throw ThermalPrinterFailure(payload: ["error": "Device not enabled Bluetooth!"])
        }
    }
}
