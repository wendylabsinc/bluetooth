// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Bluetooth",
    platforms: [
        .iOS("26.0"),
        .macOS("26.0"),
        .tvOS("26.0"),
        .watchOS("26.0"),
        .visionOS("26.0"),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "Bluetooth",
            targets: ["Bluetooth"]
        ),
        .executable(
            name: "BluetoothAdvertisingExample",
            targets: ["BluetoothAdvertisingExample"]
        ),
        .executable(
            name: "BluetoothGATTExample",
            targets: ["BluetoothGATTExample"]
        ),
    ],
    traits: [
        .default(enabledTraits: []),
        .trait(name: "backend_corebluetooth", description: "Force the CoreBluetooth backend.", enabledTraits: []),
        .trait(name: "backend_bluez", description: "Force the BlueZ backend.", enabledTraits: []),
        .trait(name: "backend_windows", description: "Force the Windows Bluetooth backend.", enabledTraits: []),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "Bluetooth",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .define(
                    "BLUETOOTH_BACKEND_FORCE_COREBLUETOOTH",
                    .when(platforms: nil, configuration: nil, traits: ["backend_corebluetooth"])
                ),
                .define(
                    "BLUETOOTH_BACKEND_FORCE_BLUEZ",
                    .when(platforms: nil, configuration: nil, traits: ["backend_bluez"])
                ),
                .define(
                    "BLUETOOTH_BACKEND_FORCE_WINDOWS",
                    .when(platforms: nil, configuration: nil, traits: ["backend_windows"])
                ),
            ]
        ),
        .testTarget(
            name: "BluetoothTests",
            dependencies: ["Bluetooth"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "BluetoothAdvertisingExample",
            dependencies: [
                "Bluetooth",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Examples/Advertising",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "BluetoothGATTExample",
            dependencies: [
                "Bluetooth",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Examples/GATT",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
