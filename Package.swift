// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WaveformViewer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "WaveformViewer", targets: ["WaveformViewer"])
    ],
    targets: [
        .executableTarget(
            name: "WaveformViewer",
            path: "Sources/WaveformViewer",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "WaveformViewerTests",
            dependencies: ["WaveformViewer"],
            path: "Tests/WaveformViewerTests",
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
