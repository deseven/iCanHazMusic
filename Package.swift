// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "iCanHazMusic",
    platforms: [
        .macOS("15.4")
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "iCanHazMusic",
            dependencies: [],
            path: "src"
        ),
        .testTarget(
            name: "iCanHazMusicTests",
            dependencies: [
                .target(name: "iCanHazMusic"),
            ],
            path: "tests",
            exclude: ["fixtures", "prepare-fixtures.sh"]
        ),
    ]
)
