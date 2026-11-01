// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "ThermalPrinter",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "ThermalPrinter", targets: ["ThermalPrinter"]),
    ],
    targets: [
        .target(name: "ThermalPrinter", path: "Sources/ThermalPrinter"),
        .testTarget(
            name: "ThermalPrinterTests",
            dependencies: ["ThermalPrinter"],
            path: "Tests/ThermalPrinterTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
