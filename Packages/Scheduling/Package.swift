// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Scheduling",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "Scheduling", targets: ["Scheduling"]),
    ],
    dependencies: [
        // Pinned to a revision, not a tag: FSRS-6 is merged on main but in no
        // release — the newest tag, v5.0.0, is FSRS-5 only. See the repo README.
        .package(
            url: "https://github.com/open-spaced-repetition/swift-fsrs",
            revision: "4fbaf20184d62f82a9f44f343337c61a2c5483e9"
        ),
    ],
    targets: [
        .target(name: "Scheduling", dependencies: [.product(name: "FSRS", package: "swift-fsrs")]),
        .testTarget(name: "SchedulingTests", dependencies: ["Scheduling"]),
    ]
)
