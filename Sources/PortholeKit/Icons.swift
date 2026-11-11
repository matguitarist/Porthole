import Foundation

/// Where a container's icon comes from.
public enum IconSource: Hashable, Sendable {
    case url(URL)
    /// A file on the server, read over SSH ("/boot/config/plugins/porthole/icons/azeroth.png").
    case serverFile(String)

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") { self = .serverFile(trimmed) }
        else if let url = URL(string: trimmed), url.scheme != nil { self = .url(url) }
        else { return nil }
    }
}

/// Icons and web pages for containers whose labels have none: from Unraid's
/// templates (the container was made before the template got an icon), then
/// from Porthole's own list on the server's flash drive,
/// /boot/config/plugins/porthole/icons.json:
///
///     { "containers": { "LocalProxy": "https://…/nginx.png" },
///       "prefixes":   { "azeroth-survivors-cmangos-": "/boot/config/plugins/porthole/icons/cmangos.png" } }
public struct ServerIcons: Sendable, Equatable {
    public static let listPath = "/boot/config/plugins/porthole/icons.json"

    public var templateIcons: [String: String] = [:]
    public var templateWebUIs: [String: String] = [:]
    public var containers: [String: String] = [:]
    public var prefixes: [String: String] = [:]

    public init() {}

    /// The shell command that prints the templates and the list (see `parse`).
    public static let command = #"""
    for f in /boot/config/plugins/dockerMan/templates-user/*.xml; do printf '%s\t%s\t%s\n' "$(grep -o '<Name>[^<]*' "$f" | head -1 | cut -c7-)" "$(grep -o '<Icon>[^<]*' "$f" | head -1 | cut -c7-)" "$(grep -o '<WebUI>[^<]*' "$f" | head -1 | cut -c8-)"; done 2>/dev/null; echo '@@porthole-icons'; cat /boot/config/plugins/porthole/icons.json 2>/dev/null
    """#

    /// Reads `command`'s output: "name<TAB>icon<TAB>webui" lines, a marker, then the JSON list.
    public static func parse(_ output: String) -> ServerIcons {
        var icons = ServerIcons()
        let parts = output.components(separatedBy: "@@porthole-icons")
        for line in parts[0].split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, !fields[0].isEmpty else { continue }
            if !fields[1].isEmpty { icons.templateIcons[fields[0]] = fields[1] }
            if fields.count > 2, !fields[2].isEmpty { icons.templateWebUIs[fields[0]] = fields[2] }
        }
        if parts.count > 1,
           let object = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any] {
            icons.containers = object["containers"] as? [String: String] ?? [:]
            icons.prefixes = object["prefixes"] as? [String: String] ?? [:]
        }
        return icons
    }

    /// The label first, then the template, then the list: an exact name, then the longest prefix.
    public func icon(for container: Container) -> IconSource? { icons(for: container).first }

    /// Every place an icon could come from, best first: a link can be dead
    /// (projects move their icons), so the app falls back to the next one.
    public func icons(for container: Container) -> [IconSource] {
        var texts = [container.labels["net.unraid.docker.icon"], templateIcons[container.name], containers[container.name]]
        if let prefix = prefixes.keys.filter({ container.name.hasPrefix($0) }).max(by: { $0.count < $1.count }) {
            texts.append(prefixes[prefix])
        }
        var sources: [IconSource] = []
        for case let text? in texts {
            if let source = IconSource(text), !sources.contains(source) { sources.append(source) }
        }
        return sources
    }

    /// The container's labels, plus the template's web page when the label has none.
    public func withTemplateWebUI(_ container: Container) -> Container {
        guard (container.labels["net.unraid.docker.webui"] ?? "").isEmpty, let web = templateWebUIs[container.name] else { return container }
        var copy = container
        copy.labels["net.unraid.docker.webui"] = web
        return copy
    }
}
