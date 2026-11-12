import LogKit
import PortholeKit
import SwiftUI

/// The server at a glance: load, storage, containers that need a look, and
/// each container's warnings and errors over the last day.
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xxl) {
                    ServerTiles()
                    if proxy.size.width >= 1200 {
                        // Wide (full screen): problems on the left, the rest on the right.
                        HStack(alignment: .top, spacing: Space.xxl) {
                            VStack(alignment: .leading, spacing: Space.xxl) {
                                AttentionSection()
                                ProblemList()
                            }
                            .frame(maxWidth: .infinity)
                            VStack(alignment: .leading, spacing: Space.xxl) {
                                StorageSection(columns: 1)
                                EventList()
                                BusiestList()
                            }
                            .frame(width: min(520, proxy.size.width * 0.36))
                        }
                    } else {
                        StorageSection(columns: nil)
                        AttentionSection()
                        ProblemList()
                        EventList()
                        BusiestList()
                    }
                }
                .padding(Space.margin)
                .frame(maxWidth: .infinity, alignment: .leading)
                .gridArea("overview")
            }
        }
        .navigationTitle(model.hostInfo?.hostname ?? ServerSettings.host)
        .navigationSubtitle(model.hostInfo?.subtitle ?? "")
        .toolbar {
            ToolbarItem {
                Button("Clear All Logs on Server…", systemImage: "trash") { model.requestClearLogs() }
                    .help("Empty every container's log file on the server, to start fresh")
                    .disabled(model.clearing || model.containers.isEmpty)
            }
            ToolbarItem {
                Button("Scan Logs for Problems", systemImage: "arrow.clockwise") {
                    Task { await model.scanProblems() }
                }
                .help("Read the last \(ProblemSummary.hours) hours of every container's log again (Shift-Command-P)")
                .disabled(model.scanningProblems)
            }
        }
    }
}

// MARK: Server

struct ServerTiles: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Four across, stretched, whenever they fit; fewer on a narrow window.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Space.md) { tiles }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Space.md)], alignment: .leading, spacing: Space.md) { tiles }
        }
    }

    @ViewBuilder
    private var tiles: some View {
        let load = model.hostLoad
        let running = model.containers.filter(\.isRunning).count
        let stopped = model.containers.count - running
        let unhealthy = model.containers.filter { $0.health == "unhealthy" }.count
            Tile(title: "CPU", symbol: "cpu") {
                BigNumber(load.cpu.last.map(Format.percent) ?? "—")
                Sparkline(values: load.cpu).frame(height: 28)
                if let busy = DockerdWatch.busy(load.dockerdCPU) {
                    Label("Docker at \(Int(busy.rounded()))%", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.monospacedDigit()).foregroundStyle(.orange)
                } else {
                    Text(load.load.isEmpty ? " " : "Load \(load.load.map { String(format: "%.2f", $0) }.joined(separator: "  "))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .help(cpuHelp(load))
            Tile(title: "Memory", symbol: "memorychip") {
                BigNumber(load.memoryUsed.last.map(Format.bytes) ?? "—")
                Sparkline(values: load.memoryUsed).frame(height: 28)
                Text(load.memoryTotal > 0 ? "of \(Format.bytes(load.memoryTotal))" : " ")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .help("Memory in use (not counting caches) over the last \(Format.window(load.memoryUsed.count))")
            Tile(title: "Containers", symbol: "shippingbox") {
                BigNumber(String(localized: "\(running) running"))
                Spacer(minLength: 0)
                HStack(spacing: Space.sm) {
                    Text("\(stopped) stopped")
                    if unhealthy > 0 {
                        Label("\(unhealthy) unhealthy", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Tile(title: "Up For", symbol: "clock") {
                BigNumber(load.uptime > 0 ? Format.duration(load.uptime) : "—")
                Spacer(minLength: 0)
                Text(load.uptime > 0 ? "Since \(Date(timeIntervalSinceNow: -load.uptime).formatted(date: .abbreviated, time: .shortened))" : " ")
                    .font(.caption).foregroundStyle(.secondary)
            }
    }
}

extension ServerTiles {
    func cpuHelp(_ load: HostLoad) -> String {
        let all = String(localized: "CPU over the last \(Format.window(load.cpu.count)), all \(model.hostInfo?.cores ?? 1) cores together. Load is the 1, 5 and 15 minute average.")
        guard let docker = load.dockerdCPU.last else { return all }
        return all + " " + String(localized: "Docker itself: \(Int(docker.rounded()))% of one core.")
    }
}

struct StorageSection: View {
    @Environment(AppModel.self) private var model
    /// A fixed number of columns, or nil to fit the width.
    let columns: Int?

    var body: some View {
        if let disks = model.hostInfo?.disks, !disks.isEmpty {
            StorageTiles(disks: disks, columns: columns)
        }
    }
}

struct StorageTiles: View {
    let disks: [HostInfo.Disk]
    var columns: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionTitle("Storage")
            LazyVGrid(columns: columns.map { Array(repeating: GridItem(.flexible(), spacing: Space.md), count: $0) }
                      ?? [GridItem(.adaptive(minimum: 200), spacing: Space.md)], alignment: .leading, spacing: Space.md) {
                ForEach(disks) { disk in
                    let full = disk.fraction >= 0.9
                    Tile(title: LocalizedStringKey(disk.title), symbol: disk.mount == "/boot" ? "memorychip" : "internaldrive") {
                        HStack(alignment: .firstTextBaseline) {
                            BigNumber(String(format: "%.0f%%", disk.fraction * 100))
                            if full {
                                Label("Almost full", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Gauge(value: disk.fraction) {}
                            .gaugeStyle(.linearCapacity)
                            .tint(full ? .orange : Palette.accent)
                        Text("\(Format.disk(disk.used)) of \(Format.disk(disk.size))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .help("\(disk.mount): \(Format.disk(disk.size - disk.used)) free")
                }
            }
        }
    }
}

// MARK: Containers

struct AttentionSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.containersNeedingAttention.isEmpty { AttentionList() }
    }
}

struct AttentionList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionTitle("Needs a Look")
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(Array(model.containersNeedingAttention.enumerated()), id: \.element.id) { index, container in
                        if index > 0 { Divider() }
                        let look = StateBadge.look(container)
                        OverviewRow(container: container, action: { model.open(container.name) }) {
                            Label(look.help, systemImage: look.symbol)
                                .foregroundStyle(look.color)
                                .font(.callout)
                        }
                    }
                }
            }
        }
    }
}

struct ProblemList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                SectionTitle("Warnings and Errors, Last \(ProblemSummary.hours) Hours")
                if model.scanningProblems {
                    ProgressView().controlSize(.mini)
                } else if let scanned = model.problemsScanned {
                    Text("Read \(scanned.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                let noise = model.problems.values.reduce(0) { $0 + $1.aroundRestart }
                if noise > 0, let restarted = model.dockerRestarted {
                    Text("· \(noise) from Docker's restart at \(restarted.formatted(date: .omitted, time: .shortened)) not counted")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("When Docker restarts, every container logs its shutdown and startup. Those lines stay in the logs but don't count as problems or send alerts.")
                }
            }
            let rows = model.containersWithProblems
            GroupBox {
                if rows.isEmpty {
                    Text(model.problemsScanned == nil ? "Reading every container's log…" : "No warnings or errors in any container.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Space.sm)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.container.id) { index, row in
                            if index > 0 { Divider() }
                            ProblemRow(container: row.container, summary: row.summary)
                        }
                    }
                }
            }
        }
    }
}

struct ProblemRow: View {
    @Environment(AppModel.self) private var model
    let container: Container
    let summary: ProblemSummary

    var body: some View {
        OverviewRow(container: container, detail: latest, action: { model.open(container.name, problemsOnly: true) }) {
            HStack(spacing: Space.sm) {
                // The server sends at most so many lines: the bigger count may be higher.
                if summary.errors > 0 {
                    CountChip(count: summary.errors, capped: summary.capped && summary.errors >= summary.warnings, level: .error)
                }
                if summary.warnings > 0 {
                    CountChip(count: summary.warnings, capped: summary.capped && summary.warnings > summary.errors, level: .warning)
                }
            }
        }
        .help("Show \(container.name)'s warnings and errors of the last day")
        .contextMenu {
            Button("Show Warnings and Errors") { model.open(container.name, problemsOnly: true) }
            Button("Show Whole Log") { model.open(container.name) }
            if let latest = summary.latest {
                Divider()
                Button("Ignore Messages Like the Latest…", systemImage: "eye.slash") {
                    model.ignoreDraft = IgnoreDraft(container: container.name, message: latest.message)
                }
            }
            Divider()
            Button("Clear Log on Server…", systemImage: "trash") { model.requestClearLogs([container.name]) }
        }
    }

    private var latest: String? {
        guard let line = summary.latest else { return nil }
        let when = line.date.map { $0.formatted(.relative(presentation: .named)) } ?? ""
        return when.isEmpty ? line.message : "\(when): \(line.message)"
    }
}

/// "12 errors" with the level's symbol and color, so it never relies on color alone.
struct CountChip: View {
    let count: Int
    let capped: Bool
    let level: LogLevel

    var body: some View {
        let isError = level >= .error
        let more = capped ? "+" : ""
        let text = isError
            ? (count == 1 ? String(localized: "1\(more) error") : String(localized: "\(count)\(more) errors"))
            : (count == 1 ? String(localized: "1\(more) warning") : String(localized: "\(count)\(more) warnings"))
        Label(text,
              systemImage: isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
            .font(.callout.monospacedDigit())
            .foregroundStyle(isError ? .red : .orange)
            .fixedSize()
    }
}

/// Starts, crashes and health changes of the last day, newest first.
struct EventList: View {
    @Environment(AppModel.self) private var model
    @State private var showAll = false

    var body: some View {
        let events = model.recentEvents
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionTitle("Events, Last 24 Hours")
            GroupBox {
                if events.isEmpty {
                    Text("No container started, stopped or changed health.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Space.sm)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(events.prefix(showAll ? 300 : 12).enumerated()), id: \.offset) { index, event in
                            if index > 0 { Divider() }
                            EventRow(event: event)
                        }
                        if events.count > 12 {
                            Divider()
                            Button(showAll ? "Show Fewer" : "Show All \(events.count)") { showAll.toggle() }
                                .buttonStyle(.link)
                                .padding(.vertical, Space.sm)
                        }
                    }
                }
            }
        }
    }
}

struct EventRow: View {
    @Environment(AppModel.self) private var model
    let event: DockerEvent

    var body: some View {
        let look = Self.look(event)
        Button {
            if model.containers.contains(where: { $0.name == event.name }) { model.open(event.name) }
        } label: {
            HStack(spacing: Space.md) {
                Image(systemName: look.symbol).foregroundStyle(look.color).frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(event.name).lineLimit(1)
                    Text(event.summary).font(.caption).foregroundStyle(event.isProblem ? look.color : .secondary)
                }
                Spacer(minLength: Space.sm)
                Text(event.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.vertical, Space.xs)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(event.date.formatted(date: .abbreviated, time: .standard))
    }

    static func look(_ event: DockerEvent) -> (symbol: String, color: Color) {
        switch event.action {
        case "start", "restart": ("play.circle.fill", .green)
        case "oom": ("memorychip.fill", .red)
        case "health_status: unhealthy": ("exclamationmark.triangle.fill", .orange)
        case "health_status: healthy": ("checkmark.circle.fill", .green)
        default: event.isProblem ? ("xmark.octagon.fill", .red) : ("stop.circle", .secondary)
        }
    }
}

struct BusiestList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let busiest = model.containers
            .compactMap { container in model.stats[container.name].flatMap { history in history.cpu.last.map { (container, history, $0) } } }
            .filter { $0.0.isRunning }
            .sorted { $0.2 > $1.2 }
            .prefix(5)
        if !busiest.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                SectionTitle("Busiest Now")
                GroupBox {
                    VStack(spacing: 0) {
                        ForEach(Array(busiest.enumerated()), id: \.element.0.id) { index, item in
                            if index > 0 { Divider() }
                            OverviewRow(container: item.0, action: { model.open(item.0.name) }) {
                                HStack(spacing: Space.md) {
                                    Sparkline(values: item.1.cpu).frame(width: 56, height: 16)
                                    Text(Format.percent(item.2)).frame(width: 48, alignment: .trailing)
                                    Text(Format.bytes(item.1.memory.last ?? 0)).foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
                                }
                                .font(.callout.monospacedDigit())
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: Parts

/// A container as a row that opens it: icon, name, an optional line under it, and what's on the right.
struct OverviewRow<Trailing: View>: View {
    let container: Container
    var detail: String?
    let action: () -> Void
    @ViewBuilder let trailing: Trailing

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.md) {
                ContainerIcon(container: container)
                VStack(alignment: .leading, spacing: 0) {
                    Text(container.name).foregroundStyle(.primary)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: Space.md)
                trailing
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, Space.sm)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

struct Tile<Content: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Space.xs) {
                content
            }
            .frame(minWidth: 176, maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
        } label: {
            Label(title, systemImage: symbol).foregroundStyle(.secondary)
        }
    }
}

struct BigNumber: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.title2.weight(.semibold).monospacedDigit()).lineLimit(1)
    }
}

struct SectionTitle: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text).font(.headline)
    }
}

extension Format {
    /// "6 days 4 h", "3 h 12 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60, hours = minutes / 60, days = hours / 24
        if days > 0 { return days == 1 ? String(localized: "1 day \(hours % 24) h") : String(localized: "\(days) days \(hours % 24) h") }
        if hours > 0 { return String(localized: "\(hours) h \(minutes % 60) min") }
        return String(localized: "\(minutes) min")
    }

    static func disk(_ bytes: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
