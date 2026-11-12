import Foundation
import Testing
@testable import PortholeKit

/// Runs the clear command with fake `docker` and `truncate` that record each call.
@Suite("Clearing logs")
struct ClearCommandTests {
    /// `running`: containers that are running. `failStop`: a container whose stop fails.
    private func run(_ names: [String], running: Set<String>, failStop: String? = nil) throws -> (calls: [String], status: Int32) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("porthole-clear-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("calls").path
        for name in names { FileManager.default.createFile(atPath: dir.appendingPathComponent("\(name).log").path, contents: Data("x\n".utf8)) }
        let docker = """
        #!/bin/bash
        echo "docker $1 ${@: -1}" >> \(log)
        case "$1 $3" in
          "inspect {{.LogPath}}") echo "\(dir.path)/${@: -1}.log" ;;
          "inspect {{.State.Running}}") case " \(running.joined(separator: " ")) " in *" ${@: -1} "*) echo true ;; *) echo false ;; esac ;;
        esac
        [ "$1" = stop ] && [ "${@: -1}" = "\(failStop ?? "")" ] && exit 1
        exit 0
        """
        let truncate = "#!/bin/bash\necho \"truncate $(basename \"${@: -1}\" .log)\" >> \(log)\n"
        for (name, body) in [("docker", docker), ("truncate", truncate)] {
            let path = dir.appendingPathComponent(name).path
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", SSHDocker.clearCommand(names)]
        process.environment = ["PATH": "\(dir.path):/usr/bin:/bin"]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let calls = (try? String(contentsOfFile: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        return (calls.filter { !$0.hasPrefix("docker inspect") }, process.terminationStatus)
    }

    @Test("A running container stops, its log empties, then it starts again")
    func runningContainerRestarts() throws {
        let result = try run(["app", "db"], running: ["app"])
        #expect(result.calls == ["docker stop app", "truncate app", "docker start app", "truncate db"])
        #expect(result.status == 0)
    }

    @Test("A container that won't stop keeps its log, and the others still clear")
    func failedStopKeepsTheLog() throws {
        let result = try run(["app", "db"], running: ["app", "db"], failStop: "app")
        #expect(result.calls == ["docker stop app", "docker stop db", "truncate db", "docker start db"])
        #expect(result.status == 1)
    }
}
