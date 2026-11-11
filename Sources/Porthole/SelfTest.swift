import AppKit
import LogKit
import PortholeKit

/// Self-test for agents: runs the app's real functions on a test store,
/// prints PASS or FAIL per check, and quits with exit code 0 or 1.
///   APP_STORE=/tmp/Porthole-self.store ~/Applications/Porthole.app/Contents/MacOS/Porthole --selftest
/// (tools/selftest.sh does this.) Add a check for every story with logic.
@MainActor
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--selftest") }
    /// Read by AppDelegate.applicationWillTerminate.
    static var exitCode: Int32 = 0
    private static var failures = 0
    private static var count = 0

    static func runIfRequested(model: AppModel) {
        guard requested else { return }
        // Print each line at once, so a crash keeps the lines before it.
        setvbuf(stdout, nil, _IOLBF, 0)
        guard Store.isOverridden else {
            print("SELFTEST refused: set APP_STORE to a file in /tmp")
            finish(code: 1)
            return
        }
        Task {
            // ContentView connects on its own; wait for the sample containers.
            for _ in 0..<50 where model.connection != .connected { try? await Task.sleep(for: .milliseconds(100)) }
            check("connects and lists the sample containers", model.containers.count == 7, "\(model.containers.count)")
            check("opens on the overview", model.page == .overview)
            for _ in 0..<50 where model.problemsScanned == nil || model.hostLoad.cpu.isEmpty || model.hostInfo == nil { try? await Task.sleep(for: .milliseconds(100)) }
            check("the overview shows the server's load", !model.hostLoad.cpu.isEmpty && model.hostLoad.memoryTotal > 0)
            check("and its disks", model.hostInfo?.disks.count == 3)
            check("scans every container's log for problems", model.problems.count == 7)
            check("lists containers with errors first", model.containersWithProblems.first?.summary.errors ?? 0 > 0)
            check("lists containers that need a look", Set(model.containersNeedingAttention.map(\.name)) == ["tautulli", "mangosd"])
            model.open("tautulli", problemsOnly: true)
            check("a problem row opens the container's warnings and errors",
                  model.selection == "tautulli" && model.log(for: "tautulli").viewer.filter.levels == [.warning, .error, .critical])
            model.open("tautulli")
            check("a container row opens its whole log", model.log(for: "tautulli").viewer.filter.levels == model.log(for: "tautulli").viewer.defaultFilter.levels)
            model.page = .overview

            model.selection = "tautulli"
            let log = model.log(for: "tautulli")
            for _ in 0..<50 where log.store.entries.count < 6 || log.state == nil { try? await Task.sleep(for: .milliseconds(100)) }
            check("streams the container's log", log.store.entries.count == 6, "\(log.store.entries.count)")
            check("reads levels from the app's own words", log.store.entries.filter { $0.level == .error }.count == 2)
            check("an unhealthy container gets an insight", log.store.insights.contains { $0.id == ContainerInsights.healthID })
            check("so do three restarts in an hour", log.store.insights.contains { $0.id == ContainerInsights.restartID })

            model.selection = "mangosd"
            let crashed = model.log(for: "mangosd")
            for _ in 0..<50 where crashed.state == nil { try? await Task.sleep(for: .milliseconds(100)) }
            check("a crash gets an insight", crashed.store.insights.first?.title.hasPrefix("Stopped with exit code 139") == true)
            check("the log keeps following only the selected container", crashed.isFollowing && !log.isFollowing)
            check("a stopped container can start, not stop", model.canPerform(.start) && !model.canPerform(.stop))

            model.request(.start)
            for _ in 0..<50 where model.selected?.isRunning != true { try? await Task.sleep(for: .milliseconds(100)) }
            check("Start starts it", model.selected?.isRunning == true)

            model.request(.stop)
            check("Stop asks first", model.confirmStop == "mangosd" && model.selected?.isRunning == true)
            model.confirmStop = nil
            await model.perform(.stop, on: "mangosd")
            check("Stop stops it", model.selected?.isRunning == false)

            model.search = "taut"
            check("the filter narrows the list", model.shown.map(\.name) == ["tautulli"])
            model.search = ""

            for _ in 0..<50 where model.stats["seerr"] == nil { try? await Task.sleep(for: .milliseconds(100)) }
            check("usage arrives for running containers", (model.stats["seerr"]?.cpu.count ?? 0) > 0)
            check("the web page comes from Unraid's template",
                  model.webUI(for: model.containers.first { $0.name == "seerr" })?.absoluteString == "http://192.168.40.210:5055"
                  || model.webUI(for: model.containers.first { $0.name == "seerr" })?.port == 5055)

            // Stacks: a compose project's containers share one merged log.
            check("finds compose stacks", model.stacks["media"]?.map(\.name).sorted() == ["seerr", "tautulli"])
            model.page = .stack("media")
            let stack = model.stackLog("media")
            for _ in 0..<50 where Set(stack.store.entries.map(\.source)).count < 2 { try? await Task.sleep(for: .milliseconds(100)) }
            check("a stack's log merges its containers, with each line's container as source",
                  Set(stack.store.entries.map(\.source)) == ["seerr", "tautulli"])

            // Events from the last day, newest first.
            check("lists the last day's events, newest first",
                  model.recentEvents.count == 4 && model.recentEvents.first?.name == "tautulli" && model.recentEvents.first?.action == "start")

            // Ignore rules: known noise stops counting as a problem.
            model.page = .overview
            await model.scanProblems()
            let before = model.problems["uptime-kuma"]?.warnings ?? 0
            let rule = IgnoreRules.Rule(container: "uptime-kuma", text: "Monitor #6 'qBittorrent': Failing")
            model.ignore(rule)
            await model.scanProblems()
            check("an ignore rule stops counting its messages", before > 0 && (model.problems["uptime-kuma"]?.warnings ?? 0) < before,
                  "\(before) → \(model.problems["uptime-kuma"]?.warnings ?? -1)")
            model.removeIgnore(rule)
            await model.scanProblems()
            check("removing it counts them again", model.problems["uptime-kuma"]?.warnings == before)

            // Clearing logs asks first, then empties them on the server.
            model.requestClearLogs()
            check("Clear All Logs asks first", model.confirmClear?.names.count == model.containers.count)
            model.confirmClear = nil
            await model.clearLogs(["tautulli"])
            check("clearing a log removes its problems", model.problems["tautulli"]?.total == 0 && (model.problems["seerr"]?.total ?? 0) > 0)

            // Alerts: a crash notifies, the same one again stays quiet for a while.
            let sentBefore = model.notifier.sent.count
            model.notifier.event(DockerEvent(action: "die", name: "seerr", date: Date(), exitCode: 1), recent: [])
            model.notifier.event(DockerEvent(action: "die", name: "seerr", date: Date(), exitCode: 1), recent: [])
            check("a crash sends one alert, not two", model.notifier.sent.count == sentBefore + 1
                  && model.notifier.sent.last?.title == "seerr crashed")

            print(failures == 0 ? "SELFTEST PASS \(count) checks" : "SELFTEST FAIL \(failures) of \(count) checks")
            finish(code: failures == 0 ? 0 : 1)
        }
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        count += 1
        if !ok { failures += 1 }
        print(ok ? "PASS \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    /// Quits through NSApp.terminate, never exit(), and closes sheets first:
    /// an open sheet refuses terminate, and the run would wait forever.
    static func finish(code: Int32) {
        exitCode = code
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        NSApp.terminate(nil)
    }
}
