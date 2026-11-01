import CoreBluetooth
import Foundation

protocol EscPosCentralManaging: AnyObject {
    var state: CBManagerState { get }
    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?)
    func stopScan()
    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [CBPeripheral]
    func retrieveConnectedPeripherals(withServices serviceUUIDs: [CBUUID]) -> [CBPeripheral]
    func connect(_ peripheral: CBPeripheral, options: [String: Any]?)
    func cancelPeripheralConnection(_ peripheral: CBPeripheral)
}

extension CBCentralManager: EscPosCentralManaging {}

struct EscPosBluetoothDevice {
    let peripheral: CBPeripheral
    let name: String?
    let services: [CBUUID]
    let isPrinterCandidate: Bool

    var identifier: UUID { peripheral.identifier }
}

final class EscPosBluetoothCentral: NSObject, CBCentralManagerDelegate {
    static var scanDuration: TimeInterval = 3
    static var stateTimeout: TimeInterval = 10
    static var authorizationTimeout: TimeInterval = 60

    private static let knownPeripheralsKey = "ThermalPrinterKnownBluetoothPeripherals"

    let queue = EscPosQueue(label: "de.paystory.thermal-printer.bluetooth")
    private let authorizationSource: () -> CBManagerAuthorization
    private let makeManager: (EscPosBluetoothCentral) -> EscPosCentralManaging
    private let defaults: UserDefaults
    private var manager: EscPosCentralManaging?
    private var stateEvent: DispatchSemaphore?
    private var scanEvent: DispatchSemaphore?
    private var scanMatch: ((EscPosBluetoothDevice) -> Bool)?
    private var scanResults: [EscPosBluetoothDevice] = []
    private var lastScanResults: [EscPosBluetoothDevice] = []
    private var displayNames: [UUID: String] = [:]
    private var connections: [UUID: EscPosBluetoothConnection] = [:]
    private var links: [UUID: EscPosCoreBluetoothLink] = [:]

    init(
        authorization: @escaping () -> CBManagerAuthorization = { CBManager.authorization },
        defaults: UserDefaults = .standard,
        makeManager: ((EscPosBluetoothCentral) -> EscPosCentralManaging)? = nil
    ) {
        self.authorizationSource = authorization
        self.defaults = defaults
        self.makeManager = makeManager ?? { central in
            CBCentralManager(delegate: central, queue: central.queue.queue, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
        super.init()
    }

    var authorization: CBManagerAuthorization {
        authorizationSource()
    }

    var managerCreated: Bool {
        queue.sync { manager != nil }
    }

    func waitForAuthorization() -> CBManagerAuthorization {
        if authorization != .notDetermined {
            return authorization
        }
        _ = queue.sync { ensureManager() }
        let deadline = Date().addingTimeInterval(EscPosBluetoothCentral.authorizationTimeout)
        while authorization == .notDetermined && Date() < deadline {
            let event = queue.sync { () -> DispatchSemaphore in
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
            let (state, event) = queue.sync { () -> (CBManagerState, DispatchSemaphore) in
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

    func handleStateUpdate() {
        queue.sync {
            stateEvent?.signal()
            guard let manager = manager, manager.state != .poweredOn else { return }
            for link in links.values {
                link.events?.linkDidDisconnect(nil)
            }
        }
    }

    func knownDevices() -> [EscPosBluetoothDevice] {
        queue.sync {
            guard let manager = manager else { return [] }
            var devices: [EscPosBluetoothDevice] = []
            var seen = Set<UUID>()
            func add(_ peripheral: CBPeripheral) {
                guard !seen.contains(peripheral.identifier) else { return }
                seen.insert(peripheral.identifier)
                devices.append(EscPosBluetoothDevice(peripheral: peripheral, name: displayName(for: peripheral), services: [], isPrinterCandidate: true))
            }
            for link in links.values where link.isConnected {
                add(link.peripheral)
            }
            let remembered = rememberedPeripherals().keys.compactMap { UUID(uuidString: $0) }
            if !remembered.isEmpty {
                manager.retrievePeripherals(withIdentifiers: remembered).forEach(add)
            }
            manager.retrieveConnectedPeripherals(withServices: EscPosBluetoothRules.printerServices).forEach(add)
            return devices
        }
    }

    func scan(duration: TimeInterval, until match: ((EscPosBluetoothDevice) -> Bool)? = nil) -> [EscPosBluetoothDevice] {
        let event: DispatchSemaphore? = queue.sync {
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
        return queue.sync {
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
        for device in scan(duration: EscPosBluetoothCentral.scanDuration) where device.isPrinterCandidate && !seen.contains(device.identifier) {
            seen.insert(device.identifier)
            devices.append(device)
        }
        return devices
    }

    func findPeripheral(id: String, address: String?) -> CBPeripheral? {
        let keys = [id, address ?? ""].filter { !$0.isEmpty }
        let byIdentifier: CBPeripheral? = queue.sync {
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
        if let peripheral = queue.sync({ lastScanResults.first(where: matchesName)?.peripheral }) {
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
        return scan(duration: EscPosBluetoothCentral.scanDuration).filter(\.isPrinterCandidate).map(\.peripheral)
    }

    func connection(for peripheral: CBPeripheral) -> EscPosBluetoothConnection {
        queue.sync {
            if let existing = connections[peripheral.identifier] {
                return existing
            }
            let link = EscPosCoreBluetoothLink(peripheral: peripheral, central: self)
            links[peripheral.identifier] = link
            let created = EscPosBluetoothConnection(link: link, queue: queue) { [weak self] in
                self?.remember(peripheral)
            }
            connections[peripheral.identifier] = created
            return created
        }
    }

    func startConnecting(_ peripheral: CBPeripheral) {
        queue.sync { manager?.connect(peripheral, options: nil) }
    }

    func cancelConnection(_ peripheral: CBPeripheral) {
        queue.sync { manager?.cancelPeripheralConnection(peripheral) }
    }

    func remember(_ peripheral: CBPeripheral) {
        queue.sync {
            var remembered = rememberedPeripherals()
            remembered[peripheral.identifier.uuidString] = displayName(for: peripheral) ?? peripheral.name ?? ""
            defaults.set(remembered, forKey: EscPosBluetoothCentral.knownPeripheralsKey)
        }
    }

    private func rememberedPeripherals() -> [String: String] {
        defaults.dictionary(forKey: EscPosBluetoothCentral.knownPeripheralsKey) as? [String: String] ?? [:]
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
    private func ensureManager() -> EscPosCentralManaging {
        if let manager = manager {
            return manager
        }
        let created = makeManager(self)
        manager = created
        return created
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        handleStateUpdate()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanEvent != nil else { return }
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        if connectable == false {
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
        let device = EscPosBluetoothDevice(
            peripheral: peripheral,
            name: displayName(for: peripheral),
            services: services,
            isPrinterCandidate: EscPosBluetoothRules.isPrinterCandidate(name: resolvedName, advertisedServices: services, connectable: connectable)
        )
        scanResults.append(device)
        if let match = scanMatch, match(device) {
            scanEvent?.signal()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        links[peripheral.identifier]?.events?.linkDidConnect()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        links[peripheral.identifier]?.events?.linkDidFailToConnect(error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        links[peripheral.identifier]?.events?.linkDidDisconnect(error)
    }
}

final class EscPosCoreBluetoothLink: NSObject, EscPosBluetoothLink, CBPeripheralDelegate {
    let peripheral: CBPeripheral
    weak var events: EscPosBluetoothLinkEvents?
    private unowned let central: EscPosBluetoothCentral
    private var characteristic: CBCharacteristic?
    private var pendingCharacteristicDiscoveries = 0

    init(peripheral: CBPeripheral, central: EscPosBluetoothCentral) {
        self.peripheral = peripheral
        self.central = central
        super.init()
    }

    var isConnected: Bool { peripheral.state == .connected }

    var canSendWriteWithoutResponse: Bool { peripheral.canSendWriteWithoutResponse }

    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int {
        peripheral.maximumWriteValueLength(for: type)
    }

    func connect() {
        peripheral.delegate = self
        central.startConnecting(peripheral)
    }

    func cancel() {
        characteristic = nil
        central.cancelConnection(peripheral)
    }

    func discoverPrinterCharacteristic() {
        characteristic = nil
        pendingCharacteristicDiscoveries = 0
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func write(_ data: Data, type: CBCharacteristicWriteType) {
        guard let characteristic = characteristic else {
            if type == .withResponse {
                events?.linkDidWrite(EscPosError.connection("Unable to send data to device."))
            }
            return
        }
        peripheral.writeValue(data, for: characteristic, type: type)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            events?.linkDidDiscover(writeType: nil, error: error)
            return
        }
        let services = peripheral.services ?? []
        if services.isEmpty {
            finishDiscovery()
            return
        }
        pendingCharacteristicDiscoveries = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        pendingCharacteristicDiscoveries -= 1
        if pendingCharacteristicDiscoveries == 0 {
            finishDiscovery()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        events?.linkDidWrite(error)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        events?.linkIsReadyToSend()
    }

    private func finishDiscovery() {
        if let (found, type) = EscPosBluetoothRules.selectCharacteristic(in: peripheral.services ?? []) {
            characteristic = found
            events?.linkDidDiscover(writeType: type, error: nil)
        } else {
            events?.linkDidDiscover(writeType: nil, error: nil)
        }
    }
}
