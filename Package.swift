// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BricksSoftCapacitorThermalPrinter",
    platforms: [.iOS(.v15)],
    products: [.library(name: "BricksSoftCapacitorThermalPrinter", targets: ["ThermalPrinter"])],
    dependencies: [.package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0")],
    targets: [
        .target(name: "ThermalPrinter", dependencies: [.product(name: "Capacitor", package: "capacitor-swift-pm"), .product(name: "Cordova", package: "capacitor-swift-pm")], path: "ios/Sources/ThermalPrinter"),
        .testTarget(name: "ThermalPrinterTests", dependencies: ["ThermalPrinter"], path: "ios/Tests/ThermalPrinterTests", resources: [.copy("Fixtures")])
    ]
)
