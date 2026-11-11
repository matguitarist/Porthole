import Darwin
import Foundation

/// Starts a command the way Terminal does: the child disclaims Porthole as
/// its responsible process. macOS then judges ssh's network access on its
/// own, so Local Network privacy (tied to each build of the app) never
/// blocks it, and a rebuild doesn't need permission again.
enum Spawn {
    enum Output {
        case pipe
        case null
        /// stderr only: the same pipe as stdout.
        case merged
        case file(String)
    }

    struct Child {
        let pid: pid_t
        let stdout: FileHandle?
        let stderr: FileHandle?
    }

    private typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private static let disclaim: Disclaim? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return nil }
        return unsafeBitCast(symbol, to: Disclaim.self)
    }()

    static func launch(_ path: String, _ arguments: [String], stdout: Output, stderr: Output) throws -> Child {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the descriptors set up below reach the child.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        _ = disclaim?(&attributes, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)

        var outPipe: Pipe?
        var errPipe: Pipe?
        switch stdout {
        case .pipe, .merged:
            let pipe = Pipe()
            outPipe = pipe
            posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForWriting.fileDescriptor, 1)
        case .null:
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        case .file(let path):
            posix_spawn_file_actions_addopen(&actions, 1, path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        }
        switch stderr {
        case .pipe:
            let pipe = Pipe()
            errPipe = pipe
            posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForWriting.fileDescriptor, 2)
        case .merged:
            if let outPipe { posix_spawn_file_actions_adddup2(&actions, outPipe.fileHandleForWriting.fileDescriptor, 2) }
        case .null:
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        case .file(let path):
            posix_spawn_file_actions_addopen(&actions, 2, path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        }

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
        // The child has its own copies; the write ends must close here, or reads never end.
        try? outPipe?.fileHandleForWriting.close()
        try? errPipe?.fileHandleForWriting.close()
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL) }
        return Child(pid: pid, stdout: outPipe?.fileHandleForReading, stderr: errPipe?.fileHandleForReading)
    }

    /// Waits for the child (blocking) and returns its exit code, or 128 + the signal that ended it.
    static func wait(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }
}
