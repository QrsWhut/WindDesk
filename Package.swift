// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindDesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WindDesk", targets: ["WindDeskApp"]),
        .executable(name: "WindDeskWidget", targets: ["WindDeskWidget"])
    ],
    targets: [
        .target(name: "WindDeskCore"),
        .executableTarget(name: "WindDeskApp", dependencies: ["WindDeskCore"]),
        .executableTarget(
            name: "WindDeskWidget",
            dependencies: ["WindDeskCore"],
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [
                .linkedFramework("Foundation"),
                // Launch the bundle as an app extension when built outside Xcode.
                .unsafeFlags([
                    "-Xlinker", "-application_extension",
                    "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                    "-Xlinker", "-u", "-Xlinker", "_main"
                ])
            ]
        ),
        .executableTarget(name: "WindDeskChecks", dependencies: ["WindDeskCore"], path: "Checks")
    ]
)
