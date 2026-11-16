import Foundation

/// Unraid's array: its state, the parity check, and each disk's health, from
/// emhttp's files (/var/local/emhttp/var.ini and disks.ini). Nil on a server
/// that isn't Unraid.
public struct UnraidArray: Sendable, Equatable {
    public struct Disk: Sendable, Equatable, Identifiable {
        public var name: String
        /// "Parity", "Data", "Cache", "Flash".
        public var type: String
        public var status: String
        /// °C; nil when spun down or unknown.
        public var temperature: Int?
        public var errors: Int
        public var spunDown: Bool
        public var rotational: Bool
        public var id: String { name }

        public init(name: String, type: String, status: String = "DISK_OK", temperature: Int? = nil,
                    errors: Int = 0, spunDown: Bool = false, rotational: Bool = true) {
            self.name = name
            self.type = type
            self.status = status
            self.temperature = temperature
            self.errors = errors
            self.spunDown = spunDown
            self.rotational = rotational
        }

        /// Hot from here: a hard disk at 50 °C, an SSD at 70 °C.
        public var hotFrom: Int { rotational ? 50 : 70 }
        public var isHot: Bool { (temperature ?? 0) >= hotFrom }

        /// "Parity", "Parity 2", "Disk 1", "Cache".
        public var title: String {
            if name == "parity" { return String(localized: "Parity", bundle: .main) }
            if name.hasPrefix("parity"), let n = Int(name.dropFirst(6)) { return String(localized: "Parity \(n)", bundle: .main) }
            if name.hasPrefix("disk"), let n = Int(name.dropFirst(4)) { return String(localized: "Disk \(n)", bundle: .main) }
            if name == "cache" { return String(localized: "Cache", bundle: .main) }
            return name.prefix(1).uppercased() + name.dropFirst()
        }

        /// What is wrong with the disk, worst first; nil when it is fine.
        public var problem: String? {
            switch status {
            case "DISK_OK": break
            case "DISK_DSBL", "DISK_NP_DSBL": return String(localized: "Disabled", bundle: .main)
            case "DISK_NP", "DISK_NP_MISSING": return String(localized: "Missing", bundle: .main)
            case "DISK_INVALID": return String(localized: "Contents not valid", bundle: .main)
            case "DISK_WRONG": return String(localized: "Wrong disk", bundle: .main)
            case "DISK_DSBL_NEW", "DISK_NEW": return String(localized: "New disk, not in use yet", bundle: .main)
            default: return status
            }
            if errors > 0 { return errors == 1 ? String(localized: "1 read or write error", bundle: .main) : String(localized: "\(errors) read or write errors", bundle: .main) }
            if isHot, let temperature { return String(localized: "Hot: \(temperature) °C", bundle: .main) }
            return nil
        }

        /// A disk failing or gone is worse than a hot one.
        public var isSerious: Bool { status != "DISK_OK" || errors > 0 }
    }

    /// A parity check, sync or rebuild under way.
    public struct Check: Sendable, Equatable {
        /// "check P", "recon P", "recon D1", "clear".
        public var action: String
        public var fraction: Double
        /// Bytes per second; 0 when unknown.
        public var speed: Double
        public var total: Double

        public var title: String {
            if action.hasPrefix("check") { return String(localized: "Parity check", bundle: .main) }
            if action.hasPrefix("recon P") || action.hasPrefix("recon Q") { return String(localized: "Parity sync", bundle: .main) }
            if action.hasPrefix("recon") { return String(localized: "Disk rebuild", bundle: .main) }
            if action.hasPrefix("clear") { return String(localized: "Disk clear", bundle: .main) }
            return action
        }

        /// Seconds left at the current speed.
        public var remaining: TimeInterval? {
            speed > 0 ? total * (1 - fraction) / speed : nil
        }
    }

    /// The last parity check that ended.
    public struct LastCheck: Sendable, Equatable {
        public var finished: Date
        public var duration: TimeInterval
        public var errors: Int
        /// 0 when it ran to the end; -4 when it was stopped.
        public var exit: Int

        public init(finished: Date, duration: TimeInterval, errors: Int, exit: Int) {
            self.finished = finished
            self.duration = duration
            self.errors = errors
            self.exit = exit
        }
    }

    /// "STARTED", "STOPPED".
    public var state: String
    public var disks: [Disk]
    public var check: Check?
    public var lastCheck: LastCheck?

    public init(state: String = "STARTED", disks: [Disk] = [], check: Check? = nil, lastCheck: LastCheck? = nil) {
        self.state = state
        self.disks = disks
        self.check = check
        self.lastCheck = lastCheck
    }

    public var isStarted: Bool { state == "STARTED" }

    /// Disks with a problem, failing ones first. Empty slots are not disks.
    public var troubled: [Disk] {
        disks.filter { $0.problem != nil }.sorted { $0.isSerious && !$1.isSerious }
    }

    /// Lines for HostInfo.command: "@var key=value", then "@dsk" lines of disks.ini.
    static let command = #"""
    grep -sE '^(mdState|mdResyncPos|mdResyncSize|mdResyncAction|mdResyncDt|mdResyncDb|sbSynced|sbSynced2|sbSyncErrs|sbSyncExit)=' /var/local/emhttp/var.ini | sed 's/^/@var /'; grep -sE '^(\[|(name|device|status|temp|numErrors|type|rotational|spundown)=)' /var/local/emhttp/disks.ini | sed 's/^/@dsk /'; true
    """#

    /// Reads `key="value"` lines of var.ini and disks.ini (sections start with `["name"]`).
    static func parse(variables: [Substring], disks diskLines: [Substring]) -> UnraidArray? {
        func pair(_ line: Substring) -> (String, String)? {
            guard let equals = line.firstIndex(of: "=") else { return nil }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            return (String(line[..<equals]), value)
        }
        let vars = Dictionary(variables.compactMap(pair), uniquingKeysWith: { _, last in last })
        guard let state = vars["mdState"] else { return nil }

        var sections: [[String: String]] = []
        for line in diskLines {
            if line.hasPrefix("[") { sections.append([:]); continue }
            guard !sections.isEmpty, let (key, value) = pair(line) else { continue }
            sections[sections.count - 1][key] = value
        }
        let disks = sections.compactMap { values -> Disk? in
            guard let name = values["name"], let type = values["type"], type != "Flash" else { return nil }
            let status = values["status"] ?? "DISK_OK"
            // An empty slot (parity2 on most servers) has no device.
            if (values["device"] ?? "").isEmpty, status.hasPrefix("DISK_NP") { return nil }
            let spunDown = values["spundown"] == "1"
            return Disk(name: name, type: type, status: status,
                        temperature: spunDown ? nil : values["temp"].flatMap { Int($0) },
                        errors: Int(values["numErrors"] ?? "") ?? 0, spunDown: spunDown,
                        rotational: values["rotational"] != "0")
        }

        var array = UnraidArray(state: state, disks: disks)
        let size = Double(vars["mdResyncSize"] ?? "") ?? 0
        if let position = Double(vars["mdResyncPos"] ?? ""), position > 0, size > 0 {
            let blocks = Double(vars["mdResyncDb"] ?? "") ?? 0, seconds = Double(vars["mdResyncDt"] ?? "") ?? 0
            // Sizes and positions are in 1 KiB blocks.
            array.check = Check(action: vars["mdResyncAction"] ?? "check", fraction: min(1, position / size),
                                speed: seconds > 0 ? blocks * 1024 / seconds : 0, total: size * 1024)
        }
        if let end = Double(vars["sbSynced2"] ?? ""), end > 0 {
            let start = Double(vars["sbSynced"] ?? "") ?? end
            array.lastCheck = LastCheck(finished: Date(timeIntervalSince1970: end), duration: max(0, end - start),
                                        errors: Int(vars["sbSyncErrs"] ?? "") ?? 0, exit: Int(vars["sbSyncExit"] ?? "") ?? 0)
        }
        return array
    }
}
