import CoreBluetooth
import Foundation

protocol EscPosPeripheralDriver: AnyObject {
    var isAvailable: Bool { get }
    var isConnected: Bool { get }
    var canSendWriteWithoutResponse: Bool { get }
    var services: [CBService] { get }
    func attach(_ delegate: CBPeripheralDelegate)
    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int
    func connect()
    func cancelConnection()
    func discoverServices()
    func discoverCharacteristics(for service: CBService)
    func write(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType)
}

final class EscPosCBPeripheralDriver: EscPosPeripheralDriver {
    let peripheral: CBPeripheral
    private unowned let central: EscPosBluetoothCentral

    init(peripheral: CBPeripheral, central: EscPosBluetoothCentral) {
        self.peripheral = peripheral
        self.central = central
    }

    var isAvailable: Bool { central.isPoweredOn }

    var isConnected: Bool { peripheral.state == .connected }

    var canSendWriteWithoutResponse: Bool { peripheral.canSendWriteWithoutResponse }

    var services: [CBService] { peripheral.services ?? [] }

    func attach(_ delegate: CBPeripheralDelegate) {
        peripheral.delegate = delegate
    }

    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int {
        peripheral.maximumWriteValueLength(for: type)
    }

    func connect() {
        central.startConnecting(peripheral)
    }

    func cancelConnection() {
        central.cancelConnection(peripheral)
    }

    func discoverServices() {
        peripheral.discoverServices(nil)
    }

    func discoverCharacteristics(for service: CBService) {
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func write(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        peripheral.writeValue(data, for: characteristic, type: type)
    }
}

final class EscPosCoreBluetoothLink: NSObject, EscPosBluetoothLink, CBPeripheralDelegate {
    weak var events: EscPosBluetoothLinkEvents?
    let driver: EscPosPeripheralDriver
    private var session: Int?
    private var pendingConnect: Int?
    private var closing: Int?
    private var queuedConnect: Int?
    private var pendingDiscovery: Int?
    private var pendingWrites: [Int] = []
    private var characteristic: CBCharacteristic?
    private var pendingCharacteristicDiscoveries = 0

    init(driver: EscPosPeripheralDriver) {
        self.driver = driver
        super.init()
    }

    var isCancelling: Bool { closing != nil }

    var isConnected: Bool { closing == nil && driver.isConnected }

    var canSendWriteWithoutResponse: Bool { driver.canSendWriteWithoutResponse }

    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int {
        driver.maximumWriteValueLength(for: type)
    }

    func connect(attempt: Int) {
        resetSession()
        if closing != nil {
            queuedConnect = attempt
            return
        }
        startConnecting(attempt)
    }

    func adopt(attempt: Int) {
        resetSession()
        if closing != nil {
            queuedConnect = attempt
            return
        }
        session = attempt
        driver.attach(self)
    }

    func cancel() {
        let open = session ?? pendingConnect
        queuedConnect = nil
        resetSession()
        pendingConnect = nil
        guard let open = open else { return }
        closing = open
        driver.cancelConnection()
    }

    func discoverPrinterCharacteristic(attempt: Int) {
        guard session == attempt else { return }
        characteristic = nil
        pendingCharacteristicDiscoveries = 0
        pendingDiscovery = attempt
        driver.discoverServices()
    }

    func write(_ data: Data, type: CBCharacteristicWriteType, token: Int) {
        guard session != nil, let characteristic = characteristic else {
            if type == .withResponse {
                events?.linkDidWrite(token: token, error: EscPosError.connection("Unable to send data to device."))
            }
            return
        }
        if type == .withResponse {
            pendingWrites.append(token)
        }
        driver.write(data, for: characteristic, type: type)
    }

    func handleConnected() {
        if closing != nil {
            return
        }
        guard let attempt = pendingConnect else { return }
        pendingConnect = nil
        session = attempt
        events?.linkDidConnect(attempt: attempt)
    }

    func handleFailedToConnect(_ error: Error?) {
        if let ended = closing {
            finishCancellation { $0.linkDidFailToConnect(attempt: ended, error: error) }
            return
        }
        guard let attempt = pendingConnect else { return }
        pendingConnect = nil
        events?.linkDidFailToConnect(attempt: attempt, error: error)
    }

    func handleDisconnected(_ error: Error?) {
        if let ended = closing {
            finishCancellation { $0.linkDidDisconnect(attempt: ended, error: error) }
            return
        }
        guard let live = session else { return }
        resetSession()
        events?.linkDidDisconnect(attempt: live, error: error)
    }

    func handleUnavailable() {
        let cancelled = closing
        let live = session
        let pending = pendingConnect
        let queued = queuedConnect
        resetSession()
        closing = nil
        pendingConnect = nil
        queuedConnect = nil
        guard let events = events else { return }
        if let cancelled = cancelled {
            events.linkDidDisconnect(attempt: cancelled, error: nil)
        }
        if let live = live {
            events.linkDidDisconnect(attempt: live, error: nil)
        }
        if let pending = pending {
            events.linkDidFailToConnect(attempt: pending, error: nil)
        }
        if let queued = queued {
            events.linkDidFailToConnect(attempt: queued, error: nil)
        }
    }

    func handleServicesDiscovered(error: Error?) {
        guard session != nil, let attempt = pendingDiscovery else { return }
        if let error = error {
            pendingDiscovery = nil
            events?.linkDidDiscover(attempt: attempt, writeType: nil, error: error)
            return
        }
        let services = driver.services
        if services.isEmpty {
            finishDiscovery()
            return
        }
        pendingCharacteristicDiscoveries = services.count
        for service in services {
            driver.discoverCharacteristics(for: service)
        }
    }

    func handleCharacteristicsDiscovered() {
        guard session != nil, pendingDiscovery != nil else { return }
        pendingCharacteristicDiscoveries -= 1
        if pendingCharacteristicDiscoveries == 0 {
            finishDiscovery()
        }
    }

    func handleWriteResponse(error: Error?) {
        guard session != nil, !pendingWrites.isEmpty else { return }
        events?.linkDidWrite(token: pendingWrites.removeFirst(), error: error)
    }

    func handleReadyToSend() {
        guard let attempt = session else { return }
        events?.linkIsReadyToSend(attempt: attempt)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        handleServicesDiscovered(error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        handleCharacteristicsDiscovered()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        handleWriteResponse(error: error)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        handleReadyToSend()
    }

    private func startConnecting(_ attempt: Int) {
        guard driver.isAvailable else {
            events?.linkDidFailToConnect(attempt: attempt, error: nil)
            return
        }
        pendingConnect = attempt
        driver.attach(self)
        driver.connect()
    }

    private func finishCancellation(_ report: (EscPosBluetoothLinkEvents) -> Void) {
        closing = nil
        let next = queuedConnect
        queuedConnect = nil
        if let events = events {
            report(events)
        }
        if let next = next {
            startConnecting(next)
        }
    }

    private func finishDiscovery() {
        guard let attempt = pendingDiscovery else { return }
        pendingDiscovery = nil
        if let (found, type) = EscPosBluetoothRules.selectCharacteristic(in: driver.services) {
            characteristic = found
            events?.linkDidDiscover(attempt: attempt, writeType: type, error: nil)
        } else {
            events?.linkDidDiscover(attempt: attempt, writeType: nil, error: nil)
        }
    }

    private func resetSession() {
        session = nil
        pendingDiscovery = nil
        pendingWrites = []
        characteristic = nil
        pendingCharacteristicDiscoveries = 0
    }
}
