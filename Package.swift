// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeTokenMeter",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ClaudeTokenMeterLogic", targets: ["ClaudeTokenMeterLogic"]),
    ],
    targets: [
        .target(
            name: "ClaudeTokenMeterLogic",
            path: ".",
            exclude: [
                "Tests",
                "dist",
                ".build",
                "ClaudeTokenMeter.xcodeproj",
                "assets",
                "build",
                ".github",
                "AppDelegate.swift",
                "ClaudeProvider.swift",
                "ClaudeTokenMeter.swift",
                "CodexAuthAccess.swift",
                "CodexOAuth.swift",
                "CodexRPC.swift",
                "CombinedStatusController.swift",
                "MeterUI.swift",
                "ProviderClients.swift",
                "ProviderStatusController.swift",
                "README.md",
                "LICENSE",
                "Info.plist",
                "entitlements.plist",
                "release.sh",
                "build.sh",
                "app-icon.png",
                "permissions.png",
                "screenshot-1.png",
                "screenshot-2.png",
                "screenshot-3.png",
                "screenshot-4.png",
                "Assets.xcassets",
            ],
            sources: [
                "CoreTypes.swift",
                "SupportUtilities.swift",
                "CodexStatus.swift",
            ]
        ),
        .testTarget(
            name: "ClaudeTokenMeterLogicTests",
            dependencies: ["ClaudeTokenMeterLogic"],
            path: "Tests/ClaudeTokenMeterLogicTests"
        ),
    ]
)
