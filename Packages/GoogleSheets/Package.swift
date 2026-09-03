// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "GoogleSheets",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "GoogleSheets", targets: ["GoogleSheets"]),
    ],
    targets: [
        // No dependencies on purpose. §4.1 signs the JWT on device with
        // Security.framework rather than pulling in the Google SDK, and §8 limits
        // network access to googleapis.com — both easier to hold to with nothing
        // else in the module.
        .target(name: "GoogleSheets"),
        .testTarget(name: "GoogleSheetsTests", dependencies: ["GoogleSheets"]),
    ]
)
