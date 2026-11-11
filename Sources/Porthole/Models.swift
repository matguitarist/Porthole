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
                        if let date = line.date {
                            if let since, date <= since { continue }   // already shown
                            newest.value = date
                        }
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
    var value: Date? {
        get { lock.withLock { date } }
        set { lock.withLock { date = newValue } }
    }
}

/// App-wide state that menus, toolbars, and views share.
@Observable
final class AppModel {
    private(set) var client: any DockerClient
    private(set) var containers: [Container] = []
    private(set) var connection = Connection.connecting
    var selection: String? {
        didSet { if selection != oldValue { selectionChanged(from: oldValue) } }
    }
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
        if selection == nil || !containers.contains(where: { $0.name == selection }) {
            selection = (containers.first(where: \.isRunning) ?? containers.first)?.name
        } else {
            selectionChanged(from: nil)
        }
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
        client = Self.makeClient()
        Task { await connect() }
    }

    private func loadContainers() async throws {
        let list = try await client.containers()
        containers = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
