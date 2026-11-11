import Foundation
import LogKit

/// One line of `docker logs --timestamps`, read into what the viewer shows:
/// Docker's own time, a level found in the app's text, an optional source
/// ("Jobs", "MONITOR"), and the message without the app's repeated prefix.
public struct LogLine: Equatable, Sendable {
    public var date: Date?
    public var level: LogLevel
    public var code: String?
    public var source: String
    public var message: String
    /// Extra fields from a JSON line, one "key: value" per line.
    public var detail: String?

    public init(date: Date? = nil, level: LogLevel, code: String? = nil, source: String = "", message: String, detail: String? = nil) {
        self.date = date
        self.level = level
        self.code = code
        self.source = source
        self.message = message
        self.detail = detail
    }

    /// Between a container's name and its line in a stack's merged log.
    public static let mergedSeparator = "\u{1F}"

    /// Reads a raw line from `docker logs -t`: "2026-11-11T14:03:11.998185856Z <text>".
    public static func parse(_ raw: Substring) -> LogLine {
        var text = raw
        var date: Date?
        if let space = raw.firstIndex(of: " "), let parsed = DockerTime.parse(raw[..<space]) {
            date = parsed
            text = raw[raw.index(after: space)...]
        }
        var line = parseText(ANSI.strip(text))
        line.date = date
        return line
    }

    /// Reads the app's own text, after Docker's timestamp.
    public static func parseText(_ text: String) -> LogLine {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.first == "{", let line = json(trimmed) { return line }
        if let line = logfmt(trimmed) { return line }
        return words(trimmed)
    }

    // MARK: JSON ({"level":"info","message":"..."})

    static func json(_ text: String) -> LogLine? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        func string(_ keys: [String]) -> (key: String, value: String)? {
            for key in keys {
                if let value = object[key] { return (key, "\(value)") }
            }
            return nil
        }
        let levelField = string(["level", "lvl", "severity", "@l", "loglevel", "log.level"])
        let messageField = string(["message", "msg", "@m", "@mt", "text"])
        let sourceField = string(["logger", "module", "component", "name", "source"])
        guard levelField != nil || messageField != nil else { return nil }
        let level = levelField.flatMap { LogLevel(word: $0.value) } ?? .info
        let used: Set<String> = Set([levelField?.key, messageField?.key, sourceField?.key, "time", "timestamp", "ts", "@t"].compactMap { $0 })
        let extra = object.keys.filter { !used.contains($0) }.sorted().map { "\($0): \(object[$0].map { "\($0)" } ?? "")" }
        return LogLine(level: level, code: levelField.map { $0.value.uppercased() }, source: sourceField?.value ?? "",
                       message: messageField?.value ?? text, detail: extra.isEmpty ? nil : extra.joined(separator: "\n"))
    }

    // MARK: logfmt (time="..." level=info msg="..." key=value)

    static func logfmt(_ text: String) -> LogLine? {
        guard let levelRange = text.range(of: "level="),
              text.distance(from: text.startIndex, to: levelRange.lowerBound) < 80,
              levelRange.lowerBound == text.startIndex || text[text.index(before: levelRange.lowerBound)] == " "
        else { return nil }
        var fields: [(String, String)] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
            guard let equals = text[index...].firstIndex(of: "="),
                  !text[index..<equals].contains(" ") else { break }
            let key = String(text[index..<equals])
            var valueStart = text.index(after: equals)
            var value = ""
            if valueStart < text.endIndex, text[valueStart] == "\"" {
                valueStart = text.index(after: valueStart)
                var cursor = valueStart
                var escaped = false
                while cursor < text.endIndex {
                    let character = text[cursor]
                    if escaped { value.append(character); escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" { break }
                    else { value.append(character) }
                    cursor = text.index(after: cursor)
                }
                index = cursor < text.endIndex ? text.index(after: cursor) : cursor
            } else {
                let end = text[valueStart...].firstIndex(of: " ") ?? text.endIndex
                value = String(text[valueStart..<end])
                index = end
            }
            fields.append((key, value))
        }
        guard let levelWord = fields.first(where: { $0.0 == "level" })?.1 else { return nil }
        let message = fields.first(where: { $0.0 == "msg" || $0.0 == "message" })?.1 ?? ""
        let source = fields.first(where: { ["module", "component", "logger"].contains($0.0) })?.1 ?? ""
        let rest = fields.filter { !["time", "level", "msg", "message", "module", "component", "logger"].contains($0.0) }
            .map { "\($0.0)=\($0.1.contains(" ") ? "\"\($0.1)\"" : $0.1)" }
        let full = [message, rest.joined(separator: " ")].filter { !$0.isEmpty }.joined(separator: "  ")
        return LogLine(level: LogLevel(word: levelWord) ?? .info, code: levelWord.uppercased(), source: source, message: full)
    }

    // MARK: Plain text with a level word near the start

    /// Finds a level word among the first few words ("INF", "[Warning]",
    /// "ERROR ::", "WARN:"), drops the prefix before and including it, then a
    /// leading timestamp and a "[Source]" or "Source:" when there is one.
    static func words(_ text: String) -> LogLine {
        let utf8 = Array(text.utf8)
        var found: (level: LogLevel, code: String, end: Int, before: [String])?
        var words: [String] = []
        var index = 0
        var seen = 0
        while index < utf8.count, index < 120, seen < 5, found == nil {
            guard isLetter(utf8[index]) else { index += 1; continue }
            let start = index
            while index < utf8.count, isLetter(utf8[index]) { index += 1 }
            let word = String(decoding: utf8[start..<index], as: UTF8.self)
            let before = start == 0 ? UInt8(ascii: " ") : utf8[start - 1]
            let after = index < utf8.count ? utf8[index] : UInt8(ascii: " ")
            let digitNeighbor = isDigit(before) || isDigit(after)
            // Lone "T" and "Z" are the inside of an ISO timestamp, not words.
            if word.count > 1 || !digitNeighbor {
                seen += 1
                if !digitNeighbor, isOpener(before), isCloser(after), let level = LogLevel(word: word) {
                    found = (level, word, index, words)
                } else {
                    words.append(word)
                }
            }
        }
        var rest: Substring
        var level = LogLevel.info
        var code: String?
        var source = ""
        if let found {
            level = found.level
            code = found.code.uppercased()
            var end = found.end
            while end < utf8.count, ":]|)-\" ".utf8.contains(utf8[end]) { end += 1 }
            rest = Substring(String(decoding: utf8[end...], as: UTF8.self))
            // "[Kavita] [time] [Information]" or "[MONITOR] WARN:": the bracketed word before is the source.
            if let last = found.before.last, text.contains("[\(last)]"), found.before.count <= 2 { source = last }
        } else {
            rest = Substring(text)
            if let status = httpStatus(text) {
                level = status >= 500 ? .error : status >= 400 ? .warning : .info
            } else if text.hasPrefix("Traceback (most recent call last)") || text.hasPrefix("panic:") {
                level = text.hasPrefix("panic:") ? .critical : .error
            }
        }
        rest = dropTimestamp(rest)
        if let (bracketed, after) = leadingSource(rest) {
            source = bracketed
            rest = after
        }
        return LogLine(level: level, code: code, source: source, message: String(rest))
    }

    /// "2026-11-11 17:00:36 - ", "2026/11/11 13:54:50.597 ", "2026-11-11T14:46:00 - ".
    static func dropTimestamp(_ text: Substring) -> Substring {
        let utf8 = Array(text.utf8.prefix(40))
        guard utf8.count >= 10, utf8[0..<4].allSatisfy(isDigit), utf8[4] == UInt8(ascii: "-") || utf8[4] == UInt8(ascii: "/")
        else { return text }
        var end = 0
        while end < utf8.count, isDigit(utf8[end]) || "-/:.,TZ+ ".utf8.contains(utf8[end]) { end += 1 }
        var rest = text.dropFirst(end)
        if rest.hasPrefix("- ") { rest = rest.dropFirst(2) }
        return rest
    }

    /// "[Jobs]: Starting", "[Server] Serving", "ReleaseSearchService: Searching".
    static func leadingSource(_ text: Substring) -> (String, Substring)? {
        if text.first == "[", let close = text.firstIndex(of: "]") {
            let name = text[text.index(after: text.startIndex)..<close]
            guard !name.isEmpty, name.count <= 32, name.first?.isLetter == true,
                  name.allSatisfy({ $0.isLetter || $0.isNumber || " ._-".contains($0) }) else { return nil }
            var rest = text[text.index(after: close)...]
            while rest.first == ":" || rest.first == " " { rest = rest.dropFirst() }
            guard !rest.isEmpty else { return nil }
            return (String(name), rest)
        }
        if let colon = text.firstIndex(of: ":"), text[colon...].hasPrefix(": ") {
            let name = text[..<colon]
            guard name.count >= 3, name.count <= 48, name.first?.isUppercase == true,
                  name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." }),
                  name.contains(where: \.isLowercase) else { return nil }
            return (String(name), text[text.index(colon, offsetBy: 2)...])
        }
        return nil
    }

    /// The status of an access-log line: `"GET /health HTTP/1.1" 200 42`.
    static func httpStatus(_ text: String) -> Int? {
        guard let http = text.range(of: " HTTP/"),
              let quote = text[http.upperBound...].firstIndex(of: "\"") else { return nil }
        let after = text[text.index(after: quote)...].drop(while: { $0 == " " })
        let digits = after.prefix(3)
        guard digits.count == 3, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    private static func isLetter(_ byte: UInt8) -> Bool { (byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A }
    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
    private static func isOpener(_ byte: UInt8) -> Bool { " [(|\"<".utf8.contains(byte) }
    private static func isCloser(_ byte: UInt8) -> Bool { " ]):|\">,".utf8.contains(byte) }
}

extension LogLevel {
    /// The level words apps write, including short ones LogKit doesn't read
    /// on its own ("INF", "WRN", "Information", "Note").
    public init?(word: some StringProtocol) {
        switch word.lowercased() {
        case "trc", "trace", "verbose", "vrb": self = .trace
        case "dbg", "debug", "dbug": self = .debug
        case "inf", "info", "information", "informational", "notice", "note", "system": self = .info
        case "wrn", "warn", "warning": self = .warning
        case "err", "eror", "error": self = .error
        case "ftl", "fatal", "crit", "critical", "panic", "emerg", "emergency", "alert": self = .critical
        default: return nil
        }
    }
}

/// Docker's RFC 3339 times with nanoseconds, parsed by hand: a log has
/// thousands, and ISO8601DateFormatter is slow and not Sendable.
public enum DockerTime {
    public static func parse(_ text: some StringProtocol) -> Date? {
        let b = Array(text.utf8)
        guard b.count >= 20, b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54, b[13] == 0x3A, b[16] == 0x3A else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for i in range {
                guard b[i] >= 0x30, b[i] <= 0x39 else { return nil }
                value = value * 10 + Int(b[i] - 0x30)
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19) else { return nil }
        var index = 19
        var fraction = 0.0
        if index < b.count, b[index] == 0x2E {
            index += 1
            var scale = 0.1
            while index < b.count, b[index] >= 0x30, b[index] <= 0x39 {
                fraction += Double(b[index] - 0x30) * scale
                scale /= 10
                index += 1
            }
        }
        var offset = 0
        if index < b.count, b[index] == 0x2B || b[index] == 0x2D, index + 6 <= b.count,
           let hours = number(index + 1..<index + 3), let minutes = number(index + 4..<index + 6) {
            offset = (hours * 3600 + minutes * 60) * (b[index] == 0x2D ? -1 : 1)
        } else if index >= b.count || b[index] != 0x5A {
            return nil
        }
        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = Double(days * 86_400 + hour * 3600 + minute * 60 + second - offset) + fraction
        return Date(timeIntervalSince1970: seconds)
    }

    /// Days since 1970-01-01 (Howard Hinnant's algorithm).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// For `docker logs --since`: "2026-11-11T14:03:11.998185856Z" from a date.
    public static func string(_ date: Date) -> String {
        String(format: "%.9f", date.timeIntervalSince1970)
    }
}

/// Removes terminal color codes ("\u{1B}[33mWARN:\u{1B}[0m").
public enum ANSI {
    public static func strip(_ text: some StringProtocol) -> String {
        let utf8 = Array(text.utf8)
        guard utf8.contains(0x1B) else { return String(text) }
        var out: [UInt8] = []
        out.reserveCapacity(utf8.count)
        var index = 0
        while index < utf8.count {
            if utf8[index] == 0x1B {
                index += 1
                if index < utf8.count, utf8[index] == UInt8(ascii: "[") {
                    index += 1
                    while index < utf8.count, !(0x40...0x7E).contains(utf8[index]) { index += 1 }
                    index += 1
                } else {
                    index += 1
                }
            } else {
                out.append(utf8[index])
                index += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}
