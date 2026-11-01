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

protocol EscPosDiscoveredPeripheral: AnyObject {
    var identifier: UUID { get }
    var name: String? { get }
}

extension CBPeripheral: EscPosDiscoveredPeripheral {}

struct EscPosBluetoothDevice {
    let peripheral: EscPosDiscoveredPeripheral
    let name: String?
    let services: [CBUUID]
    let isPrinterCandidate: Bool

    var identifier: UUID { peripheral.identifier }
}

final class EscPosBluetoothCentral: NSObject, CBCentralManagerDelegate {
    static var scanDuration: TimeInterval = 3
    static var stateTimeout: TimeInterval = 10
    static var authorizationTimeout: TimeInterval = 60

    static func fallbackName(for identifier: UUID) -> String {
        "BLE Printer \(identifier.uuidString.prefix(4))"
    }

    let queue = EscPosQueue(label: "de.paystory.thermal-printer.bluetooth")
    private let authorizationSource: () -> CBManagerAuthorization
    private let makeManager: (EscPosBluetoothCentral) -> EscPosCentralManaging
    private let store: EscPosKnownPrinterStore
    private var manager: EscPosCentralManaging?
    private var stateEvent: DispatchSemaphore?
    private var scanEvent: DispatchSemaphore?
    private var scanMatch: ((EscPosBluetoothDevice) -> Bool)?
    private var scanResults: [EscPosBluetoothDevice] = []
    private var lastScanResults: [EscPosBluetoothDevice] = []
    private var displayNames: [UUID: String] = [:]
    private var connections: [UUID: EscPosBluetoothConnection] = [:]
    private var links: [UUID: EscPosCoreBluetoothLink] = [:]
    private var linkedPeripherals: [UUID: CBPeripheral] = [:]

    init(
        authorization: @escaping () -> CBManagerAuthorization = { CBManager.authorization },
        store: EscPosKnownPrinterStore = EscPosKnownPrinterStore(),
        makeManager: ((EscPosBluetoothCentral) -> EscPosCentralManaging)? = nil
    ) {
        self.authorizationSource = authorization
        self.store = store
        self.makeManager = makeManager ?? { central in
            CBCentralManager(delegate: central, queue: central.queue.queue, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
        super.init()
    }

    var authorization: CBManagerAuthorization {
        authorizationSource()
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
                link.handleDisconnected(nil)
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
            for (identifier, link) in links where link.isConnected {
                if let peripheral = linkedPeripherals[identifier] {
                    add(peripheral)
                }
            }
            let remembered = store.load().keys.compactMap { UUID(uuidString: $0) }
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
        if let peripheral = queue.sync({ lastScanResults.first(where: matchesName)?.peripheral as? CBPeripheral }) {
            return peripheral
        }
        if let peripheral = knownDevices().first(where: matchesName)?.peripheral as? CBPeripheral {
            return peripheral
        }
        return scan(duration: EscPosBluetoothCentral.scanDuration, until: matchesName).first(where: matchesName)?.peripheral as? CBPeripheral
    }

    func candidatesForFirst() -> [CBPeripheral] {
        let known = knownDevices()
        if !known.isEmpty {
            return known.compactMap { $0.peripheral as? CBPeripheral }
        }
        return scan(duration: EscPosBluetoothCentral.scanDuration).filter(\.isPrinterCandidate).compactMap { $0.peripheral as? CBPeripheral }
    }

    func connection(for peripheral: CBPeripheral) -> EscPosBluetoothConnection {
        queue.sync {
            if let existing = connections[peripheral.identifier] {
                return existing
            }
            let link = EscPosCoreBluetoothLink(driver: EscPosCBPeripheralDriver(peripheral: peripheral, central: self), queue: queue)
            links[peripheral.identifier] = link
            linkedPeripherals[peripheral.identifier] = peripheral
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
        let name = queue.sync { displayName(for: peripheral) ?? peripheral.name ?? EscPosBluetoothCentral.fallbackName(for: peripheral.identifier) }
        store.remember(identifier: peripheral.identifier, name: name)
    }

    func record(_ peripheral: EscPosDiscoveredPeripheral, advertisementData: [String: Any]) {
        guard scanEvent != nil else { return }
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        if connectable == false {
            return
        }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let advertisedName = [localName, peripheral.name].compactMap { $0 }.first { !$0.isEmpty }
        let isPrinterCandidate = EscPosBluetoothRules.isPrinterCandidate(name: advertisedName, advertisedServices: services, connectable: connectable)
        guard advertisedName != nil || isPrinterCandidate else { return }
        if displayNames[peripheral.identifier] == nil {
            displayNames[peripheral.identifier] = advertisedName ?? EscPosBluetoothCentral.fallbackName(for: peripheral.identifier)
        }
        guard !scanResults.contains(where: { $0.identifier == peripheral.identifier }) else { return }
        let device = EscPosBluetoothDevice(
            peripheral: peripheral,
            name: displayName(for: peripheral),
            services: services,
            isPrinterCandidate: isPrinterCandidate
        )
        scanResults.append(device)
        if let match = scanMatch, match(device) {
            scanEvent?.signal()
        }
    }

    private func displayName(for peripheral: EscPosDiscoveredPeripheral) -> String? {
        if let remembered = store.load()[peripheral.identifier.uuidString], !remembered.isEmpty {
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
        record(peripheral, advertisementData: advertisementData)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        links[peripheral.identifier]?.handleConnected()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        links[peripheral.identifier]?.handleFailedToConnect(error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        links[peripheral.identifier]?.handleDisconnected(error)
    }
}
