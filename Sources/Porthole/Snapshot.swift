import AppKit
import AppTestKit
import SwiftUI

/// Screenshot mode for agents.
///   APP_STORE=/tmp/test.store APP_SNAPSHOT=/tmp/shots ~/Applications/Porthole.app/Contents/MacOS/Porthole
/// writes <page>-light.png and <page>-dark.png for every sidebar page, and
/// settings-<tab>-light.png and settings-<tab>-dark.png for every Settings tab, then quits.
/// Each PNG gets a <page>-<mode>-layout.json with the grid probes (tools/check-layout.swift).
/// The pages are sample containers (DemoDocker). APP_SNAPSHOT_PAGES=seerr,tautulli limits them. Add "settings" to include Settings.
/// Add APP_ACCENT=<id> to see the pages in another accent.
/// AppTestKit refuses without APP_STORE in /tmp, keeps the display awake, and takes the captures.
enum Snapshot {
    /// Sample containers that show each state: warnings, an unhealthy one, a crashed one.
    static let pages = ["overview", "uptime-kuma", "seerr", "tautulli", "mangosd", "stack-media"]

    static func runIfRequested(model: AppModel, openSettings: OpenSettingsAction) {
        // Snapshots never run against the real server.
        guard let run = SnapshotRun.requested(layout: { GridProbes.shared.write(to: $0.path, window: $1) }) else { return }
        Task {
            await run.start()
            run.settle = .seconds(1.2)
            await run.shootPages(pages) { page in
                if page == "overview" { model.page = .overview }
                else if page.hasPrefix("stack-") { model.page = .stack(String(page.dropFirst(6))) }
                else { model.selection = page }
            }
            run.settle = .seconds(0.8)
            await run.shootSettings(tabs: SettingsTab.allCases.map(\.rawValue), open: { openSettings() },
                                    select: { model.settingsTab = SettingsTab(rawValue: $0) ?? .server })
            if run.wants("menubar") {
                // The menu bar panel, in a plain window of its own.
                let panel = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 340, height: 400),
                                     styleMask: [.titled], backing: .buffered, defer: false)
                panel.title = "Menu Bar"
                // Closing a window AppKit releases on close crashed the run here, before Help.
                panel.isReleasedWhenClosed = false
                panel.contentView = NSHostingView(rootView: MenuBarPanel().environment(model).themed())
                panel.setContentSize(panel.contentView?.fittingSize ?? .zero)
                await run.forEachAppearance { look in
                    await run.pause()
                    await run.capture("menubar", look, window: panel)
                }
                panel.close()
            }
            if run.wants("help") {
                // Help, on its first page and on the shortcuts.
                for topic in [HelpTopic.overview, .shortcuts] {
                    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 840, height: 600),
                                          styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = NSHostingView(rootView: HelpView(topic: topic).themed())
                    await run.forEachAppearance { look in
                        await run.pause()
                        await run.capture("help-\(topic.rawValue)", look, window: window)
                    }
                    window.close()
                }
            }
            run.finish()
        }
    }
}
