// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "GeometryCore",
    products: [.library(name: "GeometryCore", targets: ["GeometryCore"])],
    targets: [
        .target(name: "GeometryCore"),
        .testTarget(name: "GeometryCoreTests", dependencies: ["GeometryCore"])
    ]
)
