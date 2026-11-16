import Foundation

/// What fills Docker's own space (`docker system df`), and each container's
/// log file size. Read every few minutes: `docker system df` takes a moment.
public struct DockerDisk: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case images = "Images"
        case containers = "Containers"
        case volumes = "Local Volumes"
        case buildCache = "Build Cache"

        public var title: String {
            switch self {
            case .images: String(localized: "Images", bundle: .main)
            case .containers: String(localized: "Containers", bundle: .main)
            case .volumes: String(localized: "Volumes", bundle: .main)
            case .buildCache: String(localized: "Build cache", bundle: .main)
            }
        }
    }

    public struct Usage: Sendable, Equatable, Identifiable {
        public var kind: Kind
        public var count: Int
        public var size: Double
        /// What Docker says nothing uses and could be removed.
        public var reclaimable: Double
        public var id: Kind { kind }

        public init(kind: Kind, count: Int, size: Double, reclaimable: Double) {
            self.kind = kind
            self.count = count
            self.size = size
            self.reclaimable = reclaimable
        }
    }

    public var usage: [Usage]
    /// Log file size in bytes, by container name.
    public var logs: [String: Double]

    public init(usage: [Usage] = [], logs: [String: Double] = [:]) {
        self.usage = usage
        self.logs = logs
    }

    public var total: Double { usage.reduce(0) { $0 + $1.size } }
    public var reclaimable: Double { usage.reduce(0) { $0 + $1.reclaimable } }

    /// The biggest log files, largest first; empty ones left out.
    public func biggestLogs(_ count: Int) -> [(name: String, bytes: Double)] {
        logs.filter { $0.value > 0 }
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(count)
            .map { (name: $0.key, bytes: $0.value) }
    }

    /// "@df {json}" per kind of `docker system df`, then "@log name bytes" per container.
    public static let command = #"""
    docker system df --format '{{json .}}' | sed 's/^/@df /'; ids=$(docker ps -aq); [ -n "$ids" ] && docker inspect -f '{{.Name}} {{.LogPath}}' $ids | while read -r n p; do echo "@log ${n#/} $(stat -c %s "$p" 2>/dev/null || echo 0)"; done; true
    """#

    public static func parse(_ output: String) -> DockerDisk {
        var disk = DockerDisk()
        for line in output.split(separator: "\n") {
            if line.hasPrefix("@df "),
               let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(4).utf8)) as? [String: Any],
               let kind = (object["Type"] as? String).flatMap(Kind.init(rawValue:)) {
                // "1.409MB (6%)": the size before the share.
                let reclaimable = (object["Reclaimable"] as? String ?? "").components(separatedBy: " (")[0]
                disk.usage.append(Usage(kind: kind,
                                        count: Int(object["TotalCount"] as? String ?? "") ?? 0,
                                        size: ContainerStats.bytes(object["Size"] as? String ?? "") ?? 0,
                                        reclaimable: ContainerStats.bytes(reclaimable) ?? 0))
            } else if line.hasPrefix("@log ") {
                let parts = line.split(separator: " ")
                guard parts.count == 3, let bytes = Double(parts[2]) else { continue }
                disk.logs[String(parts[1])] = bytes
            }
        }
        return disk
    }
}
