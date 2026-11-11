import LogKitUI
import PortholeKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            ContainerSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            ContainerDetail()
        }
        .task {
            SelfTest.runIfRequested(model: model)
            Snapshot.runIfRequested(model: model, openSettings: openSettings)
            await model.connect()
        }
        .confirmationDialog(Text("Stop \(model.confirmStop ?? "")?"), isPresented: Binding(
            get: { model.confirmStop != nil }, set: { if !$0 { model.confirmStop = nil } })) {
            Button("Stop", role: .destructive) {
                if let name = model.confirmStop { Task { await model.perform(.stop, on: name) } }
                model.confirmStop = nil
            }
        } message: {
            Text("It stops answering until you start it again. Anything that depends on it stops working too.")
        }
        .alert("Couldn't Do That", isPresented: Binding(
            get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
        } message: {
            Text(model.actionError ?? "")
        }
    }
}

// MARK: Sidebar

struct ContainerSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            if !model.running.isEmpty {
                Section("Running") {
                    ForEach(model.running) { ContainerRow(container: $0).tag($0.name) }
                }
            }
            if !model.stopped.isEmpty {
                Section("Stopped") {
                    ForEach(model.stopped) { ContainerRow(container: $0).tag($0.name) }
                }
            }
        }
        .searchable(text: $model.search, placement: .sidebar, prompt: "Filter")
        .overlay { overlay }
        .contextMenu(forSelectionType: String.self) { names in
            if let name = names.first, let container = model.containers.first(where: { $0.name == name }) {
                ContainerActions(container: container)
            }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch model.connection {
        case .connecting where model.containers.isEmpty:
            ProgressView("Connecting to \(ServerSettings.host)…")
                .controlSize(.small)
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't Reach the Server", systemImage: "network.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.reconnect() }
                Button("Settings…") { openSettings() }
            }
        default:
            if model.shown.isEmpty, !model.search.isEmpty {
                ContentUnavailableView.search(text: model.search)
            } else if model.containers.isEmpty, model.connection == .connected {
                ContentUnavailableView("No Containers", systemImage: "shippingbox",
                                       description: Text("Docker on \(ServerSettings.host) has no containers."))
            }
        }
    }
}

struct ContainerRow: View {
    @Environment(AppModel.self) private var model
    let container: Container

    var body: some View {
        HStack(spacing: Space.sm) {
            ContainerIcon(container: container)
            VStack(alignment: .leading, spacing: 0) {
                Text(container.name).lineLimit(1)
                Text(container.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.xs)
            if container.isRunning, let cpu = model.stats[container.name]?.cpu.last {
                Text(Format.percent(cpu))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("CPU now")
            }
            StateBadge(container: container)
        }
    }
}

/// The container's own icon from its Unraid template, or a box.
struct ContainerIcon: View {
    let container: Container

    var body: some View {
        Group {
            if let url = container.iconURL, url.scheme?.hasPrefix("http") == true {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(.rect(cornerRadius: Space.xs))
        .opacity(container.isRunning ? 1 : 0.5)
    }

    private var placeholder: some View {
        Image(systemName: "shippingbox")
            .foregroundStyle(.secondary)
    }
}

/// State as a symbol and a color, with words in the help tag.
struct StateBadge: View {
    let container: Container

    var body: some View {
        let look = Self.look(container)
        Image(systemName: look.symbol)
            .foregroundStyle(look.color)
            .imageScale(.small)
            .help(look.help)
            .accessibilityLabel(look.help)
    }

    static func look(_ container: Container) -> (symbol: String, color: Color, help: String) {
        if container.state == "restarting" { return ("arrow.clockwise.circle.fill", .orange, "Restarting") }
        if container.state == "paused" { return ("pause.circle.fill", .secondary, "Paused") }
        if container.isRunning {
            switch container.health {
            case "unhealthy": return ("exclamationmark.triangle.fill", .orange, "Running, unhealthy")
            case "starting": return ("circle.dotted", .green, "Running, health check starting")
            default: return ("circle.fill", .green, container.health == "healthy" ? "Running, healthy" : "Running")
            }
        }
        if let code = container.exitCode, code != 0, code != 143 {
            return ("xmark.circle.fill", .red, "Stopped with exit code \(code)")
        }
        return ("stop.circle", .secondary, "Stopped")
    }
}

/// Start, Stop, Restart and the web page, for menus.
struct ContainerActions: View {
    @Environment(AppModel.self) private var model
    let container: Container

    var body: some View {
        Button("Start", systemImage: "play") { model.request(.start, on: container.name) }
            .disabled(!model.canPerform(.start, on: container))
        Button("Stop…", systemImage: "stop") { model.request(.stop, on: container.name) }
            .disabled(!model.canPerform(.stop, on: container))
        Button("Restart", systemImage: "arrow.clockwise") { model.request(.restart, on: container.name) }
            .disabled(!model.canPerform(.restart, on: container))
        if let url = model.webUI(for: container) {
            Divider()
            Button("Open Web Page", systemImage: "safari") { NSWorkspace.shared.open(url) }
        }
    }
}

// MARK: Detail

struct ContainerDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let name = model.selection {
            let log = model.log(for: name)
            LogViewer(model: log.viewer, options: options(for: name))
                .id(name)
                .navigationTitle(name)
                .navigationSubtitle(model.selected?.image ?? "")
                .toolbar { toolbar }
        } else {
            ContentUnavailableView("No Container Selected", systemImage: "shippingbox",
                                   description: Text("Pick a container to see its log."))
        }
    }

    private func options(for name: String) -> LogViewerOptions {
        LogViewerOptions(
            emptyTitle: "No Messages",
            emptyMessage: "\(name) hasn't logged anything yet.",
            insightsTitle: "What Docker is telling you",
            insightActions: { insight in
                AnyView(InsightActions(insight: insight, name: name))
            },
            headerAccessory: { AnyView(UsageView(name: name)) },
            sourceColor: { _ in .secondary })
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if let container = model.selected {
                if container.isRunning {
                    Button("Stop", systemImage: "stop.fill") { model.request(.stop) }
                        .help("Stop \(container.name) (Option-Command-Period)")
                        .disabled(!model.canPerform(.stop))
                    Button("Restart", systemImage: "arrow.clockwise") { model.request(.restart) }
                        .help("Restart \(container.name) (Option-Command-R)")
                        .disabled(!model.canPerform(.restart))
                } else {
                    Button("Start", systemImage: "play.fill") { model.request(.start) }
                        .help("Start \(container.name) (Option-Command-S)")
                        .disabled(!model.canPerform(.start))
                }
                if let url = model.webUI() {
                    Button("Open Web Page", systemImage: "safari") { NSWorkspace.shared.open(url) }
                        .help("Open \(url.absoluteString) (Command-O)")
                }
            }
        }
    }
}

struct InsightActions: View {
    @Environment(AppModel.self) private var model
    let insight: LogInsight
    let name: String

    var body: some View {
        switch insight.id {
        case ContainerInsights.exitID, ContainerInsights.oomID:
            Button("Start") { model.request(.start, on: name) }
                .disabled(!model.canPerform(.start, on: model.containers.first { $0.name == name }))
        case ContainerInsights.healthID, ContainerInsights.restartID:
            Button("Restart") { model.request(.restart, on: name) }
                .disabled(!model.canPerform(.restart, on: model.containers.first { $0.name == name }))
        default:
            EmptyView()
        }
    }
}

// MARK: Usage

/// CPU and memory now, with the last two minutes as a sparkline, in the log's header.
struct UsageView: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        if let history = model.stats[name], let cpu = history.cpu.last, let memory = history.memory.last,
           model.containers.first(where: { $0.name == name })?.isRunning == true {
            HStack(spacing: Space.lg) {
                metric(label: "CPU", value: Format.percent(cpu), values: history.cpu,
                       help: "CPU over the last \(Format.window(history.cpu.count)): now \(Format.percent(cpu)), peak \(Format.percent(history.cpu.max() ?? 0)). 100% is one full core.")
                metric(label: "Memory", value: Format.bytes(memory), values: history.memory,
                       help: "Memory over the last \(Format.window(history.memory.count)): now \(Format.bytes(memory)), peak \(Format.bytes(history.memory.max() ?? 0)) of \(Format.bytes(history.memoryLimit)).")
            }
        }
    }

    private func metric(label: String, value: String, values: [Double], help: String) -> some View {
        HStack(spacing: Space.xs) {
            Sparkline(values: values)
                .frame(width: 56, height: 16)
            Text("\(value) \(Text(label).foregroundStyle(.secondary))")
                .font(.callout.monospacedDigit())
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
    }
}

/// One series, no axes: the shape of the last minutes, scaled to its own peak.
struct Sparkline: View {
    let values: [Double]

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let top = max(values.max() ?? 0, 0.000_1)
            let step = size.width / CGFloat(values.count - 1)
            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: CGFloat(index) * step,
                                    y: size.height - 1 - CGFloat(value / top) * (size.height - 2))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .style(.tint.opacity(0.15)))
            context.stroke(line, with: .style(.tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

enum Format {
    static func percent(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f%%", value) : String(format: "%.0f%%", value)
    }

    static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    /// Samples arrive every two seconds.
    static func window(_ count: Int) -> String {
        let seconds = count * 2
        return seconds < 120 ? "\(seconds) seconds" : "\(seconds / 60) minutes"
    }
}
