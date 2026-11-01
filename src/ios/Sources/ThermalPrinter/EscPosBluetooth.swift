import CoreBluetooth
import Foundation

struct EscPosBluetoothDevice {
    let peripheral: CBPeripheral
    let name: String?
    let services: [CBUUID]

    var identifier: UUID { peripheral.identifier }
}

final class EscPosBluetoothCentral: NSObject, CBCentralManagerDelegate {
    static let printerServices: [CBUUID] = [
        CBUUID(string: "18F0"),
        CBUUID(string: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2"),
        CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455"),
        CBUUID(string: "FF00"),
        CBUUID(string: "FFE0"),
        CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"),
    ]

    static let printerCharacteristics: [CBUUID] = [
        CBUUID(string: "2AF1"),
        CBUUID(string: "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F"),
        CBUUID(string: "49535343-8841-43F4-A8D4-ECBE34729BB3"),
        CBUUID(string: "FF02"),
        CBUUID(string: "FFE1"),
        CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"),
    ]

    static let systemServices: [CBUUID] = [
        CBUUID(string: "1800"),
        CBUUID(string: "1801"),
        CBUUID(string: "180A"),
        CBUUID(string: "180F"),
    ]

    static var scanDuration: TimeInterval = 3
    static var stateTimeout: TimeInterval = 10
    static var authorizationTimeout: TimeInterval = 60

    private static let knownPeripheralsKey = "ThermalPrinterKnownBluetoothPeripherals"
    private static let queueKey = DispatchSpecificKey<Bool>()

    let queue = DispatchQueue(label: "de.paystory.thermal-printer.bluetooth")
    private var manager: CBCentralManager?
    private var stateEvent: DispatchSemaphore?
    private var scanEvent: DispatchSemaphore?
    private var scanMatch: ((EscPosBluetoothDevice) -> Bool)?
    private var scanResults: [EscPosBluetoothDevice] = []
    private var lastScanResults: [EscPosBluetoothDevice] = []
    private var displayNames: [UUID: String] = [:]
    private var connections: [UUID: EscPosBluetoothConnection] = [:]

    override init() {
        super.init()
        queue.setSpecific(key: EscPosBluetoothCentral.queueKey, value: true)
    }

    func sync<T>(_ block: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: EscPosBluetoothCentral.queueKey) == true {
            return try block()
        }
        return try queue.sync(execute: block)
    }

    var authorization: CBManagerAuthorization {
        CBManager.authorization
    }

    func waitForAuthorization() -> CBManagerAuthorization {
        if authorization != .notDetermined {
            return authorization
        }
        _ = sync { ensureManager() }
        let deadline = Date().addingTimeInterval(EscPosBluetoothCentral.authorizationTimeout)
        while authorization == .notDetermined && Date() < deadline {
            let event = sync { () -> DispatchSemaphore in
                let semaphore = DispatchSemaphore(value: 0)
                stateEvent = semaphore
                return semaphore
            }
            _ = event.wait(timeout: .now() + 0.5)
        }
        return authorization
    }

    func waitForState() -> CBManagerState {
        let deadline = Date().addingTimeInterval(EscPosBluetoothCentral.stateTimeout)
        while true {
            let (state, event) = sync { () -> (CBManagerState, DispatchSemaphore) in
                let current = ensureManager().state
                let semaphore = DispatchSemaphore(value: 0)
                stateEvent = semaphore
                return (current, semaphore)
            }
            if state != .unknown && state != .resetting {
                return state
            }
            if Date() >= deadline {
                return state
            }
            _ = event.wait(timeout: .now() + 0.5)
        }
    }

    func knownDevices() -> [EscPosBluetoothDevice] {
        sync {
            guard let manager = manager else { return [] }
            var devices: [EscPosBluetoothDevice] = []
            var seen = Set<UUID>()
            func add(_ peripheral: CBPeripheral) {
                guard !seen.contains(peripheral.identifier) else { return }
                seen.insert(peripheral.identifier)
                devices.append(EscPosBluetoothDevice(peripheral: peripheral, name: displayName(for: peripheral), services: []))
            }
            for connection in connections.values where connection.peripheral.state == .connected {
                add(connection.peripheral)
            }
            let remembered = rememberedPeripherals().keys.compactMap { UUID(uuidString: $0) }
            if !remembered.isEmpty {
                manager.retrievePeripherals(withIdentifiers: remembered).forEach(add)
            }
            manager.retrieveConnectedPeripherals(withServices: EscPosBluetoothCentral.printerServices).forEach(add)
            return devices
        }
    }

    func scan(duration: TimeInterval, until match: ((EscPosBluetoothDevice) -> Bool)? = nil) -> [EscPosBluetoothDevice] {
        let event: DispatchSemaphore? = sync {
            guard let manager = manager, manager.state == .poweredOn else { return nil }
            let semaphore = DispatchSemaphore(value: 0)
            scanResults = []
            scanMatch = match
            scanEvent = semaphore
            manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            return semaphore
        }
        guard let semaphore = event else { return [] }
        _ = semaphore.wait(timeout: .now() + duration)
        return sync {
            manager?.stopScan()
            scanEvent = nil
            scanMatch = nil
            lastScanResults = scanResults
            return scanResults
        }
    }

    func listDevices() -> [EscPosBluetoothDevice] {
        var devices = knownDevices()
        var seen = Set(devices.map(\.identifier))
        for device in scan(duration: EscPosBluetoothCentral.scanDuration) where !seen.contains(device.identifier) {
            seen.insert(device.identifier)
            devices.append(device)
        }
        return devices
    }

    func findPeripheral(id: String, address: String?) -> CBPeripheral? {
        let keys = [id, address ?? ""].filter { !$0.isEmpty }
        let byIdentifier: CBPeripheral? = sync {
            guard let manager = manager else { return nil }
            for key in keys {
                if let uuid = UUID(uuidString: key), let peripheral = manager.retrievePeripherals(withIdentifiers: [uuid]).first {
                    return peripheral
                }
            }
            return nil
        }
        if let peripheral = byIdentifier {
            return peripheral
        }
        let matchesName: (EscPosBluetoothDevice) -> Bool = { device in
            device.name == id || device.peripheral.name == id
        }
        let cached: CBPeripheral? = sync { lastScanResults.first(where: matchesName)?.peripheral }
        if let peripheral = cached {
            return peripheral
        }
        if let peripheral = knownDevices().first(where: matchesName)?.peripheral {
            return peripheral
        }
        return scan(duration: EscPosBluetoothCentral.scanDuration, until: matchesName).first(where: matchesName)?.peripheral
    }

    func candidatesForFirst() -> [CBPeripheral] {
        let known = knownDevices()
        if !known.isEmpty {
            return known.map(\.peripheral)
        }
        return scan(duration: EscPosBluetoothCentral.scanDuration).map(\.peripheral)
    }

    func connection(for peripheral: CBPeripheral) -> EscPosBluetoothConnection {
        sync {
            if let existing = connections[peripheral.identifier] {
                return existing
            }
            let created = EscPosBluetoothConnection(central: self, peripheral: peripheral)
            connections[peripheral.identifier] = created
            return created
        }
    }

    func startConnecting(_ peripheral: CBPeripheral) {
        sync { manager?.connect(peripheral, options: nil) }
    }

    func cancelConnection(_ peripheral: CBPeripheral) {
        sync { manager?.cancelPeripheralConnection(peripheral) }
    }

    func remember(_ peripheral: CBPeripheral) {
        sync {
            var remembered = rememberedPeripherals()
            remembered[peripheral.identifier.uuidString] = displayName(for: peripheral) ?? peripheral.name ?? ""
            UserDefaults.standard.set(remembered, forKey: EscPosBluetoothCentral.knownPeripheralsKey)
        }
    }

    private func rememberedPeripherals() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: EscPosBluetoothCentral.knownPeripheralsKey) as? [String: String] ?? [:]
    }

    private func displayName(for peripheral: CBPeripheral) -> String? {
        if let remembered = rememberedPeripherals()[peripheral.identifier.uuidString], !remembered.isEmpty {
            return remembered
        }
        if let name = displayNames[peripheral.identifier], !name.isEmpty {
            return name
        }
        return peripheral.name
    }

    @discardableResult
    private func ensureManager() -> CBCentralManager {
        if let manager = manager {
            return manager
        }
        let created = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        manager = created
        return created
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        stateEvent?.signal()
        if central.state != .poweredOn {
            for connection in connections.values {
                connection.handleDisconnected(error: nil)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanEvent != nil else { return }
        if let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber, !connectable.boolValue {
            return
        }
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = [localName, peripheral.name].compactMap { $0 }.first { !$0.isEmpty }
        guard let resolvedName = name else { return }
        if displayNames[peripheral.identifier] == nil {
            displayNames[peripheral.identifier] = resolvedName
        }
        guard !scanResults.contains(where: { $0.identifier == peripheral.identifier }) else { return }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let device = EscPosBluetoothDevice(peripheral: peripheral, name: displayName(for: peripheral), services: services)
        scanResults.append(device)
        if let match = scanMatch, match(device) {
            scanEvent?.signal()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connections[peripheral.identifier]?.handleConnected()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connections[peripheral.identifier]?.handleDisconnected(error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connections[peripheral.identifier]?.handleDisconnected(error: error)
    }
}

final class EscPosBluetoothConnection: EscPosDeviceConnection, CBPeripheralDelegate {
    static var connectTimeout: TimeInterval = 10
    static var discoveryTimeout: TimeInterval = 10
    static var writeTimeout: TimeInterval = 10

    let peripheral: CBPeripheral
    private unowned let central: EscPosBluetoothCentral
    private var characteristic: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType = .withoutResponse
    private var event: DispatchSemaphore?
    private var readyEvent: DispatchSemaphore?
    private var lastError: Error?
    private var linkUp = false
    private var pendingCharacteristicDiscoveries = 0

    init(central: EscPosBluetoothCentral, peripheral: CBPeripheral) {
        self.central = central
        self.peripheral = peripheral
        super.init()
    }

    override var isConnected: Bool {
        central.sync { linkUp && peripheral.state == .connected && characteristic != nil }
    }

    @discardableResult
    override func connect() throws -> EscPosDeviceConnection {
        if isConnected {
            return self
        }
        do {
            try establishLink()
            try discoverWritableCharacteristic()
        } catch {
            central.cancelConnection(peripheral)
            central.sync {
                linkUp = false
                characteristic = nil
            }
            throw EscPosError.connection("Unable to connect to bluetooth device.")
        }
        central.remember(peripheral)
        clearBuffer()
        return self
    }

    @discardableResult
    override func disconnect() -> EscPosDeviceConnection {
        clearBuffer()
        central.sync {
            linkUp = false
            characteristic = nil
        }
        central.cancelConnection(peripheral)
        return self
    }

    override func transmit(_ bytes: [UInt8]) throws {
        let target: (CBCharacteristic, CBCharacteristicWriteType, Int)? = central.sync {
            guard linkUp, peripheral.state == .connected, let characteristic = characteristic else { return nil }
            return (characteristic, writeType, max(20, peripheral.maximumWriteValueLength(for: writeType)))
        }
        guard let (characteristic, type, chunkSize) = target else {
            throw EscPosError.connection("Unable to send data to device.")
        }
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            let chunk = Data(bytes[offset..<end])
            if type == .withoutResponse {
                try waitUntilReadyToWrite()
                central.sync { peripheral.writeValue(chunk, for: characteristic, type: .withoutResponse) }
            } else {
                let semaphore = central.sync { () -> DispatchSemaphore in
                    lastError = nil
                    let semaphore = DispatchSemaphore(value: 0)
                    event = semaphore
                    peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
                    return semaphore
                }
                if semaphore.wait(timeout: .now() + EscPosBluetoothConnection.writeTimeout) == .timedOut {
                    throw EscPosError.connection("Timed out while sending data to device.")
                }
                if let error = central.sync({ lastError }) {
                    throw EscPosError.connection(error.localizedDescription)
                }
            }
            if !central.sync({ linkUp }) {
                throw EscPosError.connection("Bluetooth device disconnected.")
            }
            offset = end
        }
    }

    private func waitUntilReadyToWrite() throws {
        let deadline = Date().addingTimeInterval(EscPosBluetoothConnection.writeTimeout)
        while true {
            let (ready, connected, semaphore) = central.sync { () -> (Bool, Bool, DispatchSemaphore) in
                let semaphore = DispatchSemaphore(value: 0)
                readyEvent = semaphore
                return (peripheral.canSendWriteWithoutResponse, linkUp, semaphore)
            }
            if !connected {
                throw EscPosError.connection("Bluetooth device disconnected.")
            }
            if ready {
                return
            }
            if Date() >= deadline {
                throw EscPosError.connection("Timed out while sending data to device.")
            }
            _ = semaphore.wait(timeout: .now() + 0.05)
        }
    }

    private func establishLink() throws {
        if central.sync({ peripheral.state == .connected && linkUp }) {
            return
        }
        let semaphore = central.sync { () -> DispatchSemaphore in
            lastError = nil
            linkUp = false
            let semaphore = DispatchSemaphore(value: 0)
            event = semaphore
            peripheral.delegate = self
            return semaphore
        }
        central.startConnecting(peripheral)
        if semaphore.wait(timeout: .now() + EscPosBluetoothConnection.connectTimeout) == .timedOut {
            throw EscPosError.connection("Unable to connect to bluetooth device.")
        }
        guard central.sync({ linkUp }) else {
            throw EscPosError.connection("Unable to connect to bluetooth device.")
        }
    }

    private func discoverWritableCharacteristic() throws {
        let semaphore = central.sync { () -> DispatchSemaphore in
            lastError = nil
            characteristic = nil
            pendingCharacteristicDiscoveries = 0
            let semaphore = DispatchSemaphore(value: 0)
            event = semaphore
            peripheral.delegate = self
            peripheral.discoverServices(nil)
            return semaphore
        }
        if semaphore.wait(timeout: .now() + EscPosBluetoothConnection.discoveryTimeout) == .timedOut {
            throw EscPosError.connection("Unable to connect to bluetooth device.")
        }
        let selected: (CBCharacteristic, CBCharacteristicWriteType)? = central.sync {
            guard lastError == nil else { return nil }
            return EscPosBluetoothConnection.selectCharacteristic(in: peripheral.services ?? [])
        }
        guard let (found, type) = selected else {
            throw EscPosError.connection("Unable to connect to bluetooth device.")
        }
        central.sync {
            characteristic = found
            writeType = type
        }
    }

    static func selectCharacteristic(in services: [CBService]) -> (CBCharacteristic, CBCharacteristicWriteType)? {
        func writable(_ characteristic: CBCharacteristic) -> CBCharacteristicWriteType? {
            if characteristic.properties.contains(.writeWithoutResponse) {
                return .withoutResponse
            }
            if characteristic.properties.contains(.write) {
                return .withResponse
            }
            return nil
        }
        let characteristics = services.flatMap { $0.characteristics ?? [] }
        for uuid in EscPosBluetoothCentral.printerCharacteristics {
            if let match = characteristics.first(where: { $0.uuid == uuid }), let type = writable(match) {
                return (match, type)
            }
        }
        for uuid in EscPosBluetoothCentral.printerServices {
            for service in services where service.uuid == uuid {
                for characteristic in service.characteristics ?? [] {
                    if let type = writable(characteristic) {
                        return (characteristic, type)
                    }
                }
            }
        }
        for service in services where !EscPosBluetoothCentral.systemServices.contains(service.uuid) {
            for characteristic in service.characteristics ?? [] {
                if let type = writable(characteristic) {
                    return (characteristic, type)
                }
            }
        }
        return nil
    }

    func handleConnected() {
        linkUp = true
        event?.signal()
    }

    func handleDisconnected(error: Error?) {
        linkUp = false
        characteristic = nil
        lastError = error
        event?.signal()
        readyEvent?.signal()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            lastError = error
            event?.signal()
            return
        }
        let services = peripheral.services ?? []
        if services.isEmpty {
            event?.signal()
            return
        }
        pendingCharacteristicDiscoveries = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        pendingCharacteristicDiscoveries -= 1
        if pendingCharacteristicDiscoveries <= 0 {
            event?.signal()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        lastError = error
        event?.signal()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        readyEvent?.signal()
    }
}
