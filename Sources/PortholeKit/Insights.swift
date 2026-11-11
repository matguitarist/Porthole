import Foundation
import LogKit

/// Findings about a container in plain words, shown above its log.
public enum ContainerInsights {
    public static let restartID = "restarts"
    public static let healthID = "health"
    public static let exitID = "exit"
    public static let oomID = "oom"
    public static let loopID = "restarting"

    public static func make(for state: ContainerState, now: Date = Date()) -> [LogInsight] {
        var insights: [LogInsight] = []
        if state.status == "restarting" {
            insights.append(LogInsight(id: loopID, level: .critical, title: "Keeps restarting",
                                       detail: "Docker restarts it each time it stops (\(state.restartCount) restarts so far). The messages just before each start usually say why."))
        }
        if state.oomKilled {
            insights.append(LogInsight(id: oomID, level: .critical, title: "Killed for running out of memory",
                                       detail: "The container used more memory than it's allowed. Raise its memory limit or find what grows."))
        }
        if state.status == "exited" || state.status == "dead", !state.oomKilled, let meaning = exitMeaning(state.exitCode) {
            let when = state.finishedAt.map { " " + relative($0, now: now) } ?? ""
            insights.append(LogInsight(id: exitID, level: meaning.level,
                                       title: "Stopped with exit code \(state.exitCode)\(when)",
                                       detail: state.error.isEmpty ? meaning.text : "\(meaning.text) Docker says: \(state.error)"))
        }
        if state.health == "unhealthy" {
            let checks = state.failingStreak == 1 ? "1 health check" : "\(state.failingStreak) health checks"
            var detail = "It failed the last \(checks) in a row."
            if let output = state.lastHealthOutput, !output.isEmpty { detail += " Last check: \(output.prefix(300))" }
            insights.append(LogInsight(id: healthID, level: .error, title: "Unhealthy", detail: detail))
        }
        if state.startsLastHour >= 3, state.status != "restarting" {
            insights.append(LogInsight(id: restartID, level: .warning,
                                       title: "Restarted \(state.startsLastHour) times in the last hour",
                                       detail: "Something keeps stopping it. Look at the messages just before each start."))
        }
        return insights
    }

    /// What an exit code usually means, or nil for a normal stop.
    public static func exitMeaning(_ code: Int) -> (level: LogLevel, text: String)? {
        switch code {
        case 0: return nil
        case 143: return nil   // SIGTERM: docker stop
        case 137: return (.error, "It was killed (SIGKILL): docker stop timed out, or the system ran out of memory.")
        case 139: return (.critical, "It crashed (segmentation fault).")
        case 134: return (.critical, "It aborted (SIGABRT), usually after a failed check in its own code.")
        case 126: return (.error, "Its command couldn't run: it isn't executable.")
        case 127: return (.error, "Its command wasn't found in the image.")
        case 125: return (.error, "Docker couldn't start it (a bad option or setting).")
        case 1: return (.error, "The app stopped with an error. Its last messages say why.")
        default: return (.error, "The app stopped with an error. Its last messages say why.")
        }
    }

    static func relative(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86_400: return "\(seconds / 3600) h ago"
        default: return "\(seconds / 86_400) days ago"
        }
    }
}
