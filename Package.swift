// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "Bluetooth",
  platforms: [
    .iOS(.v18),
    .macOS(.v15),
    .tvOS(.v18),
    .watchOS(.v11),
    .visionOS(.v2),
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
    .executable(
      name: "BluetoothL2CAPExample",
      targets: ["BluetoothL2CAPExample"]
    ),
    .executable(
      name: "BluetoothL2CAPClientExample",
      targets: ["BluetoothL2CAPClientExample"]
    ),
    .executable(
      name: "BluetoothDiscoveryExample",
      targets: ["BluetoothDiscoveryExample"]
    ),
    .executable(
      name: "BluetoothCentralPairingExample",
      targets: ["BluetoothCentralPairingExample"]
    ),
  ],
  traits: [
    .default(enabledTraits: []),
    .trait(
      name: "backend_corebluetooth", description: "Force the CoreBluetooth backend.",
      enabledTraits: []),
    .trait(name: "backend_bluez", description: "Force the BlueZ backend.", enabledTraits: []),
    .trait(
      name: "backend_windows", description: "Force the Windows Bluetooth backend.",
      enabledTraits: []),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    .package(url: "https://github.com/wendylabsinc/dbus.git", from: "0.3.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.70.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
  ],
  targets: [
    // Targets are the basic building blocks of a package, defining a module or a test suite.
    // Targets can depend on other targets in this package and products from dependencies.
    .target(
      name: "Bluetooth",
      dependencies: [
        .product(name: "DBUS", package: "dbus", condition: .when(platforms: [.linux])),
        .product(name: "NIOCore", package: "swift-nio", condition: .when(platforms: [.linux])),
        .product(name: "NIOPosix", package: "swift-nio", condition: .when(platforms: [.linux])),
        .product(
          name: "NIOFoundationCompat", package: "swift-nio", condition: .when(platforms: [.linux])),
        .product(name: "Logging", package: "swift-log"),
      ],
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
    .executableTarget(
      name: "BluetoothL2CAPExample",
      dependencies: [
        "Bluetooth",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      path: "Examples/L2CAP",
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
    .executableTarget(
      name: "BluetoothL2CAPClientExample",
      dependencies: [
        "Bluetooth",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      path: "Examples/L2CAPClient",
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
    .executableTarget(
      name: "BluetoothDiscoveryExample",
      dependencies: [
        "Bluetooth",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      path: "Examples/Discovery",
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
    .executableTarget(
      name: "BluetoothCentralPairingExample",
      dependencies: [
        "Bluetooth",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      path: "Examples/CentralPairing",
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
  ]
)
