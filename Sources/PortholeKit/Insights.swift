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
            insights.append(LogInsight(id: loopID, level: .critical, title: String(localized: "Keeps restarting", bundle: .main),
                                       detail: String(localized: "Docker restarts it each time it stops (\(state.restartCount) restarts so far). The messages just before each start usually say why.", bundle: .main)))
        }
        if state.oomKilled {
            insights.append(LogInsight(id: oomID, level: .critical, title: String(localized: "Killed for running out of memory", bundle: .main),
                                       detail: String(localized: "The container used more memory than it's allowed. Raise its memory limit or find what grows.", bundle: .main)))
        }
        if state.status == "exited" || state.status == "dead", !state.oomKilled, let meaning = exitMeaning(state.exitCode) {
            let when = state.finishedAt.map { " " + relative($0, now: now) } ?? ""
            insights.append(LogInsight(id: exitID, level: meaning.level,
                                       title: String(localized: "Stopped with exit code \(state.exitCode)\(when)", bundle: .main),
                                       detail: state.error.isEmpty ? meaning.text : String(localized: "\(meaning.text) Docker says: \(state.error)", bundle: .main)))
        }
        if state.health == "unhealthy" {
            var detail = state.failingStreak == 1 ? String(localized: "It failed the last health check.", bundle: .main) : String(localized: "It failed the last \(state.failingStreak) health checks in a row.", bundle: .main)
            if let output = state.lastHealthOutput, !output.isEmpty { detail += " " + String(localized: "Last check: \(String(output.prefix(300)))", bundle: .main) }
            insights.append(LogInsight(id: healthID, level: .error, title: String(localized: "Unhealthy", bundle: .main), detail: detail))
        }
        if state.startsLastHour >= 3, state.status != "restarting" {
            insights.append(LogInsight(id: restartID, level: .warning,
                                       title: String(localized: "Restarted \(state.startsLastHour) times in the last hour", bundle: .main),
                                       detail: String(localized: "Something keeps stopping it. Look at the messages just before each start.", bundle: .main)))
        }
        return insights
    }

    /// What an exit code usually means, or nil for a normal stop.
    public static func exitMeaning(_ code: Int) -> (level: LogLevel, text: String)? {
        switch code {
        case 0: return nil
        case 143: return nil   // SIGTERM: docker stop
        case 137: return (.error, String(localized: "It was killed (SIGKILL): docker stop timed out, or the system ran out of memory.", bundle: .main))
        case 139: return (.critical, String(localized: "It crashed (segmentation fault).", bundle: .main))
        case 134: return (.critical, String(localized: "It aborted (SIGABRT), usually after a failed check in its own code.", bundle: .main))
        case 126: return (.error, String(localized: "Its command couldn't run: it isn't executable.", bundle: .main))
        case 127: return (.error, String(localized: "Its command wasn't found in the image.", bundle: .main))
        case 125: return (.error, String(localized: "Docker couldn't start it (a bad option or setting).", bundle: .main))
        case 1: return (.error, String(localized: "The app stopped with an error. Its last messages say why.", bundle: .main))
        default: return (.error, String(localized: "The app stopped with an error. Its last messages say why.", bundle: .main))
        }
    }

    static func relative(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return String(localized: "just now", bundle: .main)
        case ..<3600: return String(localized: "\(seconds / 60) min ago", bundle: .main)
        case ..<86_400: return String(localized: "\(seconds / 3600) h ago", bundle: .main)
        default: return String(localized: "\(seconds / 86_400) days ago", bundle: .main)
        }
    }
}
