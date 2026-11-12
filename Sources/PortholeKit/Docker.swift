import Foundation

/// A container from `docker ps -a --format '{{json .}}'`.
public struct Container: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var image: String
    /// "running", "exited", "restarting", "paused", "created", "dead".
    public var state: String
    /// "Up 6 hours", "Exited (137) 2 days ago".
    public var status: String
    /// "healthy", "unhealthy", "starting", or nil without a health check.
    public var health: String?
    public var ports: String
    public var labels: [String: String]

    public init(id: String, name: String, image: String, state: String, status: String,
                health: String? = nil, ports: String = "", labels: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.health = health
        self.ports = ports
        self.labels = labels
    }

    public var isRunning: Bool { state == "running" || state == "restarting" }

    /// The exit code in "Exited (137) 2 days ago".
    public var exitCode: Int? {
        guard status.hasPrefix("Exited ("), let close = status.firstIndex(of: ")") else { return nil }
        return Int(status[status.index(status.startIndex, offsetBy: 8)..<close])
    }

    /// Unraid's icon for the container, from its template.
    public var iconURL: URL? { labels["net.unraid.docker.icon"].flatMap { URL(string: $0) } }

    /// The compose project it belongs to.
    public var project: String? { labels["com.docker.compose.project"] }

    /// The web page Unraid's template points to, with the host filled in:
    /// "http://[IP]:[PORT:11011]" → "http://192.168.40.210:11011".
    public func webUI(host: String) -> URL? {
        guard var template = labels["net.unraid.docker.webui"], !template.isEmpty else { return nil }
        template = template.replacingOccurrences(of: "[IP]", with: host)
        while let open = template.range(of: "[PORT:"), let close = template[open.upperBound...].firstIndex(of: "]") {
            let port = template[open.upperBound..<close]
            template.replaceSubrange(open.lowerBound...close, with: port)
        }
        return URL(string: template)
    }

    /// Reads one line of `docker ps -a --format '{{json .}}'`.
    public static func parse(_ line: some StringProtocol) -> Container? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = object["ID"] as? String, let name = object["Names"] as? String else { return nil }
        let state = object["State"] as? String ?? ""
        // A stopped container keeps its last health status; it means nothing until it runs again.
        let running = state == "running" || state == "restarting"
        let health = running ? (object["HealthStatus"] as? String).flatMap { $0.isEmpty || $0 == "none" ? nil : $0 } : nil
        return Container(id: id, name: name.split(separator: ",").first.map(String.init) ?? name,
                         image: object["Image"] as? String ?? "",
                         state: state,
                         status: object["Status"] as? String ?? "",
                         health: running ? health ?? Self.health(fromStatus: object["Status"] as? String ?? "") : nil,
                         ports: object["Ports"] as? String ?? "",
                         labels: Self.labels(object["Labels"] as? String ?? ""))
    }

    /// Older Docker puts health in the status: "Up 2 hours (unhealthy)".
    static func health(fromStatus status: String) -> String? {
        for word in ["unhealthy", "healthy", "health: starting"] where status.contains("(\(word))") {
            return word == "health: starting" ? "starting" : word
        }
        return nil
    }

    /// "a=1,b=http://x,y" → labels. Values can contain commas, so a piece
    /// without "=" belongs to the value before it.
    static func labels(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var lastKey: String?
        for piece in text.split(separator: ",", omittingEmptySubsequences: false) {
            if let equals = piece.firstIndex(of: "="), !piece[..<equals].contains(" "), !piece[..<equals].isEmpty {
                let key = String(piece[..<equals])
                result[key] = String(piece[piece.index(after: equals)...])
                lastKey = key
            } else if let lastKey {
                result[lastKey, default: ""] += "," + piece
            }
        }
        return result
    }
}

/// One sample of `docker stats --format '{{json .}}'`.
public struct ContainerStats: Hashable, Sendable {
    public var id: String
    public var name: String
    /// Percent of one CPU core: 150 means one and a half cores.
    public var cpu: Double
    public var memoryBytes: Double
    public var memoryLimitBytes: Double

    public init(id: String, name: String, cpu: Double, memoryBytes: Double, memoryLimitBytes: Double) {
        self.id = id
        self.name = name
        self.cpu = cpu
        self.memoryBytes = memoryBytes
        self.memoryLimitBytes = memoryLimitBytes
    }

    /// Reads a line; `docker stats` wraps lines in terminal codes.
    public static func parse(_ raw: some StringProtocol) -> ContainerStats? {
        let line = ANSI.strip(raw)   // "\u{1B}[H" before, "\u{1B}[K" after each line
        guard let brace = line.firstIndex(of: "{"),
              let object = try? JSONSerialization.jsonObject(with: Data(line[brace...].utf8)) as? [String: Any],
              let id = object["ID"] as? String ?? object["Container"] as? String else { return nil }
        let cpu = Double((object["CPUPerc"] as? String ?? "").replacingOccurrences(of: "%", with: "")) ?? 0
        let usage = (object["MemUsage"] as? String ?? "").components(separatedBy: " / ")
        return ContainerStats(id: id, name: object["Name"] as? String ?? "", cpu: cpu,
                              memoryBytes: usage.first.flatMap(bytes) ?? 0,
                              memoryLimitBytes: usage.count > 1 ? bytes(usage[1]) ?? 0 : 0)
    }

    /// "12.5MiB", "1.2GiB", "512kB", "0B" → bytes.
    public static func bytes(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let number = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(number) else { return nil }
        let units: [String: Double] = ["B": 1, "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12,
                                       "KiB": 1024, "MiB": 1_048_576, "GiB": 1_073_741_824, "TiB": 1_099_511_627_776]
        return value * (units[String(trimmed.dropFirst(number.count))] ?? 1)
    }
}

/// The last minutes of a container's usage, for the sparklines.
public struct StatsHistory: Sendable, Equatable {
    public var cpu: [Double] = []
    public var memory: [Double] = []
    public var memoryLimit: Double = 0
    public let capacity: Int

    public init(capacity: Int = 60) { self.capacity = capacity }

    public mutating func add(_ sample: ContainerStats) {
        cpu.append(sample.cpu)
        memory.append(sample.memoryBytes)
        memoryLimit = sample.memoryLimitBytes
        if cpu.count > capacity { cpu.removeFirst(cpu.count - capacity) }
        if memory.count > capacity { memory.removeFirst(memory.count - capacity) }
    }
}

/// What `docker inspect` says about a container's state, plus its starts in
/// the last hour (from `docker events`).
public struct ContainerState: Sendable, Equatable {
    public var status: String
    public var exitCode: Int
    public var oomKilled: Bool
    public var restartCount: Int
    public var error: String
    public var startedAt: Date?
    public var finishedAt: Date?
    public var health: String?
    public var failingStreak: Int
    public var lastHealthOutput: String?
    public var restartPolicy: String
    public var startsLastHour = 0

    public init(status: String, exitCode: Int = 0, oomKilled: Bool = false, restartCount: Int = 0, error: String = "",
                startedAt: Date? = nil, finishedAt: Date? = nil, health: String? = nil, failingStreak: Int = 0,
                lastHealthOutput: String? = nil, restartPolicy: String = "", startsLastHour: Int = 0) {
        self.status = status
        self.exitCode = exitCode
        self.oomKilled = oomKilled
        self.restartCount = restartCount
        self.error = error
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.health = health
        self.failingStreak = failingStreak
        self.lastHealthOutput = lastHealthOutput
        self.restartPolicy = restartPolicy
        self.startsLastHour = startsLastHour
    }

    /// Reads `docker inspect <name>` (a JSON array with one object).
    public static func parse(inspect text: String) -> ContainerState? {
        guard let array = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]],
              let object = array.first, let state = object["State"] as? [String: Any] else { return nil }
        let health = state["Health"] as? [String: Any]
        let logs = health?["Log"] as? [[String: Any]] ?? []
        func date(_ key: String) -> Date? {
            guard let text = state[key] as? String, !text.hasPrefix("0001") else { return nil }
            return DockerTime.parse(text)
        }
        let policy = ((object["HostConfig"] as? [String: Any])?["RestartPolicy"] as? [String: Any])?["Name"] as? String
        return ContainerState(status: state["Status"] as? String ?? "",
                              exitCode: state["ExitCode"] as? Int ?? 0,
                              oomKilled: state["OOMKilled"] as? Bool ?? false,
                              restartCount: object["RestartCount"] as? Int ?? 0,
                              error: state["Error"] as? String ?? "",
                              startedAt: date("StartedAt"), finishedAt: date("FinishedAt"),
                              health: health?["Status"] as? String,
                              failingStreak: health?["FailingStreak"] as? Int ?? 0,
                              lastHealthOutput: (logs.last?["Output"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                              restartPolicy: policy ?? "")
    }
}

/// A container event from `docker events --format '{{json .}}'`.
public struct DockerEvent: Sendable, Equatable {
    public var action: String
    public var name: String
    public var date: Date
    /// For "die": the container's exit code.
    public var exitCode: Int?

    public init(action: String, name: String, date: Date, exitCode: Int? = nil) {
        self.action = action
        self.name = name
        self.date = date
        self.exitCode = exitCode
    }

    public static func parse(_ line: some StringProtocol) -> DockerEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              (object["Type"] as? String ?? "container") == "container",
              let action = object["Action"] as? String ?? object["status"] as? String else { return nil }
        let attributes = (object["Actor"] as? [String: Any])?["Attributes"] as? [String: Any]
        let name = attributes?["name"] as? String ?? ""
        let nanos = object["timeNano"] as? Double
        let seconds = object["time"] as? Double ?? 0
        return DockerEvent(action: action, name: name,
                           date: Date(timeIntervalSince1970: nanos.map { $0 / 1e9 } ?? seconds),
                           exitCode: (attributes?["exitCode"] as? String).flatMap { Int($0) })
    }

    /// Worth showing in the overview's timeline and worth a notification.
    public var isNotable: Bool {
        ["start", "die", "oom", "restart"].contains(action) || action == "health_status: unhealthy" || action == "health_status: healthy"
    }

    /// A crash, an out-of-memory kill or a failed health check (not a normal stop).
    public var isProblem: Bool {
        switch action {
        case "oom", "health_status: unhealthy": return true
        case "die": return exitCode.map { $0 != 0 && $0 != 143 } ?? false
        default: return false
        }
    }

    /// "Stopped with exit code 137", "Started", "Became unhealthy".
    public var summary: String {
        switch action {
        case "start": return String(localized: "Started", bundle: .main)
        case "restart": return String(localized: "Restarted", bundle: .main)
        case "oom": return String(localized: "Ran out of memory", bundle: .main)
        case "die":
            // Its own key: "Stopped" is also the sidebar's section, plural in French.
            guard let exitCode, exitCode != 0, exitCode != 143 else {
                return String(localized: "event.stopped", defaultValue: "Stopped", bundle: .main)
            }
            return String(localized: "Stopped with exit code \(exitCode)", bundle: .main)
        case "health_status: unhealthy": return String(localized: "Became unhealthy", bundle: .main)
        case "health_status: healthy": return String(localized: "Healthy again", bundle: .main)
        default: return action.capitalized
        }
    }

    /// Events that change what the sidebar shows.
    public var changesList: Bool {
        ["create", "start", "stop", "die", "destroy", "pause", "unpause", "rename", "restart", "kill"].contains(action)
            || action.hasPrefix("health_status")
    }
}

/// Tells a crash from a stop someone asked for. `docker stop`, `docker restart`
/// and Docker shutting down all send a "kill" event before "die"; a crash
/// doesn't. So a die soon after a kill is a stop, whatever its exit code
/// (137 when the container ignored the signal and was killed).
public struct StopTracker: Sendable {
    public static let window: TimeInterval = 60
    private var kills: [String: Date] = [:]

    public init() {}

    /// Reads one event; true when it is a crash, out of memory or unhealthy.
    public mutating func isProblem(_ event: DockerEvent) -> Bool {
        switch event.action {
        case "kill":
            kills[event.name] = event.date
            return false
        case "die":
            if let kill = kills.removeValue(forKey: event.name), event.date.timeIntervalSince(kill) < Self.window { return false }
            return event.isProblem
        default:
            return event.isProblem
        }
    }
}
