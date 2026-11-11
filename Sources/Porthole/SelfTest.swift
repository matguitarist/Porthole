import AppKit
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
            check("picks a running container first", model.selected?.isRunning == true)

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
