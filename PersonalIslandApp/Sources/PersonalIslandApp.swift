import AppKit
import SwiftUI

@main
struct PersonalIslandApp: App {
    @NSApplicationDelegateAdaptor(PersonalIslandApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var coordinator = IslandCoordinator.shared

    var body: some Scene {
        MenuBarExtra("Personal Island", systemImage: "capsule") {
            Text("Personal Island · Preview")
            Divider()
            Button("Capture Region") {
                coordinator.captureRegion()
            }
            .keyboardShortcut("4", modifiers: [.control, .shift])
            .disabled(coordinator.isCapturing)
            Button(coordinator.islandsVisible ? "Hide Islands" : "Show Islands") {
                coordinator.setIslandsVisible(!coordinator.islandsVisible)
            }
            Button("Settings…") {
                coordinator.showSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button("Quit Personal Island") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}

@MainActor
final class PersonalIslandApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        IslandCoordinator.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        IslandCoordinator.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
