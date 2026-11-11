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

    public init(warnings: Int = 0, errors: Int = 0, latest: LogLine? = nil, capped: Bool = false) {
        self.warnings = warnings
        self.errors = errors
        self.latest = latest
        self.capped = capped
    }

    public var total: Int { warnings + errors }

    public static let maxLines = 1000
    public static let hours = 24

    /// One line "@@@ name" per container, then its candidate lines.
    public static let command = #"""
    for c in $(docker ps -a --format '{{.Names}}'); do echo "@@@ $c"; docker logs -t --since \#(hours)h "$c" 2>&1 | grep -aiE 'warn|wrn|err|fatal|ftl|crit|panic|alert|exception|traceback|HTTP/[0-9.]+" [45][0-9][0-9]' | tail -n \#(maxLines); done
    """#

    public static func parse(_ output: String) -> [String: ProblemSummary] {
        var result: [String: ProblemSummary] = [:]
        var current: String?
        var lines = 0
        func close() {
            if let current, lines >= maxLines { result[current]?.capped = true }
        }
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
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
            guard line.level.isProblem else { continue }
            if line.level >= .error { result[current]?.errors += 1 } else { result[current]?.warnings += 1 }
            result[current]?.latest = line
        }
        close()
        return result
    }
}
