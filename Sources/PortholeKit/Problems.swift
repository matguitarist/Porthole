import Foundation
import LogKit

/// Warnings and errors per container over the last day, for the overview.
/// The server sends only lines that might be problems (a cheap grep), and
/// Porthole's own level detection decides.
public struct ProblemSummary: Sendable, Equatable {
    public var warnings = 0
    public var errors = 0
    /// The newest problem line.
    public var latest: LogLine?
    /// True when the server sent the most lines it sends, so there may be more.
    public var capped = false
    /// Warnings and errors logged around Docker's last restart: not counted above.
    public var aroundRestart = 0

    public init(warnings: Int = 0, errors: Int = 0, latest: LogLine? = nil, capped: Bool = false) {
        self.warnings = warnings
        self.errors = errors
        self.latest = latest
        self.capped = capped
    }

    public var total: Int { warnings + errors }

    public static let maxLines = 1000
    public static let hours = 24

    /// When Docker restarted, every container logs its shutdown and startup:
    /// lines from this long before dockerd started…
    public static let beforeRestart: TimeInterval = 5 * 60
    /// …to this long after are noise, not problems.
    public static let afterRestart: TimeInterval = 3 * 60

    /// The span around a Docker start whose lines don't count.
    public static func restartWindow(_ started: Date) -> ClosedRange<Date> {
        started.addingTimeInterval(-beforeRestart)...started.addingTimeInterval(afterRestart)
    }

    /// First "@@started <unix seconds>", when dockerd started; then one line
    /// "@@@ name" per container, then its candidate lines.
    public static let command = #"""
    p=$(pidof dockerd | cut -d' ' -f1); [ -n "$p" ] && echo "@@started $(( $(date +%s) - $(awk -v t=$(getconf CLK_TCK) -v s=$(cut -d' ' -f22 /proc/$p/stat) '{print int($1 - s / t)}' /proc/uptime) ))"
    for c in $(docker ps -a --format '{{.Names}}'); do echo "@@@ $c"; docker logs -t --since \#(hours)h "$c" 2>&1 | grep -aiE 'warn|wrn|err|fatal|ftl|crit|panic|alert|exception|traceback|HTTP/[0-9.]+" [45][0-9][0-9]' | tail -n \#(maxLines); done
    """#

    /// When dockerd started, from the scan's first line.
    public static func dockerStarted(_ output: String) -> Date? {
        guard output.hasPrefix("@@started "), let line = output.split(separator: "\n").first,
              let seconds = TimeInterval(line.dropFirst(10)) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    public static func parse(_ output: String, ignoring rules: IgnoreRules = IgnoreRules()) -> [String: ProblemSummary] {
        let restart = dockerStarted(output).map(restartWindow)
        var result: [String: ProblemSummary] = [:]
        var current: String?
        var lines = 0
        func close() {
            if let current, lines >= maxLines { result[current]?.capped = true }
        }
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if raw.hasPrefix("@@started ") { continue }
            if raw.hasPrefix("@@@ ") {
                close()
                let name = String(raw.dropFirst(4))
                current = name
                lines = 0
                result[name] = ProblemSummary()
                continue
            }
            guard let current else { continue }
            lines += 1
            let line = LogLine.parse(raw)
            guard line.level.isProblem, !rules.ignores(line.message, in: current) else { continue }
            if let restart, let date = line.date, restart.contains(date) {
                result[current]?.aroundRestart += 1
                continue
            }
            if line.level >= .error { result[current]?.errors += 1 } else { result[current]?.warnings += 1 }
            result[current]?.latest = line
        }
        close()
        return result
    }
}
