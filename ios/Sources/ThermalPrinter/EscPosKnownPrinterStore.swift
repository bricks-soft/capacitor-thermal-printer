import Foundation

final class EscPosKnownPrinterStore {
    static func applicationSupportFile() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("ThermalPrinter", isDirectory: true)
            .appendingPathComponent("known-bluetooth-printers.json")
    }

    let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL = EscPosKnownPrinterStore.applicationSupportFile()) {
        self.fileURL = fileURL
    }

    func load() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return read()
    }

    func remember(identifier: UUID, name: String) {
        lock.lock()
        defer { lock.unlock() }
        var printers = read()
        printers[identifier.uuidString] = name
        guard let data = try? JSONSerialization.data(withJSONObject: printers, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
    }

    private func read() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let printers = object as? [String: String]
        else {
            return [:]
        }
        return printers
    }
}
