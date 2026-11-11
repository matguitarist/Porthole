import AppKit
import Foundation
import LogKitUI
import PortholeKit

/// Where Porthole connects, from Settings > Server.
enum ServerSettings {
    static let targetKey = "server.target"
    static let keyFileKey = "server.keyFile"
    static let tailKey = "server.tail"
    static let defaultTarget = "root@192.168.40.210"
    static let defaultKeyFile = "~/.ssh/id_ed25519_homeserver"

    static var target: String { UserDefaults.standard.string(forKey: targetKey) ?? defaultTarget }
    static var keyFile: String { UserDefaults.standard.string(forKey: keyFileKey) ?? defaultKeyFile }
    static var tail: Int {
        let value = UserDefaults.standard.integer(forKey: tailKey)
        return value > 0 ? value : 1000
    }

    /// The host part of "root@192.168.40.210", for web pages.
    static var host: String {
        let target = target
        return target.split(separator: "@").last.map(String.init) ?? target
    }
}

enum Connection: Equatable {
    case connecting
    case connected
    case failed(String)
}

/// One container's log: its own store and viewer state, kept while the app
/// runs so filters and Clear survive moving between containers.
@Observable
final class ContainerLog {
    let name: String
    let store = LogStore(limit: 20_000)
    let viewer: LogViewerModel
    var state: ContainerState?
    private var follow: Task<Void, Never>?
    /// Docker's time of the newest line, to pick up where the stream stopped.
    private let newest = NewestDate()

    init(name: String) {
        self.name = name
        viewer = LogViewerModel(store: store)
    }

    var isFollowing: Bool { follow != nil }

    /// Streams new lines into the store until `stop()`. Reconnects after a
    /// dropped connection from the newest line it has.
    func start(client: any DockerClient, tail: Int) {
        guard follow == nil else { return }
        let store = store, name = name, newest = newest
        follow = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                do {
                    let since = newest.value
                    for try await raw in client.logs(name, tail: tail, since: since.map { $0.addingTimeInterval(-1) }) {
                        let line = LogLine.parse(Substring(raw))
                        // Already shown (the reconnect's first second, or an old stream still finishing).
                        if let date = line.date, !newest.advance(to: date) { continue }
                        store.post(line.level, line.message, source: line.source, date: line.date ?? Date(), detail: line.detail)
                    }
                } catch {
                    if Task.isCancelled { return }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        follow?.cancel()
        follow = nil
    }

    /// The header's facts and the insights, from `docker inspect`.
    func update(state: ContainerState, container: Container?) {
        self.state = state
        store.insights = ContainerInsights.make(for: state)
        var metadata: [LogMetadata] = []
        if let container {
            metadata.append(LogMetadata(container.image, symbol: "shippingbox"))
            metadata.append(LogMetadata(container.status, symbol: container.isRunning ? "play.circle" : "stop.circle"))
        }
        if !state.restartPolicy.isEmpty, state.restartPolicy != "no" {
            metadata.append(LogMetadata("Restart: \(state.restartPolicy)", symbol: "arrow.clockwise"))
        }
        store.metadata = metadata
    }
}

/// Written by the log stream off the main actor.
nonisolated final class NewestDate: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date?
    var value: Date? { lock.withLock { date } }

    /// Moves to `newer` and returns true, or false when it isn't newer.
    func advance(to newer: Date) -> Bool {
        lock.withLock {
            if let date, newer <= date { return false }
            date = newer
            return true
        }
    }
}

/// What the sidebar shows in the detail: the server's overview or one container.
enum Page: Hashable {
    case overview
    case container(String)
}

/// App-wide state that menus, toolbars, and views share.
@Observable
final class AppModel {
    private(set) var client: any DockerClient
    private(set) var containers: [Container] = []
    private(set) var connection = Connection.connecting
    var page: Page? = .overview {
        didSet { if page != oldValue { selectionChanged(from: oldValue.flatMap(Self.name)) } }
    }
    /// The container shown, or nil on the overview.
    var selection: String? {
        get { page.flatMap(Self.name) }
        set { page = newValue.map { .container($0) } }
    }
    private static func name(_ page: Page) -> String? {
        if case .container(let name) = page { return name }
        return nil
    }

    // The overview
    private(set) var hostInfo: HostInfo?
    private(set) var hostLoad = HostLoad()
    private(set) var problems: [String: ProblemSummary] = [:]
    private(set) var problemsScanned: Date?
    private(set) var scanningProblems = false
    // Icons
    private(set) var serverIcons = ServerIcons()
    private(set) var iconImages: [String: NSImage] = [:]
    @ObservationIgnored private var iconRequests: Set<String> = []
    var search = ""
    private(set) var stats: [String: StatsHistory] = [:]
    /// A container whose Stop waits for confirmation.
    var confirmStop: String?
    /// A failed Start, Stop or Restart.
    var actionError: String?
    private(set) var busy: Set<String> = []
    private var logs: [String: ContainerLog] = [:]
    private var watchers: [Task<Void, Never>] = []
    private var refreshTask: Task<Void, Never>?
    /// Settings reopens on the last tab. Test and snapshot runs leave it alone.
    var settingsTab: SettingsTab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settings.tab") ?? "") ?? .server {
        didSet { if !Store.isOverridden { UserDefaults.standard.set(settingsTab.rawValue, forKey: "settings.tab") } }
    }

    /// For the app delegate at quit.
    static weak var current: AppModel?

    init() {
        client = Self.makeClient()
        Self.current = self
    }

    static func makeClient() -> any DockerClient {
        if Store.isOverridden { return DemoDocker() }
        return SSHDocker(target: ServerSettings.target, identityFile: ServerSettings.keyFile)
    }

    var selected: Container? { containers.first { $0.name == selection } }
    var selectedLog: ContainerLog? { selection.map(log(for:)) }

    func log(for name: String) -> ContainerLog {
        if let log = logs[name] { return log }
        let log = ContainerLog(name: name)
        logs[name] = log
        return log
    }

    var shown: [Container] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return containers }
        return containers.filter { $0.name.localizedStandardContains(query) || $0.image.localizedStandardContains(query) }
    }

    var running: [Container] { shown.filter(\.isRunning) }
    var stopped: [Container] { shown.filter { !$0.isRunning } }

    // MARK: Connecting

    /// Loads the containers and starts following events and usage.
    func connect() async {
        for watcher in watchers { watcher.cancel() }
        watchers = []
        connection = .connecting
        do {
            try await loadContainers()
            connection = .connected
        } catch {
            connection = .failed(error.localizedDescription)
            return
        }
        if page == nil || (selection != nil && !containers.contains(where: { $0.name == selection })) {
            page = .overview
        } else {
            selectionChanged(from: nil)
        }
        watchers.append(Task { await loadServerDetails() })
        watchers.append(Task { await watchHostLoad() })
        watchers.append(Task { await scanProblemsRegularly() })
        watchers.append(Task { await watchEvents() })
        watchers.append(Task { await watchStats() })
        watchers.append(Task { await refreshInspectRegularly() })
    }

    /// After the address changes in Settings.
    func reconnect() {
        if let ssh = client as? SSHDocker { Task { await ssh.disconnect() } }
        for log in logs.values { log.stop() }
        logs = [:]
        stats = [:]
        hostLoad = HostLoad()
        hostLoadPending = HostLoad()
        hostInfo = nil
        problems = [:]
        iconImages = [:]
        iconRequests = []
        client = Self.makeClient()
        Task { await connect() }
    }

    private func loadContainers() async throws {
        let list = try await client.containers()
        containers = list.map(serverIcons.withTemplateWebUI)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Overview

    private func loadServerDetails() async {
        if let icons = try? await client.serverIcons() {
            serverIcons = icons
            containers = containers.map(icons.withTemplateWebUI)
        }
        while !Task.isCancelled {
            if let info = try? await client.hostInfo() { hostInfo = info }
            try? await Task.sleep(for: .seconds(60))
        }
    }

    private func watchHostLoad() async {
        while !Task.isCancelled {
            do {
                for try await line in client.hostLoad() {
                    hostLoadPending.read(line)
                    // The view updates once per reading, at its end.
                    if line == "@end" { hostLoad = hostLoadPending }
                }
            } catch {}
            try? await Task.sleep(for: .seconds(5))
        }
    }
    @ObservationIgnored private var hostLoadPending = HostLoad()

    private func scanProblemsRegularly() async {
        while !Task.isCancelled {
            await scanProblems()
            try? await Task.sleep(for: .seconds(300))
        }
    }

    /// Reads the last day's warnings and errors of every container.
    func scanProblems() async {
        guard !scanningProblems else { return }
        scanningProblems = true
        defer { scanningProblems = false }
        if let found = try? await client.problems() {
            problems = found
            problemsScanned = Date()
        }
    }

    /// Containers with problems, most errors first.
    var containersWithProblems: [(container: Container, summary: ProblemSummary)] {
        containers.compactMap { container in
            guard let summary = problems[container.name], summary.total > 0 else { return nil }
            return (container, summary)
        }
        .sorted { ($0.summary.errors, $0.summary.warnings, $1.container.name) > ($1.summary.errors, $1.summary.warnings, $0.container.name) }
    }

    /// Containers that need a look: unhealthy, restarting, or stopped by a crash.
    var containersNeedingAttention: [Container] {
        containers.filter { container in
            container.health == "unhealthy" || container.state == "restarting"
                || (!container.isRunning && (container.exitCode.map { $0 != 0 && $0 != 143 } ?? false))
        }
    }

    /// Opens a container's log showing only its problems (or all of it).
    func open(_ name: String, problemsOnly: Bool = false) {
        selection = name
        let viewer = log(for: name).viewer
        viewer.filter.levels = problemsOnly ? [.warning, .error, .critical] : viewer.defaultFilter.levels
    }

    // MARK: Icons

    /// The first of the container's icon sources that loaded.
    func iconImage(for container: Container) -> NSImage? {
        for source in serverIcons.icons(for: container) {
            if let image = iconImage(source) { return image }
        }
        return nil
    }

    /// An icon, loaded once: from the web, or from the server over SSH.
    /// NSImage reads PNG, ICO and SVG (Uptime Kuma's), which AsyncImage can't.
    private func iconImage(_ source: IconSource) -> NSImage? {
        let key: String
        switch source {
        case .url(let url): key = url.absoluteString
        case .serverFile(let path): key = path
        }
        if let image = iconImages[key] { return image }
        guard !iconRequests.contains(key) else { return nil }
        iconRequests.insert(key)
        Task {
            let data: Data?
            switch source {
            case .url(let url): data = try? await URLSession.shared.data(from: url).0
            case .serverFile(let path): data = try? await client.serverFile(path)
            }
            if let data, let image = NSImage(data: data) { iconImages[key] = image }
        }
        return nil
    }

    private func watchEvents() async {
        while !Task.isCancelled {
            do {
                for try await line in client.events() {
                    guard let event = DockerEvent.parse(line), event.changesList else { continue }
                    scheduleRefresh(about: event.name)
                }
            } catch {}
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func watchStats() async {
        while !Task.isCancelled {
            do {
                for try await line in client.stats() {
                    guard let sample = ContainerStats.parse(line) else { continue }
                    let name = sample.name.isEmpty ? containers.first(where: { $0.id.hasPrefix(sample.id) })?.name ?? sample.id : sample.name
                    stats[name, default: StatsHistory()].add(sample)
                }
            } catch {}
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func refreshInspectRegularly() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            if let selection { await inspect(selection) }
        }
    }

    /// Events come in bursts (kill, die, stop, start): one refresh for a burst.
    private func scheduleRefresh(about name: String) {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            try? await loadContainers()
            if name == selection || selection == nil { await inspect(name) }
            // A container that came back starts its log stream again.
            if let selection, let log = logs[selection], !log.isFollowing { log.start(client: client, tail: ServerSettings.tail) }
        }
    }

    private func selectionChanged(from old: String?) {
        if let old { logs[old]?.stop() }
        guard let selection else { return }
        log(for: selection).start(client: client, tail: ServerSettings.tail)
        Task { await inspect(selection) }
    }

    func inspect(_ name: String) async {
        guard let state = try? await client.inspect(name) else { return }
        log(for: name).update(state: state, container: containers.first { $0.name == name })
    }

    // MARK: Actions

    func canPerform(_ action: ContainerAction, on container: Container? = nil) -> Bool {
        guard let container = container ?? selected, !busy.contains(container.name) else { return false }
        switch action {
        case .start: return !container.isRunning
        case .stop, .restart: return container.isRunning
        }
    }

    /// Stop asks first; Start and Restart run at once.
    func request(_ action: ContainerAction, on name: String? = nil) {
        guard let name = name ?? selection else { return }
        if action == .stop { confirmStop = name } else { Task { await perform(action, on: name) } }
    }

    func perform(_ action: ContainerAction, on name: String) async {
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            try await client.perform(action, on: name)
        } catch {
            actionError = error.localizedDescription
        }
        try? await loadContainers()
        await inspect(name)
        if action != .stop, name == selection {
            let log = log(for: name)
            if !log.isFollowing { log.start(client: client, tail: ServerSettings.tail) }
        }
    }

    func webUI(for container: Container? = nil) -> URL? {
        (container ?? selected)?.webUI(host: ServerSettings.host)
    }
}
