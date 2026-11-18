import Foundation

/// Which images have a newer version, from Unraid's own update check
/// (/var/lib/docker/unraid-update-status.json). Nil on a server that isn't Unraid.
public struct ImageUpdates: Sendable, Equatable {
    /// Images with an update, as Unraid names them: "library/nginx:alpine".
    public var available: Set<String>
    /// When Unraid last wrote the file.
    public var checked: Date?

    public init(available: Set<String> = [], checked: Date? = nil) {
        self.available = available
        self.checked = checked
    }

    /// Lines for HostInfo.command: "@updates <the file on one line>" and "@updated <seconds since 1970>".
    static let command = #"""
    f=/var/lib/docker/unraid-update-status.json; [ -f $f ] && echo "@updated $(stat -c %Y $f)" && echo "@updates $(tr -d ' \n\t\r' < $f)"; true
    """#

    /// Unraid's file: `{"image:tag": {"local": …, "remote": …, "status": "true" | "false" | "undef"}}`.
    /// "false" means the local image is not the newest.
    static func parse(json: Substring, checked: Date?) -> ImageUpdates? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        var updates = ImageUpdates(checked: checked)
        for (image, value) in object {
            guard let entry = value as? [String: Any], entry["status"] as? String == "false" else { continue }
            updates.available.insert(normalized(image))
        }
        return updates
    }

    /// The image as Unraid's file names it: a tag always, "library/" for Docker Hub's
    /// own images, no "docker.io/". "nginx" is "library/nginx:latest".
    public static func normalized(_ image: String) -> String {
        var name = image
        for prefix in ["docker.io/", "index.docker.io/"] where name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
        if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
        let last = name.split(separator: "/").last ?? ""
        if !last.contains(":") { name += ":latest" }
        if !name.contains("/") { name = "library/" + name }
        return name
    }

    public func hasUpdate(_ image: String) -> Bool {
        available.contains(Self.normalized(image))
    }
}
