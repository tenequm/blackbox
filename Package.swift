// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Blackbox",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Blackbox",
            path: "Sources",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
                .treatAllWarnings(as: .error),
            ],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
    ]
)
