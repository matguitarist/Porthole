import AppKit
import PortholeKit
import SwiftUI

// Porthole
//   Porthole                      the app, connected to the server in Settings
//   APP_STORE=<file> Porthole     test mode: sample containers, nothing saved (tests, snapshots)
//   APP_SNAPSHOT=<dir> Porthole   save a PNG of sample containers and every Settings tab in light and dark mode, then quit
//   APP_SEED=1 Porthole           sample data (always on in test mode)
//   Porthole --selftest           run the self-test on sample data and quit with 0 or 1 (tools/selftest.sh)
//   APP_ACCENT=<id> Porthole      run with another accent from Theme.all (UI/Theme.swift)
//   APP_GRID=1 Porthole           draw the 8 pt grid and the layout probes over the window

@main
struct PortholeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Porthole", id: "main") {
            ContentView()
                .environment(model)
                .themed()
                .overlay { if GridOverlay.enabled { GridOverlay() } }
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            ToolbarCommands()
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Container") {
                Button("Start", systemImage: "play") { model.request(.start) }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(!model.canPerform(.start))
                Button("Stop…", systemImage: "stop") { model.request(.stop) }
                    .keyboardShortcut(".", modifiers: [.command, .option])
                    .disabled(!model.canPerform(.stop))
                Button("Restart", systemImage: "arrow.clockwise") { model.request(.restart) }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(!model.canPerform(.restart))
                Divider()
                Button("Open Web Page", systemImage: "safari") {
                    if let url = model.webUI() { NSWorkspace.shared.open(url) }
                }
                .keyboardShortcut("o")
                .disabled(model.webUI() == nil)
                Divider()
                Button("Reconnect", systemImage: "arrow.triangle.2.circlepath") { model.reconnect() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .themed()
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started from a terminal, the process is not a foreground app yet.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The self-test's result becomes the exit code, after a normal quit.
    func applicationWillTerminate(_ notification: Notification) {
        if SelfTest.requested { exit(SelfTest.exitCode) }
    }
}

/// Test mode: APP_STORE set (to a file in /tmp) means sample data and no
/// saved settings. Porthole keeps no database of its own.
enum Store {
    static var isOverridden: Bool {
        !(ProcessInfo.processInfo.environment["APP_STORE"] ?? "").isEmpty
    }
}
