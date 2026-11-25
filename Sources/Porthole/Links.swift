import AppKit

/// Unraid's pages (the Help menu's links are in UI/AppCommands.swift).
enum Links {
    static let repository = URL(string: "https://github.com/matguitarist/Porthole")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Unraid's Main page: the array and its disks.
    static var unraidMain: URL { URL(string: "http://\(ServerSettings.host)/Main") ?? repository }

    /// Unraid's Docker page, where an image update is applied.
    static var unraidDocker: URL { URL(string: "http://\(ServerSettings.host)/Docker") ?? repository }
}
