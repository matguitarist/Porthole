import Foundation
import ProcessKit
import Testing
@testable import PortholeKit

/// The guard runs as the server's shell would run it: `bash -c`, with stdin
/// the SSH channel. Here the channel is an open stdin that the test closes with
/// `closeInput()`, without stopping the command: a stop would test the signal,
/// not the guard.
@Suite("Remote commands end with their channel")
struct HangupGuardTests {
    private func start(_ command: String) throws -> Shell.RunningCommand {
        try Shell.start("/bin/bash", ["-c", SSHDocker.hangupGuard(command)],
                        options: Shell.Options(input: .open, stdout: .discard, stderr: .discard))
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
        let command = try start("sleep \(marker) | cat")
        defer { command.stop() }
        #expect(await waitUntil(3) { running(marker) })
        command.closeInput()
        #expect(await waitUntil(3) { !command.isRunning && !running(marker) })
        #expect(command.output?.cancelled != true)
    }

    @Test("A command that ends by itself ends the session with its status")
    func finishedCommandKeepsItsStatus() async throws {
        let command = try start("echo done; exit 3")
        defer { command.stop() }
        #expect(await waitUntil(3) { !command.isRunning })
        #expect(await command.wait().status == 3)
    }

    @Test("The command doesn't read the channel")
    func commandStdinIsNull() async throws {
        // `cat` with the channel as stdin would wait for it to close.
        let command = try start("cat")
        defer { command.stop() }
        #expect(await waitUntil(3) { !command.isRunning })
        #expect(await command.wait().status == 0)
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
