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
            dependencies: ["CWavPack", "CMonkeysAudio"],
            path: "src"
        ),
        // Vendored decoders (vendor/README.md): upstream files, never edited, copied by vendor/update.sh.
        .target(
            name: "CWavPack",
            path: "vendor/wavpack",
            exclude: ["COPYING"],
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                // DSD files decode to PCM; the legacy (< 4.0) decoder is in. No threads, no assembly.
                .define("ENABLE_DSD"),
                .define("ENABLE_LEGACY"),
                .define("HAVE___BUILTIN_CLZ"),
            ]
        ),
        .target(
            name: "CMonkeysAudio",
            path: "vendor/monkeys-audio",
            exclude: ["License.txt"],
            sources: ["Source", "shim/ichm_ape.cpp"],
            publicHeadersPath: "shim/include",
            cxxSettings: [
                .define("PLATFORM_APPLE"),
                .headerSearchPath("Source/Shared"),
                .headerSearchPath("Source/MACLib"),
                .headerSearchPath("Source/MACLib/Old"),
                // The SDK's own file class (StdLibFileIO.h, unused: the shim reads through our code, but MACLib.cpp
                // refers to it) lacks `override`. Upstream files are not edited, so this one warning is off here.
                .unsafeFlags(["-Wno-inconsistent-missing-override"]),
            ]
        ),
        .testTarget(
            name: "iCanHazMusicTests",
            dependencies: [
                .target(name: "iCanHazMusic"),
                "CWavPack",
                "CMonkeysAudio",
            ],
            path: "tests",
            exclude: ["fixtures", "prepare-fixtures.sh"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
