// swift-tools-version: 6.1
import PackageDescription

// This package deliberately compiles only the pure presentation model and
// geometry. It never builds or launches the AppKit/SwiftUI application host.
let package = Package(
    name: "PersonalIslandPresentation",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PersonalIslandPresentation", targets: ["PersonalIslandPresentation"])
    ],
    targets: [
        .target(
            name: "PersonalIslandPresentation",
            path: "PersonalIslandApp/Sources",
            exclude: [
                "PersonalIslandApp.swift", "IslandCoordinator.swift", "IslandPanelController.swift",
                "IslandView.swift", "SettingsView.swift", "NotchShape.swift",
                "GlobalHotKey.swift", "RegionSelector.swift", "ScreenRegionCapture.swift",
                "ShelfDragSource.swift", "SpotifyAdapter.swift", "CalendarAdapter.swift", "BatteryAdapter.swift", "SystemStatsAdapter.swift", "ClipboardAdapter.swift", "TransfersAdapter.swift"
            ],
            sources: ["IslandGeometry.swift", "IslandPresentation.swift", "CaptureGeometry.swift", "CaptureFlow.swift", "ShelfDragFlow.swift", "WindowPicker.swift", "IslandSettings.swift", "SpotifyPlayback.swift", "SpotifyArtwork.swift", "CalendarAgenda.swift", "BatteryStatus.swift", "IslandTimers.swift", "SystemStats.swift", "ClipboardHistory.swift", "Transfers.swift"]
        ),
        .testTarget(
            name: "PersonalIslandPresentationTests",
            dependencies: ["PersonalIslandPresentation"],
            path: "Tests/PersonalIslandPresentationTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
