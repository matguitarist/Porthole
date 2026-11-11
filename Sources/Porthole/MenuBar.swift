import AppKit
import PortholeKit
import SwiftUI

/// The menu bar icon: a glance at the server without opening the window.
enum MenuBarStatus {
    static let showKey = "menuBar.show"
    static var isShown: Bool { UserDefaults.standard.object(forKey: showKey) as? Bool ?? true }

    /// The icon says how the server is: fine, problems, or not connected.
    static func symbol(_ model: AppModel) -> String {
        switch model.connection {
        case .connecting: "shippingbox"
        case .failed: "shippingbox.and.arrow.backward"
        case .connected:
            !model.containersNeedingAttention.isEmpty ? "exclamationmark.triangle.fill"
                : model.containersWithProblems.contains { $0.summary.errors > 0 } ? "shippingbox.fill" : "shippingbox"
        }
    }
}

struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            header
            Divider()
            switch model.connection {
            case .connecting:
                ProgressView("Connecting…").frame(maxWidth: .infinity)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(3)
            case .connected:
                load
                attention
                problems
            }
            Divider()
            HStack {
                Button("Scan Now", systemImage: "arrow.clockwise") { Task { await model.scanProblems() } }
                    .disabled(model.scanningProblems)
                Spacer()
                Button("Open Porthole") { show(nil) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.lg)
        .frame(width: 340)
        .noInitialFocus()
    }

    private var header: some View {
        HStack {
            Text(model.hostInfo?.hostname ?? ServerSettings.host).font(.headline)
            Spacer()
            let running = model.containers.filter(\.isRunning).count
            Text("\(running) of \(model.containers.count) running").foregroundStyle(.secondary)
        }
    }

    private var load: some View {
        let load = model.hostLoad
        return HStack(spacing: Space.lg) {
            LabeledValue(title: "CPU", value: load.cpu.last.map(Format.percent) ?? "—")
            LabeledValue(title: "Memory", value: load.memoryUsed.last.map(Format.bytes) ?? "—")
            LabeledValue(title: "Load", value: load.load.first.map { String(format: "%.2f", $0) } ?? "—")
        }
    }

    @ViewBuilder
    private var attention: some View {
        let needing = model.containersNeedingAttention
        if !needing.isEmpty {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Needs a Look").font(.subheadline).foregroundStyle(.secondary)
                ForEach(needing) { container in
                    row(container.name, detail: container.status, symbol: "exclamationmark.triangle.fill", color: .orange)
                }
            }
        }
    }

    @ViewBuilder
    private var problems: some View {
        let list = model.containersWithProblems.prefix(6)
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Last 24 Hours").font(.subheadline).foregroundStyle(.secondary)
            if list.isEmpty {
                Label("No warnings or errors", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            ForEach(Array(list), id: \.container.name) { item in
                let errors = item.summary.errors > 0
                row(item.container.name,
                    detail: Self.counts(item.summary),
                    symbol: errors ? "xmark.octagon.fill" : "exclamationmark.triangle.fill",
                    color: errors ? .red : .orange, problemsOnly: true)
            }
        }
    }

    static func counts(_ summary: ProblemSummary) -> String {
        func count(_ n: Int, _ word: String) -> String { "\(n)\(summary.capped ? "+" : "") \(word)\(n == 1 ? "" : "s")" }
        return [summary.errors > 0 ? count(summary.errors, "error") : nil,
                summary.warnings > 0 ? count(summary.warnings, "warning") : nil].compactMap(\.self).joined(separator: ", ")
    }

    private func row(_ name: String, detail: String, symbol: String, color: Color, problemsOnly: Bool = false) -> some View {
        Button { show(name, problemsOnly: problemsOnly) } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: symbol).foregroundStyle(color).frame(width: 16)
                Text(name).lineLimit(1)
                Spacer(minLength: Space.sm)
                Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Show \(name)'s log")
    }

    private func show(_ name: String?, problemsOnly: Bool = false) {
        if let name { model.open(name, problemsOnly: problemsOnly) } else { model.page = .overview }
        openWindow(id: "main")
        NSApp.activate()
    }
}

private struct LabeledValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
        }
    }
}
