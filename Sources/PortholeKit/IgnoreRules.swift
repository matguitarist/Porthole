import Foundation

/// Messages someone marked as known noise ("Monitor #6 'qBittorrent': Failing").
/// They no longer count as problems: the overview and notifications skip
/// them, and the log shows them dimmed as Debug, with their own level word.
public struct IgnoreRules: Codable, Sendable, Equatable {
    public struct Rule: Codable, Sendable, Hashable, Identifiable {
        /// The container, or nil for every container.
        public var container: String?
        /// Text the message contains, case and spacing as typed; matching ignores case.
        public var text: String
        public var id: String { "\(container ?? "*")|\(text)" }

        public init(container: String?, text: String) {
            self.container = container
            self.text = text
        }
    }

    public var rules: [Rule] = []

    public init(rules: [Rule] = []) { self.rules = rules }

    public func ignores(_ message: String, in container: String) -> Bool {
        rules.contains { rule in
            (rule.container == nil || rule.container == container)
                && !rule.text.isEmpty && message.range(of: rule.text, options: .caseInsensitive) != nil
        }
    }

    /// A rule's text from a message: its start, before the parts that change
    /// (numbers, quotes, ids), so the same message with other values matches too.
    public static func suggestedText(for message: String) -> String {
        var text = ""
        for character in message {
            if character.isNumber || character == "'" || character == "\"" || character == "(" || character == "[" { break }
            text.append(character)
        }
        text = text.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        return text.count >= 8 ? text : String(message.prefix(80))
    }
}
