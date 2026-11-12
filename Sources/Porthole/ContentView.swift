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
        .confirmationDialog(Text("Clear the log of \(model.confirmClear?.title ?? "")?"), isPresented: Binding(
            get: { model.confirmClear != nil }, set: { if !$0 { model.confirmClear = nil } })) {
            Button("Clear on Server", role: .destructive) {
                if let request = model.confirmClear { Task { await model.clearLogs(request.names) } }
                model.confirmClear = nil
            }
        } message: {
            Text("Porthole empties the log files on the server. A running container stops for a moment and starts again, so Docker keeps reading its log. Everything logged so far is gone for good, here, in Dozzle and in docker logs.")
        }
        .sheet(item: $model.ignoreDraft) { draft in
            IgnoreSheet(draft: draft)
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
        List(selection: $model.page) {
            if model.connection == .connected || !model.containers.isEmpty {
                Label("Overview", systemImage: "gauge.with.dots.needle.33percent")
                    .badge(model.containersWithProblems.filter { $0.summary.errors > 0 }.count)
                    .tag(Page.overview)
            }
            if model.search.isEmpty, !model.stacks.isEmpty {
                Section("Stacks") {
                    ForEach(model.stacks.keys.sorted(), id: \.self) { project in
                        StackRow(project: project, containers: model.stacks[project] ?? []).tag(Page.stack(project))
                    }
                }
            }
            if !model.running.isEmpty {
                Section("Running") {
                    ForEach(model.running) { ContainerRow(container: $0).tag(Page.container($0.name)) }
                }
            }
            if !model.stopped.isEmpty {
                Section("Stopped") {
                    ForEach(model.stopped) { ContainerRow(container: $0).tag(Page.container($0.name)) }
                }
            }
        }
        .searchable(text: $model.search, placement: .sidebar, prompt: "Filter")
        .overlay { overlay }
        .contextMenu(forSelectionType: Page.self) { pages in
            if case .container(let name) = pages.first, let container = model.containers.first(where: { $0.name == name }) {
                ContainerActions(container: container)
            } else if case .stack(let project) = pages.first {
                Button("Clear Logs on Server…", systemImage: "trash") { model.requestClearLogs(model.stacks[project]?.map(\.name) ?? []) }
            }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch model.connection {
        case .connecting where model.containers.isEmpty:
            ProgressView("Connecting to \(ServerSettings.host)…")
                .controlSize(.small)
        case .failed where ServerSettings.target.isEmpty && !Store.isOverridden:
            ContentUnavailableView {
                Label("Set Up Your Server", systemImage: "server.rack")
            } description: {
                Text("Enter your Docker server's SSH address in Settings › Server. Porthole runs the docker command there.")
            } actions: {
                Button("Settings…") { openSettings() }
            }
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

/// The container's own icon (its label, Unraid template, or Porthole's list on the server), or a box.
struct ContainerIcon: View {
    @Environment(AppModel.self) private var model
    let container: Container
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let image = model.iconImage(for: container) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
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
        if container.state == "restarting" { return ("arrow.clockwise.circle.fill", .orange, String(localized: "Restarting")) }
        if container.state == "paused" { return ("pause.circle.fill", .secondary, String(localized: "Paused")) }
        if container.isRunning {
            switch container.health {
            case "unhealthy": return ("exclamationmark.triangle.fill", .orange, String(localized: "Running, unhealthy"))
            case "starting": return ("circle.dotted", .green, String(localized: "Running, health check starting"))
            default: return ("circle.fill", .green, container.health == "healthy" ? String(localized: "Running, healthy") : String(localized: "Running"))
            }
        }
        if let code = container.exitCode, code != 0, code != 143 {
            return ("xmark.circle.fill", .red, String(localized: "Stopped with exit code \(code)"))
        }
        return ("stop.circle", .secondary, String(localized: "status.stopped", defaultValue: "Stopped"))
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
        Divider()
        Button("Clear Log on Server…", systemImage: "trash") { model.requestClearLogs([container.name]) }
    }
}

// MARK: Detail

struct ContainerDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.page == .overview {
            OverviewView()
        } else if case .stack(let project) = model.page {
            let log = model.stackLog(project)
            LogViewer(model: log.viewer, options: LogViewerOptions(
                emptyTitle: String(localized: "No Messages"), emptyMessage: String(localized: "The containers of \(project) haven't logged anything yet."),
                entryInspector: { selected, _ in AnyView(EntryInspector(entries: selected, container: nil, stack: log)) },
                sourceColor: { _ in Palette.accentText }))
                .id(log.key)
                .navigationTitle(project)
                .navigationSubtitle("\(log.names.count) containers")
                .toolbar {
                    ToolbarItem {
                        Button("Clear Logs on Server…", systemImage: "trash") { model.requestClearLogs(log.names) }
                            .help("Empty these containers' log files on the server")
                    }
                }
        } else if let name = model.selection {
            let log = model.log(for: name)
            LogViewer(model: log.viewer, options: options(for: name, log: log))
                .id(name)
                .navigationTitle(name)
                .navigationSubtitle(model.selected?.image ?? "")
                .toolbar { toolbar }
        } else {
            ContentUnavailableView("No Container Selected", systemImage: "shippingbox",
                                   description: Text("Pick a container to see its log."))
        }
    }

    private func options(for name: String, log: ContainerLog) -> LogViewerOptions {
        LogViewerOptions(
            emptyTitle: String(localized: "No Messages"),
            emptyMessage: String(localized: "\(name) hasn't logged anything yet."),
            insightsTitle: String(localized: "What Docker is telling you"),
            insightActions: { insight in
                AnyView(InsightActions(insight: insight, name: name))
            },
            banner: { _ in AnyView(WindowBanner(log: log)) },
            headerAccessory: { AnyView(UsageView(name: name)) },
            entryInspector: { selected, _ in AnyView(EntryInspector(entries: selected, container: name, stack: nil)) },
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
                Button("Clear Log on Server…", systemImage: "trash") { model.requestClearLogs([container.name]) }
                    .help("Empty \(container.name)'s log file on the server")
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
                metric(label: String(localized: "CPU"), value: Format.percent(cpu), values: history.cpu,
                       help: String(localized: "CPU over the last \(Format.window(history.cpu.count)): now \(Format.percent(cpu)), peak \(Format.percent(history.cpu.max() ?? 0)). 100% is one full core."))
                metric(label: String(localized: "Memory"), value: Format.bytes(memory), values: history.memory,
                       help: String(localized: "Memory over the last \(Format.window(history.memory.count)): now \(Format.bytes(memory)), peak \(Format.bytes(history.memory.max() ?? 0)) of \(Format.bytes(history.memoryLimit))."))
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
        return seconds < 120 ? String(localized: "\(seconds) seconds") : String(localized: "\(seconds / 60) minutes")
    }
}

// MARK: Stacks, windows, ignoring

struct StackRow: View {
    let project: String
    let containers: [Container]

    var body: some View {
        let running = containers.filter(\.isRunning).count
        HStack(spacing: Space.sm) {
            if let first = containers.first { ContainerIcon(container: first) }
            VStack(alignment: .leading, spacing: 0) {
                Text(project).lineLimit(1)
                Text("\(running) of \(containers.count) running")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .help("The merged log of \(containers.map(\.name).joined(separator: ", "))")
    }
}

/// Above the log when it holds a day's window instead of the last lines.
struct WindowBanner: View {
    @Environment(AppModel.self) private var model
    let log: ContainerLog

    var body: some View {
        if let since = log.loadedSince {
            HStack(spacing: Space.sm) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                Text("Everything since \(since.formatted(date: .abbreviated, time: .shortened)).")
                Spacer()
                Button("Show Latest Lines") { model.loadLatest(log) }
            }
            .font(.callout)
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
        }
    }
}

/// The selected messages, and "Ignore Messages Like This".
struct EntryInspector: View {
    @Environment(AppModel.self) private var model
    let entries: [LogEntry]
    /// The container, or nil in a stack (then the entry's source names it).
    let container: String?
    let stack: ContainerLog?

    var body: some View {
        if let entry = entries.last {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    Label(entry.displayCode, systemImage: entry.level.symbol)
                        .foregroundStyle(entry.level.color)
                        .font(.headline)
                    Text(entry.message).textSelection(.enabled)
                    if let detail = entry.detail {
                        Text(detail).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if entries.count > 1 {
                        Text("\(entries.count) messages selected").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    Button("Ignore Messages Like This…", systemImage: "eye.slash") {
                        model.ignoreDraft = IgnoreDraft(container: containerName(entry), message: entry.message)
                    }
                    Text("They stop counting as problems in the overview and in alerts, and show dimmed here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("No Message Selected", systemImage: "text.alignleft",
                                   description: Text("Select a message to see it whole, or to ignore messages like it."))
        }
    }

    private func containerName(_ entry: LogEntry) -> String? {
        if let container { return container }
        // In a stack, the source is the short name: find the container it stands for.
        return stack?.names.first { Stacks.shortName($0, in: stack?.names ?? []) == entry.source }
    }
}

/// A rule waiting for the person to confirm its text.
struct IgnoreDraft: Identifiable {
    var container: String?
    var message: String
    var id: String { "\(container ?? "*")|\(message)" }
}

struct IgnoreSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let draft: IgnoreDraft
    @State private var text = ""
    @State private var everywhere = false

    var body: some View {
        Form {
            Section {
                TextField("Messages containing", text: $text, axis: .vertical)
                    .lineLimit(2...4)
                if let container = draft.container {
                    Picker("In", selection: $everywhere) {
                        Text(container).tag(false)
                        Text("Every container").tag(true)
                    }
                }
            } header: {
                Text("Ignore Messages Like This")
            } footer: {
                Text("Matching ignores upper and lower case. Keep only the part that stays the same, so the rule catches every copy of the message. Settings > Ignored lists the rules.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fitsContent()
        .frame(width: 480)
        .noInitialFocus()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Ignore") {
                    model.ignore(IgnoreRules.Rule(container: everywhere ? nil : draft.container, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
                    dismiss()
                }
                .disabled(text.trimmingCharacters(in: .whitespaces).count < 3)
            }
        }
        .onAppear { text = IgnoreRules.suggestedText(for: draft.message); everywhere = draft.container == nil }
    }
}
