import Foundation

public enum ContainerAction: String, Sendable, CaseIterable {
    case start, stop, restart
}

public enum DockerError: LocalizedError, Equatable {
    case command(status: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .command(let status, let message):
            let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if status == 255 {
                if text.contains("No route to host") {
                    return text + "\n\nIf the server is on your network, allow Porthole in System Settings > Privacy & Security > Local Network, then try again."
                }
                return text.isEmpty ? "Couldn't connect over SSH." : text
            }
            return text.isEmpty ? "The command failed (exit code \(status))." : text
        }
    }
}

/// What the app needs from Docker. `SSHDocker` talks to a server;
/// `DemoDocker` serves sample data for snapshots and the self-test.
public protocol DockerClient: Sendable {
    func containers() async throws -> [Container]
    func inspect(_ name: String) async throws -> ContainerState
    /// Raw `docker logs -f -t` lines, the last `tail`, or those after `since`.
    /// With several containers (a compose stack), each line starts with the
    /// container's name and `LogLine.mergedSeparator`.
    func logs(_ names: [String], tail: Int, since: Date?) -> AsyncThrowingStream<String, Error>
    /// Empties the containers' log files on the server. Can't be undone.
    func clearLogs(_ names: [String]) async throws
    /// Notable events of the last `hours` (starts, crashes, health).
    func recentEvents(hours: Int) async throws -> [DockerEvent]
    /// Raw `docker events` JSON lines for containers.
    func events() -> AsyncThrowingStream<String, Error>
    /// Raw `docker stats` JSON lines, a round for all running containers every two seconds.
    func stats() -> AsyncThrowingStream<String, Error>
    func perform(_ action: ContainerAction, on name: String) async throws
    /// Icons from Unraid's templates and Porthole's list on the server.
    func serverIcons() async throws -> ServerIcons
    /// A file on the server (an icon).
    func serverFile(_ path: String) async throws -> Data
    func hostInfo() async throws -> HostInfo
    /// HostLoad lines every two seconds.
    func hostLoad() -> AsyncThrowingStream<String, Error>
    /// Warnings and errors per container over the last day, without ignored messages.
    func problems(ignoring rules: IgnoreRules) async throws -> [String: ProblemSummary]
}

/// Docker on another machine, through the `docker` command over SSH. All
/// commands share one SSH connection (a ControlMaster), so a new stream
/// costs no new login.
public actor SSHDocker: DockerClient {
    public nonisolated let target: String
    public nonisolated let identityFile: String?
    private var masterReady = false

    /// - Parameters:
    ///   - target: "root@192.168.40.210" or a Host from ~/.ssh/config.
    ///   - identityFile: a private key, or nil for ssh's own choice.
    public init(target: String, identityFile: String? = nil) {
        self.target = target
        let key = identityFile?.trimmingCharacters(in: .whitespaces) ?? ""
        self.identityFile = key.isEmpty ? nil : (key as NSString).expandingTildeInPath
    }

    /// Short, so it stays under the 104-byte socket path limit.
    private nonisolated var controlPath: String { "/tmp/porthole-\(getuid())-%C" }

    nonisolated func sshArguments(_ remote: String? = nil, extra: [String] = []) -> [String] {
        var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=15",
                    "-o", "ServerAliveCountMax=3", "-o", "ControlPath=\(controlPath)"]
        if let identityFile { args += ["-i", identityFile, "-o", "IdentitiesOnly=yes"] }
        args += extra
        args.append(target)
        if let remote { args.append(remote) }
        return args
    }

    /// Opens the shared connection when it isn't open yet.
    func ensureMaster() async throws {
        if masterReady, (try? await Self.run(sshArguments(extra: ["-O", "check"]))) != nil { return }
        masterReady = false
        if (try? await Self.run(sshArguments(extra: ["-O", "check"]))) == nil {
            _ = try await Self.run(sshArguments(extra: ["-f", "-N", "-o", "ControlMaster=yes", "-o", "ControlPersist=600"]),
                                   background: true)
        }
        masterReady = true
    }

    /// Closes the shared connection at once, ending every stream through it.
    /// For quitting: started commands would otherwise outlive the app.
    public nonisolated func disconnectNow() {
        guard let child = try? Spawn.launch("/usr/bin/ssh", sshArguments(extra: ["-O", "exit"]), stdout: .null, stderr: .null) else { return }
        _ = Spawn.wait(child.pid)
    }

    /// Closes the shared connection (on quit, or when the address changes).
    public func disconnect() async {
        _ = try? await Self.run(sshArguments(extra: ["-O", "exit"]))
        masterReady = false
    }

    func command(_ remote: String) async throws -> String {
        try await ensureMaster()
        do {
            return try await Self.run(sshArguments(remote))
        } catch DockerError.command(status: 255, _) {
            // The shared connection went away (sleep, network change): once more with a new one.
            masterReady = false
            try await ensureMaster()
            return try await Self.run(sshArguments(remote))
        }
    }

    public func containers() async throws -> [Container] {
        try await command("docker ps -a --no-trunc --format '{{json .}}'")
            .split(separator: "\n").compactMap(Container.parse)
    }

    public func inspect(_ name: String) async throws -> ContainerState {
        let quoted = Self.quote(name)
        let since = Int(Date().timeIntervalSince1970) - 3600
        let output = try await command("docker inspect \(quoted); echo '--porthole--'; docker events --since \(since) --until \(since + 3600) --filter container=\(quoted) --filter event=start --format x | wc -l")
        let parts = output.components(separatedBy: "--porthole--")
        guard var state = ContainerState.parse(inspect: parts[0]) else {
            throw DockerError.command(status: 1, message: "Docker has no container named \(name).")
        }
        state.startsLastHour = Int(parts.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        return state
    }

    public nonisolated func logs(_ names: [String], tail: Int, since: Date?) -> AsyncThrowingStream<String, Error> {
        let from = since.map { "--since \(DockerTime.string($0))" } ?? "--tail \(tail)"
        if names.count == 1 {
            return stream("docker logs -f -t \(from) \(Self.quote(names[0])) 2>&1")
        }
        return stream(Self.mergedCommand(names, from: from))
    }

    /// One SSH channel for a whole stack, each line prefixed with its container's
    /// name. The earlier lines come first, merged in time order (Docker's
    /// timestamps sort as text); then every container follows from the moment
    /// the command started. The few lines in both are dropped by date on this side.
    static func mergedCommand(_ names: [String], from: String) -> String {
        func prefixed(_ name: String, _ logs: String, unbuffered: Bool) -> String {
            "docker logs -t \(logs) \(quote(name)) 2>&1 | sed \(unbuffered ? "-u " : "")\"s/^/\(name)\\x1f/\""
        }
        let history = names.map { prefixed($0, from, unbuffered: false) }.joined(separator: "; ")
        let follow = names.map { "(\(prefixed($0, "-f --since $t", unbuffered: true))) &" }.joined(separator: " ")
        return "t=$(date +%s); { \(history); } | sort -s -t \"$(printf '\\037')\" -k2,2; \(follow) wait"
    }

    /// Sends a Gotify message from the server (Gotify is on its network).
    /// `url` as the server sees it: "http://127.0.0.1:8070".
    public func gotify(url: String, token: String, title: String, message: String, priority: Int = 6) async throws {
        let endpoint = url.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/message"
        _ = try await command("curl -fsS -m 10 -X POST \(Self.quote(endpoint)) -H \(Self.quote("X-Gotify-Key: " + token)) --form-string \(Self.quote("title=" + title)) --form-string \(Self.quote("message=" + message)) -F priority=\(priority) >/dev/null")
    }

    public func clearLogs(_ names: [String]) async throws {
        _ = try await command(Self.clearCommand(names))
    }

    /// Empties each container's log file. A running container stops first and
    /// starts again after: on Docker 29, emptying the file under a running
    /// container breaks `docker logs --tail` for it until it restarts, and
    /// every such read hangs and spins dockerd. One container at a time, so
    /// each is down only for its own stop and start.
    static func clearCommand(_ names: [String]) -> String {
        let quoted = names.map(quote).joined(separator: " ")
        return "s=0; for c in \(quoted); do "
            + "f=$(docker inspect -f '{{.LogPath}}' \"$c\") && [ -f \"$f\" ] || continue; "
            + "if [ \"$(docker inspect -f '{{.State.Running}}' \"$c\")\" = true ]; then "
            + "docker stop \"$c\" >/dev/null && truncate -s 0 \"$f\" && docker start \"$c\" >/dev/null; "
            + "else truncate -s 0 \"$f\"; fi "
            + "|| { echo \"Couldn't clear $c.\" >&2; s=1; }; done; exit $s"
    }

    public func recentEvents(hours: Int) async throws -> [DockerEvent] {
        let now = Int(Date().timeIntervalSince1970)
        let output = try await command("docker events --since \(now - hours * 3600) --until \(now) --filter type=container --format '{{json .}}'")
        return output.split(separator: "\n").compactMap(DockerEvent.parse).filter(\.isNotable)
    }

    public nonisolated func events() -> AsyncThrowingStream<String, Error> {
        stream("docker events --filter type=container --format '{{json .}}'")
    }

    public nonisolated func stats() -> AsyncThrowingStream<String, Error> {
        stream("docker stats --format '{{json .}}'")
    }

    public func perform(_ action: ContainerAction, on name: String) async throws {
        _ = try await command("docker \(action.rawValue) \(Self.quote(name))")
    }

    public func serverIcons() async throws -> ServerIcons {
        ServerIcons.parse(try await command(ServerIcons.command))
    }

    public func serverFile(_ path: String) async throws -> Data {
        let text = try await command("base64 < \(Self.quote(path))")
        guard let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else {
            throw DockerError.command(status: 1, message: "Couldn't read \(path).")
        }
        return data
    }

    public func hostInfo() async throws -> HostInfo {
        HostInfo.parse(try await command(HostInfo.command))
    }

    public nonisolated func hostLoad() -> AsyncThrowingStream<String, Error> {
        stream(HostLoad.command)
    }

    public func problems(ignoring rules: IgnoreRules) async throws -> [String: ProblemSummary] {
        let output = try await command(ProblemSummary.command)
        return await Task.detached { ProblemSummary.parse(output, ignoring: rules) }.value
    }

    /// Runs `command` on the server so that it ends when the SSH channel closes.
    /// Without a terminal, a remote command that writes nothing (`docker logs -f`
    /// on a quiet container) never notices that ssh went away and runs forever,
    /// and dockerd keeps following its log. Here the command runs in its own
    /// process group with stdin from /dev/null; a watcher reads the channel's
    /// stdin, which this side holds open, and kills the group at end of file.
    /// When the command ends first, the watcher goes too.
    static func hangupGuard(_ command: String) -> String {
        "set -m; { \(command); } </dev/null & p=$!; { cat >/dev/null; kill -TERM -- -$p; } >/dev/null 2>&1 & w=$!; "
            + "wait $p; s=$?; kill -- -$w 2>/dev/null; exit $s"
    }

    /// A long-running remote command, line by line. Cancelling the stream ends the
    /// command, here and on the server (see `hangupGuard`).
    nonisolated func stream(_ remote: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let box = ProcessBox()
            let task = Task.detached {
                do {
                    try await self.ensureMaster()
                    let child = try Spawn.launch("/usr/bin/ssh", self.sshArguments(Self.hangupGuard(remote)),
                                                 stdout: .pipe, stderr: .merged, keepStdinOpen: true)
                    guard box.set(child.pid, stdin: child.stdin), let out = child.stdout else { return }
                    // A thread of its own that hands over each line as soon as it
                    // arrives (FileHandle.bytes waits for a big chunk first).
                    let status = await withCheckedContinuation { (done: CheckedContinuation<Int32, Never>) in
                        Thread.detachNewThread {
                            LineReader.read(out) { continuation.yield($0) }
                            done.resume(returning: Spawn.wait(child.pid))
                        }
                    }
                    box.finished()
                    if Task.isCancelled || status == 0 || status > 128 {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: DockerError.command(status: status, message: ""))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                box.cancel()
            }
        }
    }

    /// Runs ssh and returns its output; throws with its error text when it fails.
    /// With `background`, ssh forks a master that keeps its output open, so
    /// its errors go to a file instead of a pipe that would never close.
    static func run(_ arguments: [String], background: Bool = false) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let errorFile = FileManager.default.temporaryDirectory.appending(path: "porthole-ssh-\(UUID().uuidString).txt")
                let child: Spawn.Child
                do {
                    child = try Spawn.launch("/usr/bin/ssh", arguments,
                                             stdout: background ? .null : .pipe,
                                             stderr: background ? .file(errorFile.path(percentEncoded: false)) : .pipe)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                var output = Data(), errors = Data()
                if let out = child.stdout, let err = child.stderr {
                    let group = DispatchGroup()
                    let errorBox = DataBox()
                    group.enter()
                    DispatchQueue.global().async {
                        errorBox.data = err.readDataToEndOfFile()
                        group.leave()
                    }
                    output = out.readDataToEndOfFile()
                    group.wait()
                    errors = errorBox.data
                }
                let status = Spawn.wait(child.pid)
                if background {
                    errors = (try? Data(contentsOf: errorFile)) ?? Data()
                    try? FileManager.default.removeItem(at: errorFile)
                }
                if status == 0 {
                    continuation.resume(returning: String(decoding: output, as: UTF8.self))
                } else {
                    continuation.resume(throwing: DockerError.command(status: status, message: String(decoding: errors, as: UTF8.self)))
                }
            }
        }
    }

    /// Single quotes for the remote shell.
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// The ssh process behind a stream, so cancelling can stop it.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?
    private var stdin: FileHandle?
    private var cancelled = false

    /// False when the stream was already cancelled; the process is stopped.
    func set(_ pid: pid_t, stdin: FileHandle? = nil) -> Bool {
        lock.withLock {
            if cancelled {
                try? stdin?.close()
                kill(pid, SIGTERM)
                return false
            }
            self.pid = pid
            self.stdin = stdin
            return true
        }
    }

    /// The process was reaped: its pid may belong to another process now.
    func finished() {
        lock.withLock {
            pid = nil
            try? stdin?.close()
            stdin = nil
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            // End of file first, so the server's side ends even if the signal races.
            try? stdin?.close()
            stdin = nil
            if let pid { kill(pid, SIGTERM) }
        }
    }
}

/// Splits a pipe's output into lines as it arrives, with CRLF endings.
enum LineReader {
    static func read(_ handle: FileHandle, line: (String) -> Void) {
        var buffer = Data()
        while true {
            let chunk = handle.availableData   // blocks until something arrives; empty at the end
            if chunk.isEmpty { break }
            buffer.append(chunk)
            var start = buffer.startIndex
            while let newline = buffer[start...].firstIndex(of: 0x0A) {
                var end = newline
                if end > start, buffer[buffer.index(before: end)] == 0x0D { end = buffer.index(before: end) }
                line(String(decoding: buffer[start..<end], as: UTF8.self))
                start = buffer.index(after: newline)
            }
            buffer.removeSubrange(buffer.startIndex..<start)
        }
        if !buffer.isEmpty { line(String(decoding: buffer, as: UTF8.self)) }
    }
}
