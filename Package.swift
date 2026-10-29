// swift-tools-version:6.0
import PackageDescription

// FreeRDP 3 + OpenSSL built by scripts/build-freerdp.sh (no GPL codecs, macOS 14+); bundled into
// Pstsc.app/Contents/Frameworks by scripts/build-app.sh.
let freerdpPrefix = Context.packageDirectory + "/build/deps/freerdp"

let package = Package(
    name: "Pstsc",
    platforms: [.macOS(.v14)],
    targets: [
        // Thin C layer over libfreerdp3: connection thread, RemoteApp (RAIL) window orders, GDI frames, input.
        .target(
            name: "PstscRDP",
            cSettings: [
                .unsafeFlags([
                    "-I\(freerdpPrefix)/include/freerdp3",
                    "-I\(freerdpPrefix)/include/winpr3",
                    "-Wno-deprecated-declarations",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(freerdpPrefix)/lib"]),
                .linkedLibrary("freerdp3"),
                .linkedLibrary("freerdp-client3"),
                .linkedLibrary("winpr3"),
            ]
        ),
        // The agent: one RDP connection, each remote window shown as its own NSWindow.
        .executableTarget(
            name: "PstscAgent",
            dependencies: ["PstscRDP", "PstscDockProxy"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Inside the app: Contents/Frameworks. From `swift run`: the build directory.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                              "-Xlinker", "-rpath", "-Xlinker", "\(freerdpPrefix)/lib"]),
            ]
        ),
        // Copied into one generated .app per remote program to give it its own Dock icon.
        .executableTarget(
            name: "PstscDockProxy",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
