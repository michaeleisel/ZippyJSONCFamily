// swift-tools-version:5.0

import PackageDescription

let package = Package(
    name: "ZippyJSONCFamily",
    products: [
        .library(
            name: "ZippyJSONCFamily",
            targets: ["ZippyJSONCFamily"]),
    ],
    targets: [
        .target(
            name: "ZippyJSONCFamily",
            dependencies: []),
        .testTarget(
            name: "ZippyJSONCFamilyTests",
            dependencies: ["ZippyJSONCFamily"]),
    ],
    cxxLanguageStandard: .cxx1z
)
