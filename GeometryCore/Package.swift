// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "GeometryCore",
    products: [.library(name: "GeometryCore", targets: ["GeometryCore"])],
    targets: [
        .systemLibrary(name: "CZlib", pkgConfig: "zlib", providers: [.apt(["zlib1g-dev"]), .brew(["zlib"])]),
        .target(name: "GeometryCore", dependencies: ["CZlib"]),
        .testTarget(name: "GeometryCoreTests", dependencies: ["GeometryCore"], resources: [.process("Fixtures")])
    ]
)
