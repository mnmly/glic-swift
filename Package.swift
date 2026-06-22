// swift-tools-version:5.9
import PackageDescription

// Prototype package: C++ GLIC codec consumed from Swift via C++ interop.
// Targets: CGlic (C++ codec module), GlicBench (interop benchmark CLI),
// GlicStudio (SwiftUI interactive app). Coexists with CMakeLists.txt.
let package = Package(
    name: "GlicInterop",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CGlic",
            path: "src",
            exclude: ["main.cpp"],
            sources: [
                "glic.cpp", "planes.cpp", "colorspaces.cpp", "segment.cpp",
                "prediction.cpp", "quantization.cpp", "wavelet.cpp",
                "encoding.cpp", "bitio.cpp", "effects.cpp", "studio_api.cpp",
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../external/stb"),  // stb submodule (master)
                .unsafeFlags(["-O2", "-DNDEBUG"]),
            ]
        ),
        .executableTarget(
            name: "GlicBench",
            dependencies: ["CGlic"],
            path: "Sources/GlicBench",
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        .executableTarget(
            name: "GlicStudio",
            dependencies: ["CGlic"],
            path: "Sources/GlicStudio",
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
