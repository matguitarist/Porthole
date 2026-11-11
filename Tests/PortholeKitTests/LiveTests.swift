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
}
