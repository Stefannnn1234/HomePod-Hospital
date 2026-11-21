// swift-tools-version:5.9
//
// HomePod Hospital — a friendly Mac app for restoring, diagnosing and reviving
// 1st-gen HomePods. (Formerly "HomePod Restore": the package, targets and
// modules deliberately keep their HomePodRestore names.)
//
// Build the app bundle with:   ./scripts/build-app.sh
// Run the core unit tests with: swift test
//
import PackageDescription

var targets: [Target] = [
    // Foundation-only logic (log parsing, firmware catalog, downloads, zip
    // handling, process orchestration). Builds and tests on Linux too.
    .target(
        name: "HomePodRestoreCore",
        path: "Sources/HomePodRestoreCore"
    ),
    .testTarget(
        name: "HomePodRestoreCoreTests",
        dependencies: ["HomePodRestoreCore"],
        path: "Tests/HomePodRestoreCoreTests",
        resources: [.copy("Fixtures")]
    ),
]

var products: [Product] = [
    .library(name: "HomePodRestoreCore", targets: ["HomePodRestoreCore"]),
]

#if os(macOS)
targets.append(
    .executableTarget(
        name: "HomePodRestore",
        dependencies: ["HomePodRestoreCore"],
        path: "Sources/HomePodRestore",
        linkerSettings: [
            .linkedFramework("IOKit"),
            .linkedFramework("AppKit"),
        ]
    )
)
products.append(.executable(name: "HomePodRestore", targets: ["HomePodRestore"]))
#endif

let package = Package(
    name: "HomePodRestore",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
