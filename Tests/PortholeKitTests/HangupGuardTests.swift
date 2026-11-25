import Foundation
import ProcessKit
import Testing
@testable import PortholeKit

/// The guard runs as the server's shell would run it: `bash -c`, with stdin
/// the SSH channel. Here the channel is a pipe this test holds open and closes
/// by itself: ProcessKit closes a command's stdin only while it stops it, which
/// would test the signal, not the guard.
@Suite("Remote commands end with their channel")
struct HangupGuardTests {
    private func start(_ command: String) throws -> (Process, Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", SSHDocker.hangupGuard(command)]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return (process, stdin)
    }

    private func running(_ marker: String) -> Bool {
        (try? Shell.runSync("/usr/bin/pgrep", ["-f", marker]))?.succeeded == true
    }

    private func waitUntil(_ seconds: Double, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return done()
    }

    @Test("A command that writes nothing stops when the channel closes")
    func quietCommandStopsOnHangup() async throws {
        let marker = "3141.5926"   // a sleep no one else runs
        let (process, stdin) = try start("sleep \(marker) | cat")
        #expect(await waitUntil(3) { running(marker) })
        try stdin.fileHandleForWriting.close()
        #expect(await waitUntil(3) { !process.isRunning && !running(marker) })
    }

    @Test("A command that ends by itself ends the session with its status")
    func finishedCommandKeepsItsStatus() async throws {
        let (process, stdin) = try start("echo done; exit 3")
        #expect(await waitUntil(3) { !process.isRunning })
        #expect(process.terminationStatus == 3)
        try? stdin.fileHandleForWriting.close()
    }

    @Test("The command doesn't read the channel")
    func commandStdinIsNull() async throws {
        // `cat` with the channel as stdin would wait for it to close.
        let (process, stdin) = try start("cat")
        #expect(await waitUntil(3) { !process.isRunning })
        #expect(process.terminationStatus == 0)
        try? stdin.fileHandleForWriting.close()
    }
}

@Suite("SSH failures")
struct SSHFailureTests {
    @Test("A server that can't be reached fails with ssh's own words and status 255")
    func unreachable() async throws {
        // .invalid never resolves: ssh's -f master fails, and its error file is read.
        let docker = SSHDocker(target: "porthole-test.invalid")
        await #expect {
            _ = try await docker.containers()
        } throws: { error in
            guard case DockerError.command(let status, let message) = error else { return false }
            return status == 255 && message.contains("porthole-test.invalid")
        }
    }
}
