import Foundation

@objc(ThermalPrinterCordovaPlugin)
final class ThermalPrinterCordovaPlugin: CDVPlugin {
    private let service = ThermalPrinterService()

    @objc(listPrinters:)
    func listPrinters(_ command: CDVInvokedUrlCommand) {
        run("listPrinters", command)
    }

    @objc(printFormattedText:)
    func printFormattedText(_ command: CDVInvokedUrlCommand) {
        run("printFormattedText", command)
    }

    @objc(printFormattedTextAndCut:)
    func printFormattedTextAndCut(_ command: CDVInvokedUrlCommand) {
        run("printFormattedTextAndCut", command)
    }

    @objc(getEncoding:)
    func getEncoding(_ command: CDVInvokedUrlCommand) {
        run("getEncoding", command)
    }

    @objc(disconnectPrinter:)
    func disconnectPrinter(_ command: CDVInvokedUrlCommand) {
        run("disconnectPrinter", command)
    }

    @objc(requestPermissions:)
    func requestPermissions(_ command: CDVInvokedUrlCommand) {
        run("requestPermissions", command)
    }

    @objc(requestBTPermissions:)
    func requestBTPermissions(_ command: CDVInvokedUrlCommand) {
        run("requestBTPermissions", command)
    }

    @objc(bitmapToHexadecimalString:)
    func bitmapToHexadecimalString(_ command: CDVInvokedUrlCommand) {
        run("bitmapToHexadecimalString", command)
    }

    private func run(_ action: String, _ command: CDVInvokedUrlCommand) {
        let callbackId = command.callbackId
        service.execute(action, command.arguments ?? []) { [weak self] result in
            self?.commandDelegate.send(ThermalPrinterCordovaPlugin.pluginResult(result), callbackId: callbackId)
        }
    }

    private static func pluginResult(_ result: ThermalPrinterResult) -> CDVPluginResult {
        switch result {
        case .success(let payload):
            return pluginResult(status: .ok, payload: payload)
        case .error(let payload):
            return pluginResult(status: .error, payload: payload)
        }
    }

    private static func pluginResult(status: CDVCommandStatus, payload: Any?) -> CDVPluginResult {
        switch payload {
        case let message as String:
            return CDVPluginResult(status: status, messageAs: message)
        case let message as [Any]:
            return CDVPluginResult(status: status, messageAs: message)
        case let message as [String: Any]:
            return CDVPluginResult(status: status, messageAs: message)
        default:
            return CDVPluginResult(status: status)
        }
    }
}
