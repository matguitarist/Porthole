import LogKit
import PortholeKit
import SwiftUI

/// The server at a glance: load, storage, containers that need a look, and
/// each container's warnings and errors over the last day.
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                ServerTiles()
                if let disks = model.hostInfo?.disks, !disks.isEmpty {
                    StorageTiles(disks: disks)
                }
                if !model.containersNeedingAttention.isEmpty {
                    AttentionList()
                }
                ProblemList()
                BusiestList()
            }
            .padding(Space.margin)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .gridArea("overview")
        }
        .navigationTitle(model.hostInfo?.hostname ?? ServerSettings.host)
        .navigationSubtitle(model.hostInfo?.subtitle ?? "")
        .toolbar {
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
        let load = model.hostLoad
        let running = model.containers.filter(\.isRunning).count
        let stopped = model.containers.count - running
        let unhealthy = model.containers.filter { $0.health == "unhealthy" }.count
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Space.md)], alignment: .leading, spacing: Space.md) {
            Tile(title: "CPU", symbol: "cpu") {
                BigNumber(load.cpu.last.map(Format.percent) ?? "—")
                Sparkline(values: load.cpu).frame(height: 28)
                Text(load.load.isEmpty ? " " : "Load \(load.load.map { String(format: "%.2f", $0) }.joined(separator: "  "))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .help("CPU over the last \(Format.window(load.cpu.count)), all \(model.hostInfo?.cores ?? 1) cores together. Load is the 1, 5 and 15 minute average.")
            Tile(title: "Memory", symbol: "memorychip") {
                BigNumber(load.memoryUsed.last.map(Format.bytes) ?? "—")
                Sparkline(values: load.memoryUsed).frame(height: 28)
                Text(load.memoryTotal > 0 ? "of \(Format.bytes(load.memoryTotal))" : " ")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .help("Memory in use (not counting caches) over the last \(Format.window(load.memoryUsed.count))")
            Tile(title: "Containers", symbol: "shippingbox") {
                BigNumber("\(running) running")
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
}

struct StorageTiles: View {
    let disks: [HostInfo.Disk]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionTitle("Storage")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Space.md)], alignment: .leading, spacing: Space.md) {
                ForEach(disks) { disk in
                    let full = disk.fraction >= 0.9
                    Tile(title: disk.title, symbol: disk.mount == "/boot" ? "memorychip" : "internaldrive") {
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
        .help("Show \(container.name)'s warnings and errors")
    }

    private var latest: String? {
        guard let line = summary.latest else { return nil }
        let when = line.date.map { $0.formatted(.relative(presentation: .named)) } ?? ""
        return "\(when): \(line.message)"
    }
}

/// "12 errors" with the level's symbol and color, so it never relies on color alone.
struct CountChip: View {
    let count: Int
    let capped: Bool
    let level: LogLevel

    var body: some View {
        let isError = level >= .error
        Label("\(count)\(capped ? "+" : "") \(isError ? (count == 1 ? "error" : "errors") : (count == 1 ? "warning" : "warnings"))",
              systemImage: isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
            .font(.callout.monospacedDigit())
            .foregroundStyle(isError ? .red : .orange)
            .fixedSize()
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
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Space.xs) {
                content
            }
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
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
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.headline)
    }
}

extension Format {
    /// "6 days 4 h", "3 h 12 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60, hours = minutes / 60, days = hours / 24
        if days > 0 { return "\(days) day\(days == 1 ? "" : "s") \(hours % 24) h" }
        if hours > 0 { return "\(hours) h \(minutes % 60) min" }
        return "\(minutes) min"
    }

    static func disk(_ bytes: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
