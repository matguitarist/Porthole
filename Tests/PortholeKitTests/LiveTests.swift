import Foundation
import Testing
@testable import PortholeKit

/// Against the real server: PORTHOLE_LIVE=1 swift test --filter Live
@Suite("Live", .enabled(if: ProcessInfo.processInfo.environment["PORTHOLE_LIVE"] == "1"))
struct LiveTests {
    @Test("Stats lines from the server parse")
    func stats() async throws {
        let docker = SSHDocker(target: "root@192.168.40.210", identityFile: "~/.ssh/id_ed25519_homeserver")
        var lines: [String] = []
        for try await line in docker.stats() {
            lines.append(line)
            if lines.count >= 5 { break }
        }
        for line in lines { print("RAW", line.debugDescription.prefix(120), "->", ContainerStats.parse(line).map { "\($0.name) \($0.cpu)" } ?? "nil") }
        #expect(lines.compactMap(ContainerStats.parse).count == lines.count)
    }

    @Test("Cancelling a log stream ends `docker logs -f` on the server")
    func cancelledStreamLeavesNothingBehind() async throws {
        let docker = SSHDocker(target: "root@192.168.40.210", identityFile: "~/.ssh/id_ed25519_homeserver")
        // A start in 2100: nothing else follows from there, and nothing arrives.
        let since = Date(timeIntervalSince1970: 4_102_444_800)
        let count = "pgrep -fc '[d]ocker logs -f -t --since \(DockerTime.string(since))' || true"
        let task = Task { for try await _ in docker.logs(["porthole-agent"], tail: 0, since: since) {} }
        try await Task.sleep(for: .seconds(3))
        #expect(try await docker.command(count).trimmingCharacters(in: .whitespacesAndNewlines) != "0")
        task.cancel()
        try await Task.sleep(for: .seconds(2))
        #expect(try await docker.command(count).trimmingCharacters(in: .whitespacesAndNewlines) == "0")
    }
}
