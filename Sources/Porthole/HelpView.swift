import SwiftUI

/// Help › Porthole Help (⌘?): how each part of Porthole works, one topic at a time.
struct HelpView: View {
    @State private var topic: HelpTopic? = .start

    init(topic: HelpTopic = .start) {
        _topic = State(initialValue: topic)
    }

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.allCases, selection: $topic) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            ScrollView {
                if let topic {
                    HelpPage(topic: topic)
                        .padding(Space.margin)
                        .frame(maxWidth: 600, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .gridArea("help")
                }
            }
        }
        .navigationTitle("Porthole Help")
        .noInitialFocus()
    }
}

private struct HelpPage: View {
    let topic: HelpTopic

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Label(topic.title, systemImage: topic.symbol)
                .font(.title2.weight(.semibold))
                .padding(.bottom, Space.xs)
            ForEach(Array(topic.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(AttributedString(localized: paragraph))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if topic == .shortcuts {
                ShortcutTable()
            }
        }
    }
}

private struct ShortcutTable: View {
    var body: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: Space.lg, verticalSpacing: Space.sm) {
                ForEach(Array(HelpTopic.keys.enumerated()), id: \.offset) { index, shortcut in
                    if index > 0 { Divider() }
                    GridRow {
                        Text(verbatim: shortcut.keys)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                        Text(shortcut.action)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.vertical, Space.xs)
        }
    }
}

enum HelpTopic: String, CaseIterable, Identifiable {
    case start, overview, logs, containers, stacks, alerts, ignoring, menuBar, away, shortcuts

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .start: "Getting Started"
        case .overview: "The Overview"
        case .logs: "Reading Logs"
        case .containers: "Containers"
        case .stacks: "Compose Stacks"
        case .alerts: "Alerts"
        case .ignoring: "Ignoring Known Noise"
        case .menuBar: "The Menu Bar Icon"
        case .away: "Away from the Mac"
        case .shortcuts: "Keyboard Shortcuts"
        }
    }

    var symbol: String {
        switch self {
        case .start: "power"
        case .overview: "gauge.with.dots.needle.33percent"
        case .logs: "text.alignleft"
        case .containers: "shippingbox"
        case .stacks: "square.stack.3d.up"
        case .alerts: "bell"
        case .ignoring: "eye.slash"
        case .menuBar: "menubar.rectangle"
        case .away: "globe"
        case .shortcuts: "keyboard"
        }
    }

    /// Markdown: **bold** for the names of things on screen.
    var paragraphs: [LocalizedStringResource] {
        switch self {
        case .start: [
            "Porthole shows your Docker server's containers and their logs. It connects with SSH and runs the `docker` command, so nothing is installed on the server.",
            "In **Settings › Server**, enter the server's SSH address (like `root@192.168.1.10`, or a Host from `~/.ssh/config`) and your key file, then click **Test Connection**. The key must log in without asking for a password.",
            "Porthole keeps one SSH connection open for everything it reads, so it stays light on the server.",
        ]
        case .overview: [
            "The **Overview** (⌘0) is the server at a glance: CPU, memory, network, disk activity, containers, and how long it has been up. When the CPU waits on the disks a lot, **Disk Activity** says so: a parity check or the mover is slowing things down.",
            "**Updates** lists the containers whose image has a newer version, from Unraid's own update check. Click one to update it on Unraid's Docker page.",
            "**Needs a Look** lists what to deal with first: a crashed or unhealthy container, a stopped array, a failing or hot disk, or parity errors.",
            "**Warnings and Errors** reads the last 24 hours of every container's log. The chart shows them per hour; hold the pointer over an hour for its counts. Click a row to see that container's warnings and errors.",
            "**Storage**, **Array**, and **Docker's Space** show how full the disks are, the last parity check, each disk's temperature, and what fills Docker's space. **Biggest Logs** lists the largest log files; Control-click one to clear it.",
            "Lines logged while Docker restarts don't count: every container logs its shutdown and startup then.",
        ]
        case .logs: [
            "Choose a container in the sidebar to follow its log as it's written. Porthole finds the level of each line in most formats: level words, JSON, logfmt, web access logs, and tracebacks.",
            "Filter by level, search, and fold repeated lines from the log's toolbar. **Container › Show Warnings and Errors of the Last Day** loads the whole day.",
            "When a container is in trouble, a note at the top says why: a crash with its exit code, a failing health check, or a restart loop.",
        ]
        case .containers: [
            "Start, stop, or restart the selected container from the toolbar or the **Container** menu. Stop asks first.",
            "**Open Web Page** (⌘O) opens the container's page, from its Unraid template.",
            "**Clear Log on Server** empties a container's log file to start fresh. A running container stops for a moment while its log is cleared: Docker 29 can't read a log emptied under a running container.",
        ]
        case .stacks: [
            "Compose projects with more than one container appear under **Stacks** in the sidebar.",
            "A stack's log merges its containers' logs in time order, and each line says which container wrote it.",
        ]
        case .alerts: [
            "Porthole sends a notification when a container crashes, runs out of memory, turns unhealthy, keeps restarting, or logs new errors, and when Docker itself stays busy. Click one to see that container's problems.",
            "In **Settings › Alerts**, choose the alerts you want and add Gotify to get them on your phone too. Each alert waits 15 minutes before it repeats.",
        ]
        case .ignoring: [
            "Some messages are expected. Select a log line and choose **Ignore Messages Like This…**: those lines stay in the log, dimmed, but no longer count as problems or send alerts.",
            "**Settings › Ignored** lists your rules; remove one to count its messages again.",
        ]
        case .menuBar: [
            "The menu bar icon shows how the server is: a triangle when something needs a look. Its panel shows the load, what needs a look, and the containers with problems.",
            "With the icon on, Porthole keeps watching and sending alerts after you close its window. Turn it on or off in **Settings › General**.",
        ]
        case .away: [
            "Porthole's agent is a small web page that runs on the server as a container, with the same overview and live logs, on a phone too.",
            "`agent/deploy.sh` installs it. It only reads, unless you start it with `PORTHOLE_ACTIONS=1`. Put it behind a login (Cloudflare Access, for example) before you open it to the internet.",
        ]
        case .shortcuts: [
            "Every action has a menu item; these are the keys.",
        ]
        }
    }

    static let keys: [(keys: String, action: LocalizedStringResource)] = [
        ("⌘0", "Show the Overview"),
        ("⇧⌘P", "Scan Logs for Problems"),
        ("⌥⌘E", "Show Warnings and Errors of the Last Day"),
        ("⌥⌘L", "Show Whole Log"),
        ("⌥⌘S", "Start"),
        ("⌥⌘.", "Stop…"),
        ("⌥⌘R", "Restart"),
        ("⌘O", "Open Web Page"),
        ("⇧⌘O", "Open Server's Web Page"),
        ("⌥⌘⌫", "Clear Log on Server…"),
        ("⇧⌘⌫", "Clear All Logs on Server…"),
        ("⇧⌘R", "Reconnect"),
        ("⌘,", "Settings"),
        ("⌘?", "Porthole Help"),
    ]
}

/// Help › Porthole Help, which needs the scene's openWindow.
struct HelpMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Porthole Help") { openWindow(id: "help") }
            .keyboardShortcut("?", modifiers: .command)
    }
}
