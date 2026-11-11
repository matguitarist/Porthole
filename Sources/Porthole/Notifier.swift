import Foundation
import PortholeKit
import Security
import UserNotifications

/// Tells you when something goes wrong: a container crashes, runs out of
/// memory, turns unhealthy or keeps restarting, or logs new errors. On this
/// Mac, and on your phone through Gotify (sent from the server, since Gotify
/// is on its network).
@Observable
final class Notifier {
    /// What a test run would have sent (test runs never send).
    private(set) var sent: [(title: String, body: String)] = []
    @ObservationIgnored private var lastSent: [String: Date] = [:]
    /// The same alert at most this often.
    static let quietTime: TimeInterval = 15 * 60

    enum Keys {
        static let crashes = "alerts.crashes"
        static let newErrors = "alerts.newErrors"
        static let gotify = "alerts.gotify"
        static let gotifyURL = "alerts.gotifyURL"
        static let defaultGotifyURL = "http://127.0.0.1:8070"
    }

    private var crashesOn: Bool { UserDefaults.standard.object(forKey: Keys.crashes) as? Bool ?? true }
    private var newErrorsOn: Bool { UserDefaults.standard.object(forKey: Keys.newErrors) as? Bool ?? true }

    func requestPermission() async {
        guard !Store.isOverridden else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// A container event: crashes, out of memory, unhealthy, a restart loop.
    func event(_ event: DockerEvent, recent: [DockerEvent]) {
        guard crashesOn else { return }
        if event.isProblem {
            let title = event.action == "health_status: unhealthy" ? "\(event.name) is unhealthy"
                : event.action == "oom" ? "\(event.name) ran out of memory"
                : "\(event.name) crashed"
            send(key: "\(event.name)|\(event.action)", title: title, body: event.summary, container: event.name)
        } else if event.action == "start" {
            let starts = recent.filter { $0.name == event.name && $0.action == "start" && $0.date > Date().addingTimeInterval(-600) }
            if starts.count >= 3 {
                send(key: "\(event.name)|loop", title: "\(event.name) keeps restarting",
                     body: "It started \(starts.count) times in 10 minutes.", container: event.name)
            }
        }
    }

    /// After a scan: containers with more errors than at the previous scan.
    func newErrors(_ now: [String: ProblemSummary], since previous: [String: ProblemSummary]) {
        guard newErrorsOn else { return }
        for (name, summary) in now {
            let added = summary.errors - (previous[name]?.errors ?? 0)
            guard added > 0 else { continue }
            send(key: "\(name)|errors", title: "\(name): \(added) new error\(added == 1 ? "" : "s")",
                 body: summary.latest?.message ?? "", container: name)
        }
    }

    private func send(key: String, title: String, body: String, container: String) {
        if let last = lastSent[key], Date().timeIntervalSince(last) < Self.quietTime { return }
        lastSent[key] = Date()
        sent.append((title, body))
        guard !Store.isOverridden else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(240))
        content.sound = .default
        content.userInfo = ["container": container]
        content.threadIdentifier = container
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))

        if UserDefaults.standard.bool(forKey: Keys.gotify), let token = Keychain.gotifyToken, !token.isEmpty,
           let ssh = AppModel.current?.client as? SSHDocker {
            let url = UserDefaults.standard.string(forKey: Keys.gotifyURL) ?? Keys.defaultGotifyURL
            Task { try? await ssh.gotify(url: url, token: token, title: title, message: body) }
        }
    }

    /// A test message, from Settings. Returns an error to show, or nil.
    func testGotify(url: String, token: String) async -> String? {
        guard let ssh = AppModel.current?.client as? SSHDocker else { return "Connect to the server first." }
        do {
            try await ssh.gotify(url: url, token: token, title: "Porthole", message: "Alerts from Porthole arrive here.")
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// The Gotify app token, kept in the login keychain.
enum Keychain {
    private static let service = "com.mathieuares.porthole.gotify"

    static var gotifyToken: String? {
        get {
            var item: CFTypeRef?
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecReturnData as String: true]
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        set {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            SecItemDelete(query as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var add = query
            add[kSecValueData as String] = Data(newValue.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
