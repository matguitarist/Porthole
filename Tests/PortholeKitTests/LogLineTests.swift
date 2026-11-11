import Foundation
import LogKit
import Testing
@testable import PortholeKit

/// Lines from the containers on the home server.
@Suite("Reading log lines")
struct LogLineTests {
    func text(_ line: String) -> LogLine { LogLine.parseText(ANSI.strip(line)) }

    @Test("Docker's timestamp becomes the line's time")
    func dockerTime() {
        let line = LogLine.parse("2026-11-11T14:03:12.006986560Z [2026-11-11 09:03:12.006 INF] Now listening on: http://[::]:11011")
        #expect(line.date == Date(timeIntervalSince1970: 1_794_405_792.006_986_560))
        #expect(line.level == .info)
        #expect(line.message == "Now listening on: http://[::]:11011")
    }

    @Test("Docker times with an offset and without fractions")
    func times() {
        #expect(DockerTime.parse("1970-01-01T00:00:00Z") == Date(timeIntervalSince1970: 0))
        #expect(DockerTime.parse("1970-01-01T01:00:00+01:00") == Date(timeIntervalSince1970: 0))
        #expect(DockerTime.parse("hello") == nil)
    }

    @Test("Serilog short levels: INF, WRN")
    func serilog() {
        let line = text("[2026-11-11 09:03:11.998 WRN] Overriding address(es) 'http://*:11011'.")
        #expect(line.level == .warning)
        #expect(line.code == "WRN")
        #expect(line.message == "Overriding address(es) 'http://*:11011'.")
    }

    @Test("Audiobookshelf: INFO: [Server] message")
    func audiobookshelf() {
        let line = text("[2026-11-11 08:53:45.486] INFO: [Server] Serving from base path \"/audiobookshelf\"")
        #expect(line.level == .info)
        #expect(line.source == "Server")
        #expect(line.message == "Serving from base path \"/audiobookshelf\"")
    }

    @Test("Python: date - LEVEL :: thread : message")
    func tautulli() {
        let line = text("2026-11-11 17:05:25 - ERROR :: CP Server Thread-13 : Failed to access uri endpoint /status/sessions.")
        #expect(line.level == .error)
        #expect(line.message == "CP Server Thread-13 : Failed to access uri endpoint /status/sessions.")
        #expect(text("2026-11-11 17:05:25 - WARNING :: CP Server Thread-13 : Unable to retrieve data").level == .warning)
    }

    @Test("Level first, then a timestamp (Mealie, FlareSolverr)")
    func levelFirst() {
        let mealie = text("INFO     2026-11-11T14:46:00 - [::ffff:127.0.0.1:60770] 200 OK \"GET /api/app/about HTTP/1.1\"")
        #expect(mealie.level == .info)
        #expect(mealie.message == "[::ffff:127.0.0.1:60770] 200 OK \"GET /api/app/about HTTP/1.1\"")
        let flare = text("2026-11-11 18:15:18 INFO     Challenge solved!")
        #expect(flare.message == "Challenge solved!")
    }

    @Test("logfmt: level= and msg=, other fields kept")
    func logfmt() {
        let line = text("time=\"2026-11-11T13:54:27Z\" level=info msg=\"Creating turnstile widget\" account=homeserver zone=matshomeserver.com")
        #expect(line.level == .info)
        #expect(line.message == "Creating turnstile widget  account=homeserver zone=matshomeserver.com")
        let lapi = text("time=\"2026-11-11T19:47:25Z\" level=warning msg=\"172.17.0.1 - \\\"GET /v1/heartbeat\\\"\" module=lapi")
        #expect(lapi.level == .warning)
        #expect(lapi.source == "lapi")
        #expect(lapi.message == "172.17.0.1 - \"GET /v1/heartbeat\"")
    }

    @Test("JSON lines: level, message, and the other fields as details")
    func json() {
        let line = text("{\"level\":\"info\",\"version\":\"v11.4.2\",\"time\":\"2026-11-10T14:40:25-05:00\",\"message\":\"Accepting connections on :8080\"}")
        #expect(line.level == .info)
        #expect(line.message == "Accepting connections on :8080")
        #expect(line.detail == "version: v11.4.2")
        #expect(text("{\"level\":\"error\",\"msg\":\"boom\"}").level == .error)
    }

    @Test("Syncthing and Gotify: INF / WRN after the time")
    func goStyle() {
        let sync = text("2026-11-11 14:34:58 WRN Failed to sync (path=aria.png error=\"syncing: no connected device\")")
        #expect(sync.level == .warning)
        #expect(sync.message.hasPrefix("Failed to sync"))
        let gotify = text("2026-11-11T14:46:04-05:00 INF HTTP duration=\"550.216µs\" ip=192.168.40.215 method=GET path=/ status=200")
        #expect(gotify.level == .info)
        #expect(gotify.message.hasPrefix("HTTP duration"))
    }

    @Test("Uptime Kuma with colors: the bracketed part becomes the source")
    func uptimeKuma() {
        let line = text("\u{1B}[36m2026-11-11T14:42:08-05:00\u{1B}[0m [\u{1B}[38;5;119mMONITOR\u{1B}[0m] \u{1B}[33mWARN:\u{1B}[0m Monitor #6 'qBittorrent': Failing")
        #expect(line.level == .warning)
        #expect(line.source == "MONITOR")
        #expect(line.message == "Monitor #6 'qBittorrent': Failing")
    }

    @Test("Seerr: [debug][Jobs]: message")
    func seerr() {
        let line = text("2026-11-11T19:45:00.019Z [\u{1B}[34mdebug\u{1B}[39m][Jobs]: Starting scheduled job: Download Sync")
        #expect(line.level == .debug)
        #expect(line.source == "Jobs")
        #expect(line.message == "Starting scheduled job: Download Sync")
    }

    @Test("MySQL and MariaDB: [Warning], [Note], [System]")
    func mysql() {
        #expect(text("2026-11-04T18:59:54.374602Z 0 [Warning] [MY-011810] [Server] Insecure configuration").level == .warning)
        #expect(text("2026-11-01 21:53:57 0 [Note] InnoDB: Starting shutdown...").level == .info)
        #expect(text("2026-11-01 21:53:57 0 [ERROR] InnoDB: Cannot open").level == .error)
    }

    @Test("*arr apps: [Info] Service: message")
    func arr() {
        let line = text("[Info] ReleaseSearchService: Searching indexer(s): [1337x] for Term: []")
        #expect(line.level == .info)
        #expect(line.source == "ReleaseSearchService")
        #expect(line.message == "Searching indexer(s): [1337x] for Term: []")
        #expect(text("[Warn] RssSyncService: No indexers").level == .warning)
    }

    @Test("Kavita: [Kavita] [time] [Information] message")
    func kavita() {
        let line = text("[Kavita] [2026-11-11 14:46:04.452 -05:00  65] [Information] Serilog.AspNetCore.RequestLoggingMiddleware HTTP GET / responded 200")
        #expect(line.level == .info)
        #expect(line.message.hasPrefix("Serilog.AspNetCore"))
        #expect(text("[Kavita] [2026-11-11 14:46:04.452 -05:00  65] [Error] Boom").level == .error)
    }

    @Test("Access logs: 5xx is an error, 4xx a warning")
    func accessLog() {
        #expect(text("127.0.0.1 - - [11/Nov/2026:14:44:50 -0500] \"GET /health HTTP/1.1\" 200 42 \"-\" \"curl/8.22.0\"").level == .info)
        #expect(text("1.2.3.4 - - [11/Nov/2026:14:44:50 -0500] \"GET /x HTTP/1.1\" 502 0 \"-\" \"-\"").level == .error)
        #expect(text("1.2.3.4 - - [11/Nov/2026:14:44:50 -0500] \"GET /x HTTP/1.1\" 404 0 \"-\" \"-\"").level == .warning)
    }

    @Test("Plain text stays info; a message that mentions a level word later isn't changed")
    func plain() {
        #expect(text("Delete Gameobject (Entry: 35591) DBGuid: 5341827 that lost references. Crash possible later.").level == .info)
        #expect(text("Go to: http://127.0.0.1:8000/ to open SillyTavern").level == .info)
        #expect(text("Loaded the plugin list and we will now check for an error page").level == .info)
        #expect(text("Traceback (most recent call last):").level == .error)
    }

    @Test("iVentoy: slash dates and [PXE] as the source")
    func iventoy() {
        let line = text("2026/11/11 13:54:50.597 [PXE]  Module <OS> init OK ...")
        #expect(line.source == "PXE")
        #expect(line.message == "Module <OS> init OK ...")
    }

    @Test("Colors are removed")
    func ansi() {
        #expect(ANSI.strip("\u{1B}[38;5;39mhello\u{1B}[0m world") == "hello world")
        #expect(ANSI.strip("plain") == "plain")
    }
}

@Suite("Docker")
struct DockerTests {
    @Test("A container from docker ps, with Unraid's icon and web page")
    func container() throws {
        let line = #"{"Command":"x","HealthStatus":"none","ID":"517203e83d04","Image":"ghcr.io/cleanuparr/cleanuparr:latest","Labels":"net.unraid.docker.icon=https://example.com/512.png,net.unraid.docker.managed=dockerman,net.unraid.docker.webui=http://[IP]:[PORT:11011],a=b,c","Names":"cleanuparr","Ports":"0.0.0.0:11011->11011/tcp","State":"running","Status":"Up 6 hours"}"#
        let container = try #require(Container.parse(line))
        #expect(container.name == "cleanuparr")
        #expect(container.health == nil)
        #expect(container.isRunning)
        #expect(container.iconURL?.absoluteString == "https://example.com/512.png")
        #expect(container.webUI(host: "192.168.40.210")?.absoluteString == "http://192.168.40.210:11011")
        #expect(container.labels["a"] == "b,c")
    }

    @Test("A stopped container has no health, whatever Docker kept")
    func stoppedHealth() throws {
        let line = #"{"HealthStatus":"unhealthy","ID":"1","Image":"x","Labels":"","Names":"db","State":"exited","Status":"Exited (0) 9 days ago"}"#
        #expect(try #require(Container.parse(line)).health == nil)
    }

    @Test("Health from the status of older Docker")
    func health() {
        #expect(Container.health(fromStatus: "Up 2 hours (unhealthy)") == "unhealthy")
        #expect(Container.health(fromStatus: "Up 2 hours (health: starting)") == "starting")
        #expect(Container.health(fromStatus: "Up 2 hours") == nil)
    }

    @Test("Stats lines start with terminal codes")
    func stats() throws {
        let line = "\u{1B}[H\u{1B}[J" + #"{"BlockIO":"260MB / 9.87MB","CPUPerc":"12.50%","Container":"517203e83d04","ID":"517203e83d04","MemPerc":"1.2%","MemUsage":"512MiB / 31.2GiB","Name":"cleanuparr"}"# + "\u{1B}[K"
        let stats = try #require(ContainerStats.parse(line))
        #expect(stats.cpu == 12.5)
        #expect(stats.memoryBytes == 512 * 1_048_576)
        #expect(ContainerStats.bytes("1.5kB") == 1500)
    }

    @Test("History keeps the newest samples")
    func history() {
        var history = StatsHistory(capacity: 3)
        for index in 0..<5 { history.add(ContainerStats(id: "a", name: "a", cpu: Double(index), memoryBytes: 1, memoryLimitBytes: 2)) }
        #expect(history.cpu == [2, 3, 4])
    }

    @Test("State from docker inspect")
    func inspect() throws {
        let json = #"[{"RestartCount":2,"HostConfig":{"RestartPolicy":{"Name":"unless-stopped"}},"State":{"Status":"exited","Running":false,"OOMKilled":false,"ExitCode":137,"Error":"","StartedAt":"2026-11-11T14:03:08.454141077Z","FinishedAt":"2026-11-11T15:03:08Z","Health":{"Status":"unhealthy","FailingStreak":3,"Log":[{"ExitCode":1,"Output":"curl: (7) Failed to connect\n"}]}}}]"#
        let state = try #require(ContainerState.parse(inspect: json))
        #expect(state.exitCode == 137)
        #expect(state.restartCount == 2)
        #expect(state.restartPolicy == "unless-stopped")
        #expect(state.health == "unhealthy")
        #expect(state.lastHealthOutput == "curl: (7) Failed to connect")
        #expect(state.finishedAt != nil)
    }

    @Test("Events")
    func events() throws {
        let line = #"{"status":"die","id":"abc","Type":"container","Action":"die","Actor":{"ID":"abc","Attributes":{"exitCode":"0","name":"kometa"}},"time":1794405792,"timeNano":1794405792000000000}"#
        let event = try #require(DockerEvent.parse(line))
        #expect(event.action == "die")
        #expect(event.name == "kometa")
        #expect(event.changesList)
        #expect(DockerEvent.parse(#"{"Type":"network","Action":"connect"}"#) == nil)
    }
}

@Suite("Insights")
struct InsightTests {
    @Test("Out of memory, exit codes, health and restarts in plain words")
    func insights() {
        let now = Date(timeIntervalSince1970: 10_000)
        let oom = ContainerInsights.make(for: ContainerState(status: "exited", exitCode: 137, oomKilled: true), now: now)
        #expect(oom.map(\.id) == [ContainerInsights.oomID])

        let crashed = ContainerInsights.make(for: ContainerState(status: "exited", exitCode: 139, finishedAt: now.addingTimeInterval(-7200)), now: now)
        #expect(crashed.first?.title == "Stopped with exit code 139 2 h ago")
        #expect(crashed.first?.level == .critical)

        #expect(ContainerInsights.make(for: ContainerState(status: "exited", exitCode: 0)).isEmpty)
        #expect(ContainerInsights.make(for: ContainerState(status: "exited", exitCode: 143)).isEmpty)

        let sick = ContainerInsights.make(for: ContainerState(status: "running", health: "unhealthy", failingStreak: 4,
                                                              lastHealthOutput: "connection refused", startsLastHour: 5))
        #expect(sick.map(\.id) == [ContainerInsights.healthID, ContainerInsights.restartID])
        #expect(sick.first?.detail.contains("connection refused") == true)
        #expect(sick.last?.title == "Restarted 5 times in the last hour")
    }
}

@Suite("Line reader")
struct LineReaderTests {
    @Test("Lines arrive one by one, with CRLF and a last line without a newline")
    func lines() throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data("one\r\ntwo\nthr".utf8))
        pipe.fileHandleForWriting.write(Data("ee".utf8))
        try pipe.fileHandleForWriting.close()
        var lines: [String] = []
        LineReader.read(pipe.fileHandleForReading) { lines.append($0) }
        #expect(lines == ["one", "two", "three"])
    }
}

@Suite("Overview")
struct OverviewTests {
    @Test("Host info from the server")
    func hostInfo() {
        let info = HostInfo.parse("@host HomeServer\n@cores 8\n@version 7.3.4\n@disk /mnt/user 2000 500\n@disk /mnt/cache 100 75\n@disk /mnt/cache 100 75\n")
        #expect(info.hostname == "HomeServer")
        #expect(info.subtitle == "Unraid 7.3.4 · 8 cores")
        #expect(info.disks.map(\.title) == ["Array", "Cache"])
        #expect(info.disks[1].fraction == 0.75)
    }

    @Test("CPU from the change between two readings, memory used from available")
    func load() {
        var load = HostLoad()
        load.read("@cpu cpu 100 0 100 800 0 0 0 0 0 0")
        #expect(load.cpu.isEmpty)
        load.read("@cpu cpu 150 0 150 900 0 0 0 0 0 0")   // busy +100 of total +200
        #expect(load.cpu == [50])
        load.read("@mem 1000 250")
        #expect(load.memoryTotal == 1_024_000)
        #expect(load.memoryUsed == [768_000])
        load.read("@load 0.52 0.61 0.70 1/800 1234")
        #expect(load.load == [0.52, 0.61, 0.70])
        load.read("@up 3600.5 7000")
        #expect(load.uptime == 3600.5)
    }

    @Test("Problems per container, confirmed by the level detection")
    func problems() {
        let output = """
        @@@ tautulli
        2026-11-11T17:05:25.397643210Z 2026-11-11 17:05:25 - ERROR :: CP Server : Failed to access uri
        2026-11-11T17:05:25.398025610Z 2026-11-11 17:05:25 - WARNING :: CP Server : Unable to parse XML
        2026-11-11T17:06:25.398025610Z 2026-11-11 17:06:25 - INFO :: Thread : No errors found
        @@@ quiet
        """
        let summary = ProblemSummary.parse(output)
        #expect(summary["tautulli"]?.errors == 1)
        #expect(summary["tautulli"]?.warnings == 1)
        #expect(summary["tautulli"]?.latest?.message.hasPrefix("CP Server : Unable") == true)
        #expect(summary["quiet"] == ProblemSummary())
    }

    @Test("Icons: label, then template, then Porthole's list by name and longest prefix")
    func icons() {
        let output = "crowdsec\thttps://x/crowdsec.png\thttp://[IP]:[PORT:8080]\nempty\t\t\n@@porthole-icons\n"
            + #"{"containers":{"LocalProxy":"https://x/nginx.png"},"prefixes":{"azeroth-":"/boot/a.png","azeroth-survivors-cmangos-":"/boot/c.png"}}"#
        let icons = ServerIcons.parse(output)
        func icon(_ name: String, labels: [String: String] = [:]) -> IconSource? {
            icons.icon(for: Container(id: name, name: name, image: "", state: "running", status: "", labels: labels))
        }
        #expect(icon("x", labels: ["net.unraid.docker.icon": "https://x/label.png"]) == .url(URL(string: "https://x/label.png")!))
        #expect(icon("crowdsec") == .url(URL(string: "https://x/crowdsec.png")!))
        #expect(icon("LocalProxy") == .url(URL(string: "https://x/nginx.png")!))
        #expect(icon("azeroth-survivors-cmangos-mangosd-1") == .serverFile("/boot/c.png"))
        #expect(icon("azeroth-other") == .serverFile("/boot/a.png"))
        #expect(icon("nothing") == nil)
        let both = Container(id: "c", name: "crowdsec", image: "", state: "running", status: "", labels: ["net.unraid.docker.icon": "https://x/dead.png"])
        #expect(icons.icons(for: both) == [.url(URL(string: "https://x/dead.png")!), .url(URL(string: "https://x/crowdsec.png")!)])
        let web = icons.withTemplateWebUI(Container(id: "c", name: "crowdsec", image: "", state: "running", status: ""))
        #expect(web.webUI(host: "h")?.absoluteString == "http://h:8080")
    }
}
