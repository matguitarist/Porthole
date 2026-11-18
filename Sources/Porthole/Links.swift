import AppKit

/// Where the Help menu's links go.
enum Links {
    static let repository = URL(string: "https://github.com/matguitarist/Porthole")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// This version's release page, with its notes.
    static var releaseNotes: URL { repository.appending(path: "releases/tag/v\(version)") }

    /// Unraid's Main page: the array and its disks.
    static var unraidMain: URL { URL(string: "http://\(ServerSettings.host)/Main") ?? repository }

    /// Unraid's Docker page, where an image update is applied.
    static var unraidDocker: URL { URL(string: "http://\(ServerSettings.host)/Docker") ?? repository }

    /// A new issue, with the version and macOS filled in.
    static var newIssue: URL {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var components = URLComponents(url: repository.appending(path: "issues/new"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "body", value: "\n\n---\nPorthole \(version), macOS \(os)")]
        return components.url!
    }
}
