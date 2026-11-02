import CoreBluetooth
import Foundation

enum EscPosBluetoothRules {
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

    static let standardServices: [CBUUID] = [
        CBUUID(string: "1800"),
        CBUUID(string: "1801"),
        CBUUID(string: "180A"),
        CBUUID(string: "180F"),
    ]

    static let printerNameFragments = ["print", "thermal", "receipt"]
    static let printerNamePrefixes = ["mpt", "mtp", "rpp", "xp-", "pt-", "zj-", "pos", "goojprt", "peripage"]

    static func isPrinterCandidate(name: String?, advertisedServices: [CBUUID], connectable: Bool?) -> Bool {
        if connectable == false {
            return false
        }
        if advertisedServices.contains(where: { printerServices.contains($0) }) {
            return true
        }
        guard let name = name?.lowercased(), !name.isEmpty else {
            return false
        }
        return printerNameFragments.contains { name.contains($0) } || printerNamePrefixes.contains { name.hasPrefix($0) }
    }

    static func writeType(for properties: CBCharacteristicProperties) -> CBCharacteristicWriteType? {
        if properties.contains(.writeWithoutResponse) {
            return .withoutResponse
        }
        if properties.contains(.write) {
            return .withResponse
        }
        return nil
    }

    static func selectCharacteristic(in services: [CBService]) -> (CBCharacteristic, CBCharacteristicWriteType)? {
        let characteristics = services.flatMap { $0.characteristics ?? [] }
        for uuid in printerCharacteristics {
            if let match = characteristics.first(where: { $0.uuid == uuid }), let type = writeType(for: match.properties) {
                return (match, type)
            }
        }
        for uuid in printerServices {
            for service in services where service.uuid == uuid {
                for characteristic in service.characteristics ?? [] {
                    if let type = writeType(for: characteristic.properties) {
                        return (characteristic, type)
                    }
                }
            }
        }
        let vendorWritable = services
            .filter { !standardServices.contains($0.uuid) }
            .flatMap { $0.characteristics ?? [] }
            .compactMap { characteristic in writeType(for: characteristic.properties).map { (characteristic, $0) } }
        return vendorWritable.count == 1 ? vendorWritable[0] : nil
    }
}
