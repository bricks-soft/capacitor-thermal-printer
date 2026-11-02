import Capacitor
import Foundation

@objc(ThermalPrinterPlugin)
public final class ThermalPrinterPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ThermalPrinterPlugin"
    public let jsName = "ThermalPrinter"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "listPrinters", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "printFormattedText", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "printFormattedTextAndCut", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getEncoding", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "disconnectPrinter", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestBTPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestUSBPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "bitmapToHexadecimalString", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "bytesToHexadecimalString", returnType: CAPPluginReturnPromise),
    ]
    private let service = ThermalPrinterService()

    deinit {
        service.cancelPendingRequests()
    }

    @objc public func listPrinters(_ call: CAPPluginCall) {
        run("listPrinters", call)
    }

    @objc public func printFormattedText(_ call: CAPPluginCall) {
        run("printFormattedText", call)
    }

    @objc public func printFormattedTextAndCut(_ call: CAPPluginCall) {
        run("printFormattedTextAndCut", call)
    }

    @objc public func getEncoding(_ call: CAPPluginCall) {
        run("getEncoding", call)
    }

    @objc public func disconnectPrinter(_ call: CAPPluginCall) {
        run("disconnectPrinter", call)
    }

    @objc override public func requestPermissions(_ call: CAPPluginCall) {
        run("requestPermissions", call)
    }

    @objc public func requestBTPermissions(_ call: CAPPluginCall) {
        run("requestBTPermissions", call)
    }

    @objc public func requestUSBPermissions(_ call: CAPPluginCall) {
        run("requestPermissions", call)
    }

    @objc public func bitmapToHexadecimalString(_ call: CAPPluginCall) {
        run("bitmapToHexadecimalString", call)
    }

    @objc public func bytesToHexadecimalString(_ call: CAPPluginCall) {
        guard let bytes = call.getArray("bytes", Int.self), bytes.allSatisfy({ (0...255).contains($0) }) else {
            call.reject("bytes must contain PNG or JPEG bytes in the range 0...255")
            return
        }
        var options = call.options as? [String: Any] ?? [:]
        options["base64"] = Data(bytes.map(UInt8.init)).base64EncodedString()
        run("bitmapToHexadecimalString", call, options: options)
    }

    private func run(_ action: String, _ call: CAPPluginCall, options: [String: Any]? = nil) {
        service.execute(action, [options ?? (call.options as? [String: Any] ?? [:])]) { result in
            switch result {
            case .success(let payload):
                call.resolve(payload.map { ["value": $0] } ?? [:])
            case .error(let payload):
                let data = payload as? [String: Any]
                call.reject(data?["error"] as? String ?? String(describing: payload), nil, nil, data)
            case .cancelled:
                call.reject("Printer request cancelled")
            }
        }
    }
}
