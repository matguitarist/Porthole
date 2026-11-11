import AppKit
import PortholeKit
import SwiftUI
import UserNotifications

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
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                    .disabled(!Updater.shared.isAvailable)
            }
            CommandGroup(before: .sidebar) {
                Button("Overview", systemImage: "gauge.with.dots.needle.33percent") { model.page = .overview }
                    .keyboardShortcut("0")
                Divider()
            }
            CommandMenu("Server") {
                Button("Scan Logs for Problems", systemImage: "exclamationmark.magnifyingglass") {
                    Task { await model.scanProblems() }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model.scanningProblems || model.connection != .connected)
                Button("Clear All Logs on Server…", systemImage: "trash") { model.requestClearLogs() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .disabled(model.clearing || model.containers.isEmpty)
                Divider()
                Button("Open Server's Web Page", systemImage: "safari") {
                    if let url = URL(string: "http://\(ServerSettings.host)") { NSWorkspace.shared.open(url) }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Reconnect", systemImage: "arrow.triangle.2.circlepath") { model.reconnect() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
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
                Button("Show Warnings and Errors of the Last Day", systemImage: "exclamationmark.triangle") {
                    if let name = model.selection { model.open(name, problemsOnly: true) }
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(model.selection == nil)
                Button("Show Whole Log", systemImage: "text.alignleft") {
                    if let name = model.selection { model.open(name) }
                }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(model.selection == nil)
                Button("Clear Log on Server…", systemImage: "trash") {
                    if let page = model.page, let log = model.log(for: page) { model.requestClearLogs(log.names) }
                }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .disabled(model.page == nil || model.page == .overview || model.clearing)
                Divider()
                Button("Open Web Page", systemImage: "safari") {
                    if let url = model.webUI() { NSWorkspace.shared.open(url) }
                }
                .keyboardShortcut("o")
                .disabled(model.webUI() == nil)
            }
            CommandGroup(replacing: .help) {
                Button("Porthole on GitHub") { NSWorkspace.shared.open(Links.repository) }
                Button("What’s New in Porthole") { NSWorkspace.shared.open(Links.releaseNotes) }
                Divider()
                Button("Report a Problem…") { NSWorkspace.shared.open(Links.newIssue) }
            }
        }

        StatusScene(model: model)

        Settings {
            SettingsView()
                .environment(model)
                .themed()
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started from a terminal, the process is not a foreground app yet.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if !Store.isOverridden { UNUserNotificationCenter.current().delegate = self }
        _ = Updater.shared
    }

    /// With the menu bar icon, Porthole keeps watching after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        Store.isOverridden || !MenuBarStatus.isShown
    }

    /// The Dock icon reopens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { true }

    /// Alerts show even while Porthole is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }

    /// A click on an alert opens that container's warnings and errors.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let name = response.notification.request.content.userInfo["container"] as? String
        await MainActor.run {
            guard let model = AppModel.current, let name else { return }
            model.open(name, problemsOnly: true)
            NSApp.activate()
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
        }
    }

    /// The self-test's result becomes the exit code, after a normal quit.
    func applicationWillTerminate(_ notification: Notification) {
        // Log, event and stats streams run through the shared SSH connection: closing it ends them.
        (AppModel.current?.client as? SSHDocker)?.disconnectNow()
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

/// The menu bar icon, in its own scene so the app's menus updating don't rebuild it.
struct StatusScene: Scene {
    @Bindable var model: AppModel

    var body: some Scene {
        // Bound to the model: an @AppStorage binding here makes SwiftUI update forever.
        MenuBarExtra(isInserted: $model.showInMenuBar) {
            MenuBarPanel()
                .environment(model)
                .themed()
        } label: {
            Image(systemName: MenuBarStatus.symbol(model))
        }
        .menuBarExtraStyle(.window)
    }
}
