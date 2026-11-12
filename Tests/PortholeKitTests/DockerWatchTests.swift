import Foundation
import Testing
@testable import PortholeKit

@Suite("Docker itself")
struct DockerWatchTests {
    @Test("dockerd's CPU comes from its ticks between two readings")
    func dockerdCPU() {
        var load = HostLoad()
        load.read("@up 1000.00")
        load.read("@dockerd 100 5000 1000 90000")
        #expect(load.dockerdCPU.isEmpty)
        #expect(load.dockerdUptime == 100)   // 1000 s up, started at 900 s
        load.read("@up 1002.00")
        load.read("@dockerd 100 5800 1200 90000")   // 1000 ticks in 2 s: five cores
        #expect(load.dockerdCPU == [500])
        // A new dockerd starts over instead of reading a negative number.
        load.read("@up 1004.00")
        load.read("@dockerd 100 10 5 100300")
        #expect(load.dockerdCPU == [500])
        #expect(load.dockerdUptime == 1)
    }

    @Test("Busy means above 150% for five minutes, not a spike")
    func busy() {
        #expect(DockerdWatch.busy(Array(repeating: 500, count: 100)) == nil)
        #expect(DockerdWatch.busy(Array(repeating: 2, count: 140) + Array(repeating: 900, count: 10)) == nil)
        #expect(DockerdWatch.busy(Array(repeating: 507, count: 150)) == 507)
    }

    @Test("A die after a kill is a stop someone asked for; a die alone is a crash")
    func stopTracker() {
        let now = Date()
        var tracker = StopTracker()
        func problem(_ action: String, _ name: String, after seconds: TimeInterval, exit: Int? = nil) -> Bool {
            tracker.isProblem(DockerEvent(action: action, name: name, date: now.addingTimeInterval(seconds), exitCode: exit))
        }
        let kill = problem("kill", "app", after: 0)
        let stopped = problem("die", "app", after: 10, exit: 137)
        // The kill is used up: the next die is a crash.
        let crashed = problem("die", "app", after: 20, exit: 1)
        // A kill long before doesn't excuse a crash.
        let oldKill = problem("kill", "db", after: 0)
        let late = problem("die", "db", after: 300, exit: 139)
        #expect(!kill && !stopped && crashed && !oldKill && late)
    }

    @Test("Lines around Docker's restart don't count, the rest do")
    func restartNoise() {
        let started = Date(timeIntervalSince1970: 1_794_439_627)   // 2026-11-11T23:27:07Z
        let output = """
        @@started \(Int(started.timeIntervalSince1970))
        @@@ crowdsec-firewall-bouncer
        2026-11-11T22:00:00.000000000Z time="2026-11-11T22:00:00Z" level=warning msg="earlier"
        2026-11-11T23:27:08.000000000Z time="2026-11-11T23:27:08Z" level=error msg="error while removing rule"
        2026-11-11T23:24:13.000000000Z time="2026-11-11T23:24:13Z" level=error msg="Connection terminated"
        2026-11-11T23:40:00.000000000Z time="2026-11-11T23:40:00Z" level=error msg="real trouble"
        """
        #expect(ProblemSummary.dockerStarted(output) == started)
        let summary = ProblemSummary.parse(output)["crowdsec-firewall-bouncer"]
        #expect(summary?.errors == 1)
        #expect(summary?.warnings == 1)
        #expect(summary?.aroundRestart == 2)
        #expect(summary?.latest?.message.contains("real trouble") == true)
    }
}
