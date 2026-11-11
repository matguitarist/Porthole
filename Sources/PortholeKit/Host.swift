import Foundation

/// The server itself: name, version, cores and disks, read now and then.
public struct HostInfo: Sendable, Equatable {
    public struct Disk: Sendable, Equatable, Identifiable {
        public var mount: String
        public var size: Double
        public var used: Double
        public var id: String { mount }
        public var fraction: Double { size > 0 ? used / size : 0 }

        public init(mount: String, size: Double, used: Double) {
            self.mount = mount
            self.size = size
            self.used = used
        }

        /// "Array", "Cache", "Flash" for Unraid's mounts.
        public var title: String {
            switch mount {
            case "/mnt/user": String(localized: "Array", bundle: .main)
            case "/mnt/cache": String(localized: "Cache", bundle: .main)
            case "/boot": String(localized: "Flash", bundle: .main)
            default: mount
            }
        }
    }

    public var hostname: String
    public var version: String
    public var cores: Int
    public var disks: [Disk]

    public init(hostname: String = "", version: String = "", cores: Int = 1, disks: [Disk] = []) {
        self.hostname = hostname
        self.version = version
        self.cores = cores
        self.disks = disks
    }

    public static let command = #"""
    echo "@host $(hostname)"; echo "@cores $(nproc)"; echo "@version $(sed -n 's/^version="\(.*\)"/\1/p' /etc/unraid-version 2>/dev/null)"; df -B1 -P /mnt/user /mnt/cache /boot 2>/dev/null | tail -n +2 | awk '{print "@disk", $6, $2, $3}'
    """#

    public static func parse(_ output: String) -> HostInfo {
        var info = HostInfo()
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let tag = parts.first else { continue }
            switch tag {
            case "@host": info.hostname = parts.dropFirst().joined(separator: " ")
            case "@cores": info.cores = Int(parts.dropFirst().first ?? "") ?? 1
            case "@version": info.version = parts.dropFirst().joined(separator: " ")
            case "@disk" where parts.count == 4:
                guard !info.disks.contains(where: { $0.mount == parts[1] }) else { continue }
                info.disks.append(Disk(mount: String(parts[1]), size: Double(parts[2]) ?? 0, used: Double(parts[3]) ?? 0))
            default: break
            }
        }
        return info
    }

    /// Unraid version for the subtitle: "Unraid 7.2.1".
    public var subtitle: String {
        let count = String(localized: "\(cores) cores", bundle: .main)
        return version.isEmpty ? count : "Unraid \(version) · \(count)"
    }
}

/// The server's load, streamed every two seconds:
/// "@cpu cpu 1 2 3 …" (from /proc/stat), "@mem <total kB> <available kB>",
/// "@load 0.52 0.61 0.70 …", "@up <seconds>", then "@end".
public struct HostLoad: Sendable, Equatable {
    public var cpu: [Double] = []
    public var memoryUsed: [Double] = []
    public var memoryTotal: Double = 0
    public var load: [Double] = []
    public var uptime: TimeInterval = 0
    let capacity: Int
    private var lastTicks: (busy: Double, total: Double)?

    public init(capacity: Int = 90) { self.capacity = capacity }

    public static let command = #"""
    while :; do echo "@cpu $(head -1 /proc/stat)"; echo "@mem $(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t, a}' /proc/meminfo)"; echo "@load $(cat /proc/loadavg)"; echo "@up $(cut -d' ' -f1 /proc/uptime)"; echo "@end"; sleep 2; done
    """#

    public static func == (lhs: HostLoad, rhs: HostLoad) -> Bool {
        lhs.cpu == rhs.cpu && lhs.memoryUsed == rhs.memoryUsed && lhs.memoryTotal == rhs.memoryTotal
            && lhs.load == rhs.load && lhs.uptime == rhs.uptime
    }

    /// Reads one line; CPU % comes from the change since the previous "@cpu".
    public mutating func read(_ line: String) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard let tag = parts.first else { return }
        switch tag {
        case "@cpu":
            // "@cpu cpu user nice system idle iowait irq softirq steal …"
            let ticks = parts.dropFirst(2).compactMap { Double($0) }
            guard ticks.count >= 4 else { return }
            let idle = ticks[3] + (ticks.count > 4 ? ticks[4] : 0)
            let total = ticks.prefix(8).reduce(0, +)
            let busy = total - idle
            if let last = lastTicks, total > last.total {
                cpu = Self.appending(cpu, 100 * (busy - last.busy) / (total - last.total), capacity: capacity)
            }
            lastTicks = (busy, total)
        case "@mem" where parts.count >= 3:
            let total = (Double(parts[1]) ?? 0) * 1024
            let available = (Double(parts[2]) ?? 0) * 1024
            memoryTotal = total
            memoryUsed = Self.appending(memoryUsed, max(0, total - available), capacity: capacity)
        case "@load":
            load = parts.dropFirst().prefix(3).compactMap { Double($0) }
        case "@up":
            uptime = Double(parts.dropFirst().first ?? "") ?? 0
        default: break
        }
    }

    private static func appending(_ values: [Double], _ value: Double, capacity: Int) -> [Double] {
        var values = values
        values.append(value)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
        return values
    }
}
