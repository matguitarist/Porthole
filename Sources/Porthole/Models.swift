import AppKit
import Foundation
import LogKitUI
import PortholeKit

/// Where Porthole connects, from Settings > Server.
enum ServerSettings {
    static let targetKey = "server.target"
    static let keyFileKey = "server.keyFile"
    static let tailKey = "server.tail"
    /// Empty until set: a new install asks for the server.
    static let defaultTarget = ""
    /// Empty: ssh's own keys and ~/.ssh/config.
    static let defaultKeyFile = ""
    static let exampleTarget = "root@192.168.1.10"

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

/// One container's log, or a compose stack's merged log: its own store and
/// viewer state, kept while the app runs so filters and Clear survive
/// moving between pages.
@Observable
final class ContainerLog {
    /// The container's name, or "stack:<project>".
    let key: String
    /// The containers it follows: one, or a stack's.
    let names: [String]
    let store = LogStore(limit: 20_000)
    let viewer: LogViewerModel
    var state: ContainerState?
    /// Set when the log holds a time window ("the last 24 hours") instead of the last lines.
    private(set) var loadedSince: Date?
    private var follow: Task<Void, Never>?
    /// Docker's time of the newest line per container, to pick up where the stream stopped.
    private let newest = NewestDates()
    private let ignore: IgnoreBox

    init(key: String, names: [String], ignore: IgnoreBox) {
        self.key = key
        self.names = names
        self.ignore = ignore
        viewer = LogViewerModel(store: store)
    }

    var isStack: Bool { names.count > 1 }
    var isFollowing: Bool { follow != nil }

    /// Streams new lines into the store until `stop()`. Reconnects after a
    /// dropped connection from the newest line it has.
    func start(client: any DockerClient, tail: Int) {
        guard follow == nil else { return }
        let store = store, names = names, newest = newest, ignore = ignore, window = loadedSince
        let merged = names.count > 1
        follow = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                do {
                    let since = newest.oldest(of: names).map { $0.addingTimeInterval(-1) } ?? window
                    for try await raw in client.logs(names, tail: tail, since: since) {
                        var container = names[0]
                        var text = Substring(raw)
                        if merged, let mark = raw.firstIndex(of: Character(LogLine.mergedSeparator)) {
                            container = String(raw[..<mark])
                            text = raw[raw.index(after: mark)...]
                        }
                        var line = LogLine.parse(text)
                        // Already shown (the reconnect's first second, or an old stream still finishing).
                        if let date = line.date, !newest.advance(container, to: date) { continue }
                        // Known noise: dimmed as Debug, with its own level word kept.
                        if line.level.isProblem, ignore.rules.ignores(line.message, in: container) {
                            line.code = line.code ?? line.level.code
                            line.level = .debug
                        }
                        let source = merged ? Stacks.shortName(container, in: names) : line.source
                        let message = merged && !line.source.isEmpty ? "[\(line.source)] \(line.message)" : line.message
                        store.post(line.level, message, source: source, date: line.date ?? Date(), detail: line.detail)
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

    /// Loads everything since `date` (or the last lines again, with nil), from scratch.
    func reload(client: any DockerClient, tail: Int, since date: Date?) {
        stop()
        store.clearMemory()
        newest.reset()
        loadedSince = date
        start(client: client, tail: tail)
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

/// Compose stacks: containers that share a compose project.
enum Stacks {
    /// "azeroth-survivors-cmangos-mangosd-1" in the "azeroth-survivors-cmangos" stack → "mangosd".
    nonisolated static func shortName(_ name: String, in names: [String]) -> String {
        var short = name
        let prefix = commonPrefix(names)
        if prefix.count > 2, short.hasPrefix(prefix), short.count > prefix.count { short.removeFirst(prefix.count) }
        if let dash = short.lastIndex(of: "-"), short[short.index(after: dash)...].allSatisfy(\.isNumber), dash > short.startIndex {
            short = String(short[..<dash])
        }
        return short
    }

    nonisolated static func commonPrefix(_ names: [String]) -> String {
        guard var prefix = names.first else { return "" }
        for name in names.dropFirst() {
            while !name.hasPrefix(prefix) { prefix.removeLast() }
        }
        // Up to the last separator, so "azeroth-survivors-cmangos-m" doesn't eat a letter.
        if let dash = prefix.lastIndex(where: { $0 == "-" || $0 == "_" }) { return String(prefix[...dash]) }
        return ""
    }
}

/// Written by the log streams off the main actor.
nonisolated final class NewestDates: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [String: Date] = [:]

    /// The oldest of the containers' newest lines: where a reconnect picks up.
    func oldest(of names: [String]) -> Date? {
        lock.withLock {
            let known = names.compactMap { dates[$0] }
            return known.count == names.count ? known.min() : nil
        }
    }

    /// Moves the container to `newer` and returns true, or false when it isn't newer.
    func advance(_ name: String, to newer: Date) -> Bool {
        lock.withLock {
            if let date = dates[name], newer <= date { return false }
            dates[name] = newer
            return true
        }
    }

    func reset() { lock.withLock { dates = [:] } }
}

/// The ignore rules, read by the log streams off the main actor.
nonisolated final class IgnoreBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = IgnoreRules()
    var rules: IgnoreRules {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// What the sidebar shows in the detail: the server's overview, one container, or a compose stack.
enum Page: Hashable {
    case overview
    case container(String)
    case stack(String)

    /// The key of the page's log.
    var logKey: String? {
        switch self {
        case .overview: nil
        case .container(let name): name
        case .stack(let project): "stack:\(project)"
        }
    }
}

/// Logs to empty on the server, waiting for confirmation.
struct ClearRequest: Identifiable {
    var names: [String]
    var title: String
    var id: String { names.joined(separator: ",") }
}

/// App-wide state that menus, toolbars, and views share.
@Observable
final class AppModel {
    private(set) var client: any DockerClient
    private(set) var containers: [Container] = []
    private(set) var connection = Connection.connecting
    var page: Page? = .overview {
        didSet { if page != oldValue { pageChanged(from: oldValue) } }
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
    /// An ignore rule being written.
    var ignoreDraft: IgnoreDraft?
    /// Clearing logs on the server, waiting for confirmation.
    var confirmClear: ClearRequest?
    private(set) var clearing = false
    /// Notable events of the last day (starts, crashes, health), newest first.
    private(set) var recentEvents: [DockerEvent] = []
    /// Known noise, saved on this Mac.
    private(set) var ignoreRules = IgnoreRules() {
        didSet { ignoreBox.rules = ignoreRules }
    }
    let ignoreBox = IgnoreBox()
    let notifier = Notifier()
    private var logs: [String: ContainerLog] = [:]
    private var watchers: [Task<Void, Never>] = []
    private var refreshTask: Task<Void, Never>?
    /// Settings reopens on the last tab. Test and snapshot runs leave it alone.
    var settingsTab: SettingsTab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settings.tab") ?? "") ?? .general {
        didSet { if !Store.isOverridden { UserDefaults.standard.set(settingsTab.rawValue, forKey: "settings.tab") } }
    }

    /// The menu bar icon. Off in test runs, which never touch the real menu bar.
    var showInMenuBar = !Store.isOverridden && MenuBarStatus.isShown {
        didSet { if !Store.isOverridden { UserDefaults.standard.set(showInMenuBar, forKey: MenuBarStatus.showKey) } }
    }

    /// For the app delegate at quit.
    static weak var current: AppModel?

    init() {
        client = Self.makeClient()
        Self.current = self
        if !Store.isOverridden, let data = UserDefaults.standard.data(forKey: "ignoreRules"),
           let rules = try? JSONDecoder().decode(IgnoreRules.self, from: data) {
            ignoreRules = rules
        }
        ignoreBox.rules = ignoreRules
    }

    static func makeClient() -> any DockerClient {
        if Store.isOverridden { return DemoDocker() }
        return SSHDocker(target: ServerSettings.target, identityFile: ServerSettings.keyFile)
    }

    var selected: Container? { containers.first { $0.name == selection } }

    func log(for name: String) -> ContainerLog {
        if let log = logs[name] { return log }
        let log = ContainerLog(key: name, names: [name], ignore: ignoreBox)
        logs[name] = log
        return log
    }

    /// A compose stack's merged log.
    func stackLog(_ project: String) -> ContainerLog {
        let key = "stack:\(project)"
        if let log = logs[key] { return log }
        let log = ContainerLog(key: key, names: stacks[project]?.map(\.name) ?? [], ignore: ignoreBox)
        logs[key] = log
        return log
    }

    /// The log of a container or stack page.
    func log(for page: Page) -> ContainerLog? {
        switch page {
        case .overview: nil
        case .container(let name): log(for: name)
        case .stack(let project): stackLog(project)
        }
    }

    /// Compose projects with more than one container.
    var stacks: [String: [Container]] {
        Dictionary(grouping: containers.filter { $0.project != nil }, by: { $0.project ?? "" }).filter { $0.value.count > 1 }
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
        if !Store.isOverridden, ServerSettings.target.isEmpty {
            connection = .failed(String(localized: "Enter your server's SSH address in Settings › Server."))
            return
        }
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
            pageChanged(from: nil)
        }
        Task { await notifier.requestPermission() }
        watchers.append(Task { await loadRecentEvents() })
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
                    if line == "@end" {
                        hostLoad = hostLoadPending
                        if let busy = DockerdWatch.busy(hostLoad.dockerdCPU) { notifier.dockerBusy(busy) }
                    }
                }
            } catch {}
            try? await Task.sleep(for: .seconds(5))
        }
    }
    @ObservationIgnored private var hostLoadPending = HostLoad()

    static let scanIntervalKey = "scan.minutes"

    private func scanProblemsRegularly() async {
        while !Task.isCancelled {
            await scanProblems()
            let minutes = UserDefaults.standard.object(forKey: Self.scanIntervalKey) as? Int ?? 5
            try? await Task.sleep(for: .seconds(max(1, minutes) * 60))
        }
    }

    /// Sparkle's daily check, for Settings > Updates.
    var checksForUpdates: Bool {
        get { access(keyPath: \.checksForUpdates); return Updater.shared.automaticallyChecks }
        set { withMutation(keyPath: \.checksForUpdates) { Updater.shared.automaticallyChecks = newValue } }
    }

    /// Reads the last day's warnings and errors of every container.
    func scanProblems() async {
        guard !scanningProblems else { return }
        scanningProblems = true
        defer { scanningProblems = false }
        if let found = try? await client.problems(ignoring: ignoreRules) {
            let previous = problemsScanned == nil ? nil : problems
            problems = found
            problemsScanned = Date()
            if let previous { notifier.newErrors(found, since: previous) }
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

    /// Opens a container's log. For its problems: the whole last day, only warnings and errors.
    func open(_ name: String, problemsOnly: Bool = false) {
        let log = log(for: name)
        if problemsOnly, log.loadedSince == nil {
            log.reload(client: client, tail: ServerSettings.tail, since: Date().addingTimeInterval(-Double(ProblemSummary.hours) * 3600))
        }
        selection = name
        log.viewer.filter.levels = problemsOnly ? [.warning, .error, .critical] : log.viewer.defaultFilter.levels
    }

    /// Back to the last lines after a day's window.
    func loadLatest(_ log: ContainerLog) {
        log.reload(client: client, tail: ServerSettings.tail, since: nil)
    }

    // MARK: Ignoring and clearing

    func ignore(_ rule: IgnoreRules.Rule) {
        guard !rule.text.trimmingCharacters(in: .whitespaces).isEmpty, !ignoreRules.rules.contains(rule) else { return }
        ignoreRules.rules.append(rule)
        saveIgnoreRules()
        Task { await scanProblems() }
    }

    func removeIgnore(_ rule: IgnoreRules.Rule) {
        ignoreRules.rules.removeAll { $0 == rule }
        saveIgnoreRules()
        Task { await scanProblems() }
    }

    private func saveIgnoreRules() {
        guard !Store.isOverridden, let data = try? JSONEncoder().encode(ignoreRules) else { return }
        UserDefaults.standard.set(data, forKey: "ignoreRules")
    }

    /// Asks first: clearing can't be undone.
    func requestClearLogs(_ names: [String]? = nil) {
        if let names, names.count == 1 {
            confirmClear = ClearRequest(names: names, title: names[0])
        } else {
            let all = names ?? containers.map(\.name)
            confirmClear = ClearRequest(names: all, title: names == nil ? String(localized: "all \(all.count) containers") : String(localized: "\(all.count) containers"))
        }
    }

    /// Empties the containers' log files on the server, then reads everything again.
    func clearLogs(_ names: [String]) async {
        clearing = true
        defer { clearing = false }
        do {
            try await client.clearLogs(names)
        } catch {
            actionError = error.localizedDescription
            return
        }
        let cleared = Set(names)
        for log in logs.values where !cleared.isDisjoint(with: log.names) {
            if log.isFollowing { log.reload(client: client, tail: ServerSettings.tail, since: nil) } else { log.store.clearMemory() }
        }
        problemsScanned = nil   // no "new errors" notification for what was there before
        await scanProblems()
    }

    // MARK: Events

    private func loadRecentEvents() async {
        if let events = try? await client.recentEvents(hours: 24) {
            recentEvents = events.sorted { $0.date > $1.date }
        }
    }

    private func record(_ event: DockerEvent) {
        let problem = stopTracker.isProblem(event)
        guard event.isNotable else { return }
        recentEvents.insert(event, at: 0)
        if recentEvents.count > 300 { recentEvents.removeLast(recentEvents.count - 300) }
        notifier.event(event, problem: problem, recent: recentEvents)
    }
    @ObservationIgnored private var stopTracker = StopTracker()

    /// When Docker last started, if it was within the problem scan's hours.
    var dockerRestarted: Date? {
        guard let uptime = hostLoad.dockerdUptime, uptime < TimeInterval(ProblemSummary.hours * 3600) else { return nil }
        return Date(timeIntervalSinceNow: -uptime)
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
                    guard let event = DockerEvent.parse(line) else { continue }
                    record(event)
                    if event.changesList { scheduleRefresh(about: event.name) }
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
            if let key = page?.logKey, let log = logs[key], !log.isFollowing { log.start(client: client, tail: ServerSettings.tail) }
        }
    }

    private func pageChanged(from old: Page?) {
        if let key = old?.logKey { logs[key]?.stop() }
        guard let page, let log = log(for: page) else { return }
        log.start(client: client, tail: ServerSettings.tail)
        if let selection { Task { await inspect(selection) } }
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
