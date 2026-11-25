import AppKit
import SwiftUI

// The menus every app of mine shares, so they read and work the same everywhere:
//   StandardCommands  About (optional) and Check for Updates… in the app menu, and the Help menu:
//                     <App> Help (⌘?), the app's own help items, What’s New in <App>, <App> on GitHub,
//                     Report a Problem…, Show Log
//   PageCommands      ⌘1, ⌘2… at the top of View, one per sidebar page, reopening the main window
//   AboutPanel        the standard About panel with a few lines of credits and links
// Each app gives its name, its GitHub repository and the hooks it has; what it doesn't give
// doesn't appear. Menus of its own (Game, Mods, Server, File items) stay in the app.
// The strings are in each app's Localizable.xcstrings, in English and French.
// Shared by my Mac apps (sync-mac-tools): change it everywhere or nowhere.

/// Where a menu item takes the person.
enum MenuDestination {
    /// A window scene, by its id. `prepare` runs first, to pick a Help topic for instance.
    case window(String, prepare: (@MainActor () -> Void)? = nil)
    /// A page of the main window: `select` picks it, then the main window comes forward,
    /// reopened if it was closed.
    case page(@MainActor () -> Void)
}

/// What Check for Updates… does: the shared `Updater` (Sparkle) in most apps.
struct AppUpdates {
    /// False in test runs and builds without an update key: the item stays, disabled.
    /// Read by the menu item's view, so a value that changes (Sparkle busy) is followed.
    let isAvailable: @MainActor () -> Bool
    let check: @MainActor () -> Void

    init(isAvailable: @autoclosure @escaping @MainActor () -> Bool, check: @escaping @MainActor () -> Void) {
        self.isAvailable = isAvailable
        self.check = check
    }
}

/// The app's GitHub links: the repository, its latest release notes, and a new issue
/// with the version, build and macOS filled in (no personal data).
struct RepositoryLinks {
    /// "owner/name", as in https://github.com/owner/name.
    let repository: String

    var home: URL { URL(string: "https://github.com/\(repository)")! }
    var latestRelease: URL { home.appending(path: "releases/latest") }

    func newIssue(app: String) -> URL {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        var components = URLComponents(url: home.appending(path: "issues/new"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "body", value: "\n\n---\n\(app) \(version) (\(build)), macOS \(system)")]
        return components.url ?? home
    }
}

/// The app menu's About and Check for Updates…, and the whole Help menu.
struct StandardCommands<HelpItems: View>: Commands {
    /// The app's name as menus show it: "RenChan", "SM Launcher Plus".
    let app: String
    let links: RepositoryLinks
    let updates: AppUpdates?
    let about: (@MainActor () -> Void)?
    let help: MenuDestination?
    let log: MenuDestination?
    let logShortcut: KeyboardShortcut?
    let mainWindow: String?
    let helpItems: HelpItems

    /// - Parameters:
    ///   - repository: "owner/name" on GitHub.
    ///   - updates: Check for Updates…, after About.
    ///   - about: replaces About <App> (an `AboutPanel` with credits, say).
    ///   - help: <App> Help (⌘?): the app's Help window.
    ///   - log: Show Log: the app's log page or window (LogKit), with `logShortcut` if it had one.
    ///   - mainWindow: the main `Window` scene's id, brought forward for a `.page` destination;
    ///     nil when the main scene is a `WindowGroup` (another window would open).
    ///   - helpItems: the app's own Help items, under <App> Help.
    init(app: String, repository: String, updates: AppUpdates? = nil, about: (@MainActor () -> Void)? = nil,
         help: MenuDestination? = nil, log: MenuDestination? = nil, logShortcut: KeyboardShortcut? = nil,
         mainWindow: String? = "main", @ViewBuilder helpItems: () -> HelpItems) {
        self.app = app
        self.links = RepositoryLinks(repository: repository)
        self.updates = updates
        self.about = about
        self.help = help
        self.log = log
        self.logShortcut = logShortcut
        self.mainWindow = mainWindow
        self.helpItems = helpItems()
    }

    var body: some Commands {
        if let about {
            CommandGroup(replacing: .appInfo) {
                Button("About \(app)") { about() }
            }
        }
        if let updates {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesItem(updates: updates)
            }
        }
        CommandGroup(replacing: .help) {
            StandardHelpItems(app: app, links: links, help: help, log: log, logShortcut: logShortcut,
                              mainWindow: mainWindow, helpItems: helpItems)
        }
    }
}

extension StandardCommands where HelpItems == EmptyView {
    init(app: String, repository: String, updates: AppUpdates? = nil, about: (@MainActor () -> Void)? = nil,
         help: MenuDestination? = nil, log: MenuDestination? = nil, logShortcut: KeyboardShortcut? = nil,
         mainWindow: String? = "main") {
        self.init(app: app, repository: repository, updates: updates, about: about, help: help, log: log,
                  logShortcut: logShortcut, mainWindow: mainWindow) { EmptyView() }
    }
}

/// A view, so its enabled state follows the updater.
private struct CheckForUpdatesItem: View {
    let updates: AppUpdates

    var body: some View {
        Button("Check for Updates…") { updates.check() }
            .disabled(!updates.isAvailable())
    }
}

/// A view, so the items can open windows.
private struct StandardHelpItems<HelpItems: View>: View {
    let app: String
    let links: RepositoryLinks
    let help: MenuDestination?
    let log: MenuDestination?
    let logShortcut: KeyboardShortcut?
    let mainWindow: String?
    let helpItems: HelpItems
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let help {
            Button("\(app) Help") { go(help) }
                .keyboardShortcut("?", modifiers: .command)
        }
        helpItems
        if help != nil || HelpItems.self != EmptyView.self {
            Divider()
        }
        Button("What’s New in \(app)") { NSWorkspace.shared.open(links.latestRelease) }
        Button("\(app) on GitHub") { NSWorkspace.shared.open(links.home) }
        Button("Report a Problem…") { NSWorkspace.shared.open(links.newIssue(app: app)) }
        if let log {
            Divider()
            Button("Show Log") { go(log) }
                .keyboardShortcut(logShortcut)
        }
    }

    private func go(_ destination: MenuDestination) {
        switch destination {
        case .window(let id, let prepare):
            prepare?()
            openWindow(id: id)
        case .page(let select):
            select()
            if let mainWindow { openWindow(id: mainWindow) }
        }
    }
}

/// ⌘1, ⌘2… (⌘0 for the tenth) at the top of the View menu, one per sidebar page.
/// Picking one selects the page and brings the main window forward, reopened if it was closed.
struct PageCommands<Page: Hashable>: Commands {
    let pages: [Page]
    let title: (Page) -> String
    let modifiers: EventModifiers
    let isEnabled: @MainActor () -> Bool
    let mainWindow: String?
    let select: @MainActor (Page) -> Void

    /// - Parameters:
    ///   - title: the page's name, already localized (the sidebar's).
    ///   - modifiers: `.command` by default; an app whose ⌘1… mean something else gives its own.
    ///   - isEnabled: false while the pages can't show anything yet (no game folder, say).
    init(pages: [Page], title: @escaping (Page) -> String, modifiers: EventModifiers = .command,
         isEnabled: @autoclosure @escaping @MainActor () -> Bool = true, mainWindow: String? = "main", select: @escaping @MainActor (Page) -> Void) {
        self.pages = pages
        self.title = title
        self.modifiers = modifiers
        self.isEnabled = isEnabled
        self.mainWindow = mainWindow
        self.select = select
    }

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            PageItems(pages: pages, title: title, modifiers: modifiers, isEnabled: isEnabled,
                      mainWindow: mainWindow, select: select)
            Divider()
        }
    }
}

private struct PageItems<Page: Hashable>: View {
    let pages: [Page]
    let title: (Page) -> String
    let modifiers: EventModifiers
    let isEnabled: @MainActor () -> Bool
    let mainWindow: String?
    let select: @MainActor (Page) -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
            Button(title(page)) {
                select(page)
                if let mainWindow { openWindow(id: mainWindow) }
            }
            .keyboardShortcut(index < 10 ? KeyboardShortcut(KeyEquivalent(Character(String((index + 1) % 10))), modifiers: modifiers) : nil)
            .disabled(!isEnabled())
        }
    }
}

/// The standard About panel (icon, name, version) with credits under it: short paragraphs,
/// then rows of links, small and centered. For apps that credit a game, a framework or a source.
@MainActor
enum AboutPanel {
    enum Credit {
        /// A paragraph, already localized.
        case text(String)
        /// Links on one line, separated by " · ".
        case links([(title: String, url: URL)])
    }

    static func show(_ credits: [Credit]) {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [.credits: text(credits)]
        // Passed in: macOS can show a stale generic icon for a rebuilt app.
        if let icon = NSImage(named: "AppIcon") { options[.applicationIcon] = icon }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate()
    }

    /// The credits as the panel shows them (a self-test can read their text and links).
    static func text(_ credits: [Credit]) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let text = NSMutableAttributedString()
        for (index, credit) in credits.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n\n", attributes: [.font: font])) }
            switch credit {
            case .text(let string):
                text.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            case .links(let links):
                for (position, link) in links.enumerated() {
                    if position > 0 {
                        text.append(NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
                    }
                    text.append(NSAttributedString(string: link.title, attributes: [.font: font, .link: link.url]))
                }
            }
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        return text
    }
}
