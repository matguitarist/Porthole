//! Reads a log line the way the Mac app does (PortholeKit/LogLine.swift):
//! Docker's timestamp, then the level from JSON, logfmt, or a level word near
//! the start ("INF", "[Warning]", "ERROR ::"), an access log's HTTP status,
//! or a traceback. Keep the two in step.

use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    Trace,
    Debug,
    Info,
    Warning,
    Error,
    Critical,
}

impl Level {
    pub fn from_word(word: &str) -> Option<Level> {
        Some(match word.to_ascii_lowercase().as_str() {
            "trc" | "trace" | "verbose" | "vrb" => Level::Trace,
            "dbg" | "debug" | "dbug" => Level::Debug,
            "inf" | "info" | "information" | "informational" | "notice" | "note" | "system" => {
                Level::Info
            }
            "wrn" | "warn" | "warning" => Level::Warning,
            "err" | "eror" | "error" => Level::Error,
            "ftl" | "fatal" | "crit" | "critical" | "panic" | "emerg" | "emergency" | "alert" => {
                Level::Critical
            }
            _ => return None,
        })
    }

    pub fn is_problem(self) -> bool {
        self >= Level::Warning
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Line {
    /// Docker's timestamp, as written ("2026-11-11T14:03:11.998185856Z").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub time: Option<String>,
    pub level: Level,
    /// The log's own level word, upper-cased ("WRN").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub source: String,
    pub message: String,
}

/// A raw `docker logs -t` line: "<timestamp> <text>".
pub fn parse(raw: &str) -> Line {
    let raw = raw.trim_end_matches(['\n', '\r']);
    let (time, text) = match raw.split_once(' ') {
        Some((stamp, rest)) if is_docker_time(stamp) => (Some(stamp.to_string()), rest),
        _ => (None, raw),
    };
    let mut line = parse_text(&strip_ansi(text));
    line.time = time;
    line
}

pub fn parse_text(text: &str) -> Line {
    let trimmed = text.trim_matches(' ');
    if trimmed.starts_with('{')
        && let Some(line) = json(trimmed)
    {
        return line;
    }
    if let Some(line) = logfmt(trimmed) {
        return line;
    }
    words(trimmed)
}

fn is_docker_time(text: &str) -> bool {
    let b = text.as_bytes();
    b.len() >= 20
        && b[4] == b'-'
        && b[7] == b'-'
        && b[10] == b'T'
        && b[..4].iter().all(u8::is_ascii_digit)
}

/// Drops terminal colors ("\x1b[33mWARN\x1b[0m").
pub fn strip_ansi(text: &str) -> String {
    if !text.contains('\u{1b}') {
        return text.to_string();
    }
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            if chars.peek() == Some(&'[') {
                chars.next();
                for c in chars.by_ref() {
                    if c.is_ascii_alphabetic() {
                        break;
                    }
                }
            }
        } else {
            out.push(c);
        }
    }
    out
}

// JSON ({"level":"info","message":"..."})

fn json(text: &str) -> Option<Line> {
    let object: serde_json::Map<String, serde_json::Value> = serde_json::from_str(text).ok()?;
    let field = |keys: &[&str]| -> Option<(String, String)> {
        keys.iter().find_map(|k| {
            object.get(*k).map(|v| {
                (
                    k.to_string(),
                    v.as_str()
                        .map(str::to_string)
                        .unwrap_or_else(|| v.to_string()),
                )
            })
        })
    };
    let level_field = field(&["level", "lvl", "severity", "@l", "loglevel", "log.level"]);
    let message_field = field(&["message", "msg", "@m", "@mt", "text"]);
    let source_field = field(&["logger", "module", "component", "name", "source"]);
    if level_field.is_none() && message_field.is_none() {
        return None;
    }
    let level = level_field
        .as_ref()
        .and_then(|(_, v)| Level::from_word(v))
        .unwrap_or(Level::Info);
    Some(Line {
        time: None,
        level,
        code: level_field.map(|(_, v)| v.to_uppercase()),
        source: source_field.map(|(_, v)| v).unwrap_or_default(),
        message: message_field
            .map(|(_, v)| v)
            .unwrap_or_else(|| text.to_string()),
    })
}

// logfmt (time="..." level=info msg="..." key=value)

fn logfmt(text: &str) -> Option<Line> {
    let at = text.find("level=")?;
    if at >= 80 || (at > 0 && text.as_bytes()[at - 1] != b' ') {
        return None;
    }
    let mut fields: Vec<(String, String)> = Vec::new();
    let mut rest = text;
    loop {
        rest = rest.trim_start_matches(' ');
        let Some(eq) = rest.find('=') else { break };
        let key = &rest[..eq];
        if key.is_empty() || key.contains(' ') {
            break;
        }
        let after = &rest[eq + 1..];
        let (value, next) = if let Some(quoted) = after.strip_prefix('"') {
            let mut value = String::new();
            let mut escaped = false;
            let mut end = quoted.len();
            for (i, c) in quoted.char_indices() {
                if escaped {
                    value.push(c);
                    escaped = false;
                } else if c == '\\' {
                    escaped = true;
                } else if c == '"' {
                    end = i + 1;
                    break;
                } else {
                    value.push(c);
                }
            }
            (value, &quoted[end.min(quoted.len())..])
        } else {
            let end = after.find(' ').unwrap_or(after.len());
            (after[..end].to_string(), &after[end..])
        };
        fields.push((key.to_string(), value));
        rest = next;
        if rest.is_empty() {
            break;
        }
    }
    let get = |names: &[&str]| {
        fields
            .iter()
            .find(|(k, _)| names.contains(&k.as_str()))
            .map(|(_, v)| v.clone())
    };
    let level_word = get(&["level"])?;
    let message = get(&["msg", "message"]).unwrap_or_default();
    let source = get(&["module", "component", "logger"]).unwrap_or_default();
    let others: Vec<String> = fields
        .iter()
        .filter(|(k, _)| {
            ![
                "time",
                "level",
                "msg",
                "message",
                "module",
                "component",
                "logger",
            ]
            .contains(&k.as_str())
        })
        .map(|(k, v)| {
            if v.contains(' ') {
                format!("{k}=\"{v}\"")
            } else {
                format!("{k}={v}")
            }
        })
        .collect();
    let full = [message, others.join(" ")]
        .into_iter()
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("  ");
    Some(Line {
        time: None,
        level: Level::from_word(&level_word).unwrap_or(Level::Info),
        code: Some(level_word.to_uppercase()),
        source,
        message: full,
    })
}

// Plain text with a level word near the start

fn is_letter(b: u8) -> bool {
    b.is_ascii_alphabetic()
}
fn is_opener(b: u8) -> bool {
    b" [(|\"<".contains(&b)
}
fn is_closer(b: u8) -> bool {
    b" ]):|\">,".contains(&b)
}

fn words(text: &str) -> Line {
    let bytes = text.as_bytes();
    let mut found: Option<(Level, String, usize, Vec<String>)> = None;
    let mut before_words: Vec<String> = Vec::new();
    let (mut i, mut seen) = (0, 0);
    while i < bytes.len() && i < 120 && seen < 5 && found.is_none() {
        if !is_letter(bytes[i]) {
            i += 1;
            continue;
        }
        let start = i;
        while i < bytes.len() && is_letter(bytes[i]) {
            i += 1;
        }
        let word = &text[start..i];
        let before = if start == 0 { b' ' } else { bytes[start - 1] };
        let after = if i < bytes.len() { bytes[i] } else { b' ' };
        let digit_neighbor = before.is_ascii_digit() || after.is_ascii_digit();
        // Lone "T" and "Z" are the inside of an ISO timestamp, not words.
        if word.len() > 1 || !digit_neighbor {
            seen += 1;
            match Level::from_word(word) {
                Some(level) if !digit_neighbor && is_opener(before) && is_closer(after) => {
                    found = Some((level, word.to_string(), i, before_words.clone()));
                }
                _ => before_words.push(word.to_string()),
            }
        }
    }
    let (mut level, mut code, mut source) = (Level::Info, None, String::new());
    let mut rest: &str = text;
    if let Some((found_level, word, end, before)) = found {
        level = found_level;
        code = Some(word.to_uppercase());
        let mut end = end;
        while end < bytes.len() && b":]|)-\" ".contains(&bytes[end]) {
            end += 1;
        }
        rest = &text[end..];
        if let Some(last) = before.last()
            && before.len() <= 2
            && text.contains(&format!("[{last}]"))
        {
            source = last.clone();
        }
    } else if let Some(status) = http_status(text) {
        level = if status >= 500 {
            Level::Error
        } else if status >= 400 {
            Level::Warning
        } else {
            Level::Info
        };
    } else if text.starts_with("Traceback (most recent call last)") {
        level = Level::Error;
    } else if text.starts_with("panic:") {
        level = Level::Critical;
    }
    let mut rest = drop_timestamp(rest);
    if let Some((name, after)) = leading_source(rest) {
        source = name;
        rest = after;
    }
    Line {
        time: None,
        level,
        code,
        source,
        message: rest.to_string(),
    }
}

/// "2026-11-11 17:00:36 - ", "2026/11/11 13:54:50.597 ".
fn drop_timestamp(text: &str) -> &str {
    let b = text.as_bytes();
    if b.len() < 10 || !b[..4].iter().all(u8::is_ascii_digit) || !(b[4] == b'-' || b[4] == b'/') {
        return text;
    }
    let mut end = 0;
    while end < b.len().min(40) && (b[end].is_ascii_digit() || b"-/:.,TZ+ ".contains(&b[end])) {
        end += 1;
    }
    let rest = &text[end..];
    rest.strip_prefix("- ").unwrap_or(rest)
}

/// "[Jobs]: Starting", "ReleaseSearchService: Searching".
fn leading_source(text: &str) -> Option<(String, &str)> {
    if let Some(inner) = text.strip_prefix('[') {
        let close = inner.find(']')?;
        let name = &inner[..close];
        let ok = !name.is_empty()
            && name.chars().count() <= 32
            && name.chars().next().is_some_and(char::is_alphabetic)
            && name
                .chars()
                .all(|c| c.is_alphanumeric() || " ._-".contains(c));
        if !ok {
            return None;
        }
        let rest = inner[close + 1..].trim_start_matches([':', ' ']);
        return (!rest.is_empty()).then(|| (name.to_string(), rest));
    }
    let colon = text.find(": ")?;
    let name = &text[..colon];
    let n = name.chars().count();
    let ok = (3..=48).contains(&n)
        && name.chars().next().is_some_and(char::is_uppercase)
        && name.chars().all(|c| c.is_alphanumeric() || c == '.')
        && name.chars().any(char::is_lowercase);
    ok.then(|| (name.to_string(), &text[colon + 2..]))
}

/// The status of an access-log line: `"GET /health HTTP/1.1" 200 42`.
fn http_status(text: &str) -> Option<u16> {
    let http = text.find(" HTTP/")?;
    let quote = text[http + 6..].find('"')? + http + 6;
    let after = text[quote + 1..].trim_start_matches(' ');
    let digits = after.get(..3)?;
    digits
        .bytes()
        .all(|b| b.is_ascii_digit())
        .then(|| digits.parse().ok())
        .flatten()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn docker_time_and_level_word() {
        let line = parse(
            "2026-11-11T21:16:47.444240750Z 2026-11-11 16:16:47 INF Connection closed (device=UD7DS6J)",
        );
        assert_eq!(line.time.as_deref(), Some("2026-11-11T21:16:47.444240750Z"));
        assert_eq!(line.level, Level::Info);
        assert_eq!(line.code.as_deref(), Some("INF"));
        assert_eq!(line.message, "Connection closed (device=UD7DS6J)");
    }

    #[test]
    fn syncthing_warning() {
        let line = parse_text("2026-11-11 16:18:27 WRN Failed to sync (path=aria.png)");
        assert_eq!(line.level, Level::Warning);
        assert_eq!(line.message, "Failed to sync (path=aria.png)");
    }

    #[test]
    fn colored_uptime_kuma_with_bracketed_source() {
        let raw = "2026-11-11T21:16:08.760206778Z \u{1b}[36m2026-11-11T16:16:08-05:00\u{1b}[0m [\u{1b}[38;5;119mMONITOR\u{1b}[0m] \u{1b}[33mWARN:\u{1b}[0m Monitor #6 'qBittorrent': Failing";
        let line = parse(raw);
        assert_eq!(line.level, Level::Warning);
        assert_eq!(line.source, "MONITOR");
        assert_eq!(line.message, "Monitor #6 'qBittorrent': Failing");
    }

    #[test]
    fn arr_apps_and_dotnet_words() {
        let line = parse_text("[Info] RssSyncService: Starting RSS Sync");
        assert_eq!(line.level, Level::Info);
        assert_eq!(line.source, "RssSyncService");
        assert_eq!(line.message, "Starting RSS Sync");
        let line = parse_text(
            "[Kavita] [2026-11-11 10:00:00.000 -05:00  1] [Warning] Kavita.Server: Slow query",
        );
        assert_eq!(line.level, Level::Warning);
    }

    #[test]
    fn json_lines() {
        let line = parse_text(r#"{"level":"error","msg":"db down","logger":"api","retry":3}"#);
        assert_eq!(line.level, Level::Error);
        assert_eq!(line.source, "api");
        assert_eq!(line.message, "db down");
    }

    #[test]
    fn logfmt_lines() {
        let line = parse_text(
            r#"time="2026-11-11T16:00:00Z" level=warning msg="disk almost full" free=2GB"#,
        );
        assert_eq!(line.level, Level::Warning);
        assert_eq!(line.message, "disk almost full  free=2GB");
    }

    #[test]
    fn access_logs_traceback_and_panic() {
        assert_eq!(
            parse_text(r#"10.0.0.1 - - "GET /api HTTP/1.1" 502 12"#).level,
            Level::Error
        );
        assert_eq!(
            parse_text(r#"10.0.0.1 - - "GET /x HTTP/1.1" 404 12"#).level,
            Level::Warning
        );
        assert_eq!(
            parse_text(r#"10.0.0.1 - - "GET / HTTP/1.1" 200 12"#).level,
            Level::Info
        );
        assert_eq!(
            parse_text("Traceback (most recent call last):").level,
            Level::Error
        );
        assert_eq!(parse_text("panic: runtime error").level, Level::Critical);
    }

    #[test]
    fn words_that_are_not_levels() {
        // "error" inside a sentence, after other words, is not the line's level.
        let line = parse_text("Connection closed with error=\"closed by peer\"");
        assert_eq!(line.level, Level::Info);
        // A timestamp's "T" is not a word.
        assert_eq!(
            parse_text("2026-11-11T16:00:00 starting").level,
            Level::Info
        );
    }
}
