S = "Sources/ThermalPrinter/"
T = "ThermalPrinterTests/"
MUTATIONS = [
    {"name": "selftest-survivor", "round": 0, "file": S + "EscPosBluetooth.swift",
     "old": "    static var scanDuration: TimeInterval = 3\n", "new": "    static var scanDuration: TimeInterval = 4\n",
     "tests": [T + "BluetoothDiscoveryTests/testFallbackLabelIsStableForAPeripheral"]},
    {"name": "selftest-build-failure", "round": 0, "file": S + "EscPosQueue.swift",
     "old": "    var isCurrent: Bool {", "new": "    var isCurrent: Bool = {",
     "tests": [T + "BluetoothDiscoveryTests/testFallbackLabelIsStableForAPeripheral"]},
]
