// swift-tools-version:6.0
import PackageDescription

// FreeRDP 3 from Homebrew (brew install freerdp)
let brewPrefix = "/opt/homebrew"

let package = Package(
    name: "Pstsc",
    platforms: [.macOS(.v14)],
    targets: [
        // Thin C layer over libfreerdp3: connection thread, RemoteApp (RAIL) window orders, GDI frames, input.
        .target(
            name: "PstscRDP",
            cSettings: [
                .unsafeFlags([
                    "-I\(brewPrefix)/include/freerdp3",
                    "-I\(brewPrefix)/include/winpr3",
                    "-Wno-deprecated-declarations",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(brewPrefix)/lib"]),
                .linkedLibrary("freerdp3"),
                .linkedLibrary("freerdp-client3"),
                .linkedLibrary("winpr3"),
            ]
        ),
        // The agent: one RDP connection, each remote window shown as its own NSWindow.
        .executableTarget(
            name: "PstscAgent",
            dependencies: ["PstscRDP", "PstscDockProxy"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Copied into one generated .app per remote program to give it its own Dock icon.
        .executableTarget(
            name: "PstscDockProxy",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
