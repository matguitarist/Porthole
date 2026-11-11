import Foundation

/// Sample containers and logs for snapshots and the self-test (APP_SEED=1).
/// Actions change the sample state, so the self-test can check them.
public actor DemoDocker: DockerClient {
    private var list: [Container]
    private let now: Date

    public init(now: Date = Date()) {
        self.now = now
        func labels(_ icon: String, web: String? = nil) -> [String: String] {
            var labels = ["net.unraid.docker.icon": "demo://\(icon)"]
            if let web { labels["net.unraid.docker.webui"] = web }
            return labels
        }
        list = [
            Container(id: "a1", name: "uptime-kuma", image: "louislam/uptime-kuma:2", state: "running", status: "Up 6 hours (healthy)",
                      health: "healthy", labels: labels("kuma", web: "http://[IP]:[PORT:3001]")),
            Container(id: "a2", name: "seerr", image: "seerr/seerr:latest", state: "running", status: "Up 6 hours",
                      labels: labels("seerr", web: "http://[IP]:[PORT:5055]")),
            Container(id: "a3", name: "tautulli", image: "linuxserver/tautulli", state: "running", status: "Up 2 hours (unhealthy)",
                      health: "unhealthy", labels: labels("tautulli", web: "http://[IP]:[PORT:8181]")),
            Container(id: "a4", name: "syncthing", image: "syncthing/syncthing", state: "running", status: "Up 3 days"),
            Container(id: "a5", name: "crowdsec", image: "crowdsecurity/crowdsec", state: "running", status: "Up 6 hours"),
            Container(id: "a6", name: "mangosd", image: "cmangos/mangosd", state: "exited", status: "Exited (139) 9 days ago",
                      labels: ["com.docker.compose.project": "azeroth"]),
            Container(id: "a7", name: "kometa", image: "kometateam/kometa", state: "exited", status: "Exited (0) 6 hours ago"),
        ]
    }

    public func containers() async throws -> [Container] { list }

    public func inspect(_ name: String) async throws -> ContainerState {
        guard let container = list.first(where: { $0.name == name }) else {
            throw DockerError.command(status: 1, message: "Docker has no container named \(name).")
        }
        switch name {
        case "tautulli":
            return ContainerState(status: "running", health: "unhealthy", failingStreak: 4,
                                  lastHealthOutput: "curl: (7) Failed to connect to localhost port 8181: Connection refused",
                                  startsLastHour: 3)
        case "mangosd":
            return ContainerState(status: container.state, exitCode: container.exitCode ?? 0,
                                  finishedAt: now.addingTimeInterval(-9 * 86_400))
        default:
            return ContainerState(status: container.state, exitCode: container.exitCode ?? 0, health: container.health)
        }
    }

    public nonisolated func logs(_ name: String, tail: Int, since: Date?) -> AsyncThrowingStream<String, Error> {
        let lines = Self.sampleLines(for: name, now: now)
        return AsyncThrowingStream { continuation in
            if since == nil { for line in lines.suffix(tail) { continuation.yield(line) } }
            // Stays open like `docker logs -f`.
        }
    }

    public nonisolated func events() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { _ in }
    }

    public nonisolated func stats() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var round = 0
                while !Task.isCancelled {
                    for (index, name) in ["uptime-kuma", "seerr", "tautulli", "syncthing", "crowdsec"].enumerated() {
                        let wave = (sin(Double(round + index * 7) / 3) + 1) / 2
                        let cpu = [2.0, 0.6, 14, 4, 1.2][index] * (0.6 + wave)
                        let memory = [182.0, 240, 96, 64, 120][index] * (0.95 + wave / 10)
                        continuation.yield(#"{"ID":"a\#(index + 1)","Name":"\#(name)","CPUPerc":"\#(String(format: "%.2f", cpu))%","MemUsage":"\#(String(format: "%.1f", memory))MiB / 31.2GiB"}"#)
                    }
                    round += 1
                    try? await Task.sleep(for: round < 40 ? .milliseconds(10) : .seconds(2))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func perform(_ action: ContainerAction, on name: String) async throws {
        guard let index = list.firstIndex(where: { $0.name == name }) else { return }
        switch action {
        case .start, .restart:
            list[index].state = "running"
            list[index].status = "Up Less than a second"
        case .stop:
            list[index].state = "exited"
            list[index].status = "Exited (143) Less than a second ago"
        }
    }

    /// Lines in the formats real containers write, with Docker's timestamps.
    static func sampleLines(for name: String, now: Date) -> [String] {
        let texts: [String]
        switch name {
        case "uptime-kuma":
            texts = (0..<6).flatMap { minute in [
                "\u{1B}[36m2026-11-11T14:4\(minute):08-05:00\u{1B}[0m [\u{1B}[38;5;119mMONITOR\u{1B}[0m] \u{1B}[33mWARN:\u{1B}[0m Monitor #6 'qBittorrent': Failing: connect ECONNREFUSED 192.168.40.210:8090 | Interval: 60 seconds",
                "2026-11-11T14:4\(minute):10-05:00 [MONITOR] INFO: Monitor #2 'Plex': Successful Response: 31 ms | Interval: 60 seconds",
            ] } + [
                "2026-11-11T14:47:00-05:00 [MONITOR] ERROR: Monitor #9 'Prowlarr': Failing: timeout of 48000ms exceeded",
                "2026-11-11T14:47:30-05:00 [SERVER] INFO: Sending notification to Gotify for 'Prowlarr'",
            ]
        case "seerr":
            texts = [
                "2026-11-11T19:44:00.019Z [info][Server]: Server ready on port 5055",
                "2026-11-11T19:45:00.019Z [debug][Jobs]: Starting scheduled job: Download Sync",
                "2026-11-11T19:45:00.046Z [debug][Download Tracker]: Found 2 item(s) in progress on Radarr server: Radarr",
                "2026-11-11T19:45:30.112Z [warn][Plex Scan]: Library 'Anime' took 41 s to scan, longer than usual",
                "2026-11-11T19:46:00.011Z [debug][Jobs]: Starting scheduled job: Download Sync",
                "2026-11-11T19:46:00.031Z [debug][Download Tracker]: Found 2 item(s) in progress on Radarr server: Radarr",
                "2026-11-11T19:46:12.500Z [error][Sonarr API]: Request failed: connect ECONNREFUSED 192.168.40.200:8989",
                "2026-11-11T19:47:00.016Z [info][Notifications]: Sent 'Media Available' to Gotify",
            ]
        case "tautulli":
            texts = [
                "2026-11-11 17:00:36 - INFO :: Thread-21 (run) : Scheduled background task: Refresh libraries list",
                "2026-11-11 17:00:36 - INFO :: Thread-21 (run) : Scheduled background task: Check Tautulli Plex token",
                "2026-11-11 17:05:25 - ERROR :: CP Server Thread-13 : Failed to access uri endpoint /status/sessions. Connection error: RemoteDisconnected",
                "2026-11-11 17:05:25 - WARNING :: CP Server Thread-13 : Tautulli Pmsconnect :: Unable to parse XML for get_current_activity",
                "2026-11-11 17:05:25 - WARNING :: CP Server Thread-13 : Unable to retrieve data for get_activity.",
                "2026-11-11 17:06:25 - ERROR :: CP Server Thread-13 : Failed to access uri endpoint /status/sessions. Connection error: RemoteDisconnected",
            ]
        case "syncthing":
            texts = [
                "2026-11-11 14:34:58 INF Created or updated directory (folder.id=Documents dir.name=\"Obsidian Vault/Repair Guides\")",
                "2026-11-11 14:34:58 WRN Failed to sync (path=aria.png error=\"syncing: no connected device has the required version of this file\")",
                "2026-11-11 14:34:58 INF Folder failed to sync, will be retried (wait=1h4m0s folder.id=Documents)",
                "2026-11-11 14:35:21 INF Established secure connection (device=UD7DS6J connection.type=tcp-client)",
            ]
        case "mangosd":
            texts = [
                "Loading Creature Data...",
                ">> Loaded 41203 creatures",
                "Delete Gameobject (Entry: 35591 Counter: 5341827) that lost references to owner Player Grotul. Crash possible later.",
                "ERROR: Map::Update: Unit (GUID 18392) is in an invalid position",
                "Segmentation fault (core dumped)",
            ]
        default:
            texts = [
                "time=\"2026-11-11T13:54:27Z\" level=info msg=\"Starting\" version=1.8.2",
                "time=\"2026-11-11T13:54:28Z\" level=info msg=\"2700 decisions added\"",
                "time=\"2026-11-11T13:55:28Z\" level=warning msg=\"Machine 'unraid' last heartbeat was 61 s ago\"",
            ]
        }
        let start = now.addingTimeInterval(-Double(texts.count) * 37)
        return texts.enumerated().map { index, text in
            let date = start.addingTimeInterval(Double(index) * 37)
            return "\(Self.iso(date)) \(text)"
        }
    }

    static func iso(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.000000000Z", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }
}
