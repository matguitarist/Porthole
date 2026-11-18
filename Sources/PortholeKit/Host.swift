import Foundation

/// The server itself: name, version, cores and disks, read now and then.
public struct HostInfo: Sendable, Equatable {
    public struct Disk: Sendable, Equatable, Identifiable {
        public var mount: String
        public var size: Double
        public var used: Double
        /// df's first column: "/dev/loop2", "shfs".
        public var filesystem: String
        public var id: String { mount }
        public var fraction: Double { size > 0 ? used / size : 0 }

        public init(mount: String, size: Double, used: Double, filesystem: String = "") {
            self.mount = mount
            self.size = size
            self.used = used
            self.filesystem = filesystem
        }

        /// Docker's own space: docker.img on Unraid, or the disk of the directory Docker runs from.
        public static let dockerMount = "/var/lib/docker"
        public var isDocker: Bool { mount == Self.dockerMount }

        /// "Array", "Cache", "Flash" for Unraid's mounts.
        public var title: String {
            switch mount {
            case "/mnt/user": String(localized: "Array", bundle: .main)
            case "/mnt/cache": String(localized: "Cache", bundle: .main)
            case "/boot": String(localized: "Flash", bundle: .main)
            case Self.dockerMount: String(localized: "Docker", bundle: .main)
            default: mount
            }
        }
    }

    public var hostname: String
    public var version: String
    public var cores: Int
    public var disks: [Disk]
    /// Unraid's array and its disks; nil on another server.
    public var array: UnraidArray?
    /// Images Unraid found an update for; nil on another server.
    public var updates: ImageUpdates?

    public init(hostname: String = "", version: String = "", cores: Int = 1, disks: [Disk] = [], array: UnraidArray? = nil,
                updates: ImageUpdates? = nil) {
        self.hostname = hostname
        self.version = version
        self.cores = cores
        self.disks = disks
        self.array = array
        self.updates = updates
    }

    public static let command = #"""
    echo "@host $(hostname)"; echo "@cores $(nproc)"; echo "@version $(sed -n 's/^version="\(.*\)"/\1/p' /etc/unraid-version 2>/dev/null)"; df -B1 -P /mnt/user /mnt/cache /boot /var/lib/docker 2>/dev/null | tail -n +2 | awk '{print "@disk", $6, $2, $3, $1}'
    """# + "; " + UnraidArray.command + "; " + ImageUpdates.command

    public static func parse(_ output: String) -> HostInfo {
        var info = HostInfo()
        var variables: [Substring] = [], diskLines: [Substring] = []
        var updatesJSON: Substring?, updatesChecked: Date?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("@updates ") { updatesJSON = line.dropFirst(9); continue }
            if line.hasPrefix("@var ") { variables.append(line.dropFirst(5)); continue }
            if line.hasPrefix("@dsk ") { diskLines.append(line.dropFirst(5)); continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let tag = parts.first else { continue }
            switch tag {
            case "@host": info.hostname = parts.dropFirst().joined(separator: " ")
            case "@cores": info.cores = Int(parts.dropFirst().first ?? "") ?? 1
            case "@updated": updatesChecked = Double(parts.dropFirst().first ?? "").map { Date(timeIntervalSince1970: $0) }
            case "@version": info.version = parts.dropFirst().joined(separator: " ")
            case "@disk" where parts.count >= 4:
                let disk = Disk(mount: String(parts[1]), size: Double(parts[2]) ?? 0, used: Double(parts[3]) ?? 0,
                                filesystem: parts.count > 4 ? String(parts[4]) : "")
                guard !info.disks.contains(where: { $0.mount == disk.mount }) else { continue }
                // Docker in a directory on the cache: the cache's own tile says it already.
                if disk.isDocker, !disk.filesystem.isEmpty, info.disks.contains(where: { $0.filesystem == disk.filesystem }) { continue }
                info.disks.append(disk)
            default: break
            }
        }
        info.array = UnraidArray.parse(variables: variables, disks: diskLines)
        info.updates = updatesJSON.flatMap { ImageUpdates.parse(json: $0, checked: updatesChecked) }
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
/// "@load 0.52 0.61 0.70 …", "@up <seconds>",
/// "@dockerd <ticks per second> <utime> <stime> <start ticks>" (from /proc/<pid>/stat),
/// "@net <bytes in> <bytes out>" (the network cards in /proc/net/dev),
/// "@io <sectors read> <sectors written>" (whole disks in /proc/diskstats), then "@end".
public struct HostLoad: Sendable, Equatable {
    public var cpu: [Double] = []
    public var memoryUsed: [Double] = []
    public var memoryTotal: Double = 0
    public var load: [Double] = []
    public var uptime: TimeInterval = 0
    /// Docker's own CPU, in percent of one core (500 is five cores busy).
    public var dockerdCPU: [Double] = []
    /// How long dockerd has run, in seconds; nil until known.
    public var dockerdUptime: TimeInterval?
    /// Share of the CPU's time spent waiting for the disks, in percent.
    public var ioWait: [Double] = []
    /// Bytes per second through the network cards, received and sent.
    public var networkIn: [Double] = []
    public var networkOut: [Double] = []
    /// Bytes per second read from and written to the disks.
    public var diskRead: [Double] = []
    public var diskWrite: [Double] = []
    let capacity: Int
    private var lastTicks: (busy: Double, total: Double, wait: Double)?
    private var lastDockerd: (ticks: Double, uptime: Double)?
    private var lastNetwork: (received: Double, sent: Double, uptime: Double)?
    private var lastDisk: (read: Double, written: Double, uptime: Double)?

    /// I/O wait from here slows the containers down: a parity check or the mover.
    public static let ioWaitHigh: Double = 20

    /// Network in and out together.
    public var network: [Double] { zip(networkIn, networkOut).map { $0 + $1 } }
    /// Disk reads and writes together.
    public var disk: [Double] { zip(diskRead, diskWrite).map { $0 + $1 } }

    public init(capacity: Int = 90) { self.capacity = capacity }

    public static let command = #"""
    tck=$(getconf CLK_TCK); nics=$(cd /sys/class/net && for d in */device; do printf '%s ' "${d%/device}"; done); while :; do echo "@cpu $(head -1 /proc/stat)"; echo "@mem $(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t, a}' /proc/meminfo)"; echo "@load $(cat /proc/loadavg)"; echo "@up $(cut -d' ' -f1 /proc/uptime)"; p=$(pidof dockerd | cut -d' ' -f1); [ -n "$p" ] && echo "@dockerd $tck $(cut -d' ' -f14,15,22 /proc/$p/stat)"; echo "@net $(awk -v n="$nics" 'BEGIN{c=split(n,a," ");for(i=1;i<=c;i++)k[a[i]]=1} {sub(/^ */,"");i=index($0,":");if(substr($0,1,i-1) in k){split(substr($0,i+1),v," ");r+=v[1];t+=v[9]}} END{printf "%.0f %.0f", r, t}' /proc/net/dev)"; echo "@io $(awk '$3 ~ /^(sd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+|xvd[a-z]+|hd[a-z]+)$/ {r+=$6; w+=$10} END{printf "%.0f %.0f", r, w}' /proc/diskstats)"; echo "@end"; sleep 2; done
    """#

    public static func == (lhs: HostLoad, rhs: HostLoad) -> Bool {
        lhs.cpu == rhs.cpu && lhs.memoryUsed == rhs.memoryUsed && lhs.memoryTotal == rhs.memoryTotal
            && lhs.load == rhs.load && lhs.uptime == rhs.uptime
            && lhs.dockerdCPU == rhs.dockerdCPU && lhs.dockerdUptime == rhs.dockerdUptime
            && lhs.ioWait == rhs.ioWait && lhs.networkIn == rhs.networkIn && lhs.networkOut == rhs.networkOut
            && lhs.diskRead == rhs.diskRead && lhs.diskWrite == rhs.diskWrite
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
            let wait = ticks.count > 4 ? ticks[4] : 0
            let idle = ticks[3] + wait
            let total = ticks.prefix(8).reduce(0, +)
            let busy = total - idle
            if let last = lastTicks, total > last.total {
                cpu = Self.appending(cpu, 100 * (busy - last.busy) / (total - last.total), capacity: capacity)
                // iowait can go backwards on some kernels: never below zero.
                ioWait = Self.appending(ioWait, max(0, 100 * (wait - last.wait) / (total - last.total)), capacity: capacity)
            }
            lastTicks = (busy, total, wait)
        case "@mem" where parts.count >= 3:
            let total = (Double(parts[1]) ?? 0) * 1024
            let available = (Double(parts[2]) ?? 0) * 1024
            memoryTotal = total
            memoryUsed = Self.appending(memoryUsed, max(0, total - available), capacity: capacity)
        case "@load":
            load = parts.dropFirst().prefix(3).compactMap { Double($0) }
        case "@up":
            uptime = Double(parts.dropFirst().first ?? "") ?? 0
        case "@dockerd" where parts.count >= 5:
            // Comes after "@up", so `uptime` is this reading's.
            guard let perSecond = Double(parts[1]), perSecond > 0, let user = Double(parts[2]),
                  let system = Double(parts[3]), let start = Double(parts[4]), uptime > 0 else { return }
            let ticks = user + system
            dockerdUptime = max(0, uptime - start / perSecond)
            // Fewer ticks than before: a new dockerd; start over.
            if let last = lastDockerd, ticks >= last.ticks, uptime > last.uptime {
                dockerdCPU = Self.appending(dockerdCPU, 100 * (ticks - last.ticks) / perSecond / (uptime - last.uptime), capacity: capacity)
            }
            lastDockerd = (ticks, uptime)
        case "@net" where parts.count >= 3:
            // Comes after "@up". Fewer bytes than before: counters reset; start over.
            guard let received = Double(parts[1]), let sent = Double(parts[2]), uptime > 0 else { return }
            if let last = lastNetwork, received >= last.received, sent >= last.sent, uptime > last.uptime {
                let seconds = uptime - last.uptime
                networkIn = Self.appending(networkIn, (received - last.received) / seconds, capacity: capacity)
                networkOut = Self.appending(networkOut, (sent - last.sent) / seconds, capacity: capacity)
            }
            lastNetwork = (received, sent, uptime)
        case "@io" where parts.count >= 3:
            // Sectors are 512 bytes, whatever the disk's own sector size.
            guard let read = Double(parts[1]), let written = Double(parts[2]), uptime > 0 else { return }
            if let last = lastDisk, read >= last.read, written >= last.written, uptime > last.uptime {
                let seconds = uptime - last.uptime
                diskRead = Self.appending(diskRead, (read - last.read) * 512 / seconds, capacity: capacity)
                diskWrite = Self.appending(diskWrite, (written - last.written) * 512 / seconds, capacity: capacity)
            }
            lastDisk = (read, written, uptime)
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

/// When Docker itself is the problem: dockerd busy while the containers aren't.
public enum DockerdWatch {
    /// Busy means above this, in percent of one core, on average…
    public static let threshold: Double = 150
    /// …over this many readings (two seconds apart: five minutes).
    public static let window = 150

    /// The average over the window when it is above the threshold, else nil.
    public static func busy(_ cpu: [Double]) -> Double? {
        guard cpu.count >= window else { return nil }
        let average = cpu.suffix(window).reduce(0, +) / Double(window)
        return average > threshold ? average : nil
    }
}
