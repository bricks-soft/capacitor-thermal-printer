import Foundation

class EscPosDeviceConnection: NSObject {
    private(set) var data: [UInt8] = []
    var pacesSends = true

    var isConnected: Bool { false }

    @discardableResult
    func connect() throws -> EscPosDeviceConnection { self }

    @discardableResult
    func disconnect() -> EscPosDeviceConnection {
        data = []
        return self
    }

    func transmit(_ bytes: [UInt8]) throws {}

    func write(_ bytes: [UInt8]) {
        data.append(contentsOf: bytes)
    }

    func send(_ addWaitingTime: Int = 0) throws {
        guard isConnected else {
            throw EscPosError.connection("Unable to send data to device.")
        }
        let payload = data
        try transmit(payload)
        let waitingTime = addWaitingTime + payload.count / 16
        data = []
        if pacesSends && waitingTime > 0 {
            Thread.sleep(forTimeInterval: Double(waitingTime) / 1000.0)
        }
    }

    func clearBuffer() {
        data = []
    }
}
