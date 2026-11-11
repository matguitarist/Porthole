import PortholeKit
import SwiftUI

/// The Settings window (Command-Comma). One tab per topic. Each tab is a
/// grouped Form that sizes to its content.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                page(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .noInitialFocus()
    }

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        Form {
            switch tab {
            case .server: ServerSettingsForm()
            case .appearance: AppearanceSettings()
            }
        }
        .formStyle(.grouped)
        .fitsContent()
        .frame(width: 520)
    }
}

/// The Settings tabs. Snapshot mode walks through every case.
enum SettingsTab: String, CaseIterable, Identifiable {
    case server, appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .server: "Server"
        case .appearance: "Appearance"
        }
    }

    var symbol: String {
        switch self {
        case .server: "server.rack"
        case .appearance: "paintpalette"
        }
    }
}

struct ServerSettingsForm: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ServerSettings.targetKey) private var target = ServerSettings.defaultTarget
    @AppStorage(ServerSettings.keyFileKey) private var keyFile = ServerSettings.defaultKeyFile
    @AppStorage(ServerSettings.tailKey) private var tail = 1000
    @State private var test: TestResult?

    enum TestResult: Equatable {
        case testing
        case ok(Int)
        case failed(String)
    }

    var body: some View {
        Section {
            TextField("SSH address", text: $target, prompt: Text(ServerSettings.defaultTarget))
                .help("user@host, or a Host from ~/.ssh/config. Porthole runs the docker command there.")
            HStack {
                TextField("Key file", text: $keyFile, prompt: Text("ssh's default"))
                Button("Choose…") { chooseKey() }
            }
            Picker("Lines to load", selection: $tail) {
                Text("500").tag(500)
                Text("1,000").tag(1000)
                Text("5,000").tag(5000)
                Text("20,000").tag(20_000)
            }
            .help("How many earlier lines Porthole loads when you pick a container")
        } header: {
            Text("Docker Server")
        } footer: {
            Text("Porthole connects with SSH and the docker command. Nothing is installed on the server.")
                .foregroundStyle(.secondary)
        }
        Section {
            HStack {
                status
                Spacer()
                Button("Test Connection") { Task { await runTest() } }
                    .disabled(test == .testing)
                Button("Reconnect") { model.reconnect() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch test {
        case .testing: ProgressView().controlSize(.small)
        case .ok(let count): Label("Connected: \(count) containers", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message): Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(3)
        case nil: EmptyView()
        }
    }

    private func runTest() async {
        test = .testing
        let client: any DockerClient = Store.isOverridden ? DemoDocker() : SSHDocker(target: target, identityFile: keyFile)
        do {
            test = .ok(try await client.containers().count)
        } catch {
            test = .failed(error.localizedDescription)
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL.homeDirectory.appending(path: ".ssh")
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            keyFile = url.path(percentEncoded: false).replacingOccurrences(of: URL.homeDirectory.path(percentEncoded: false), with: "~/")
        }
    }
}
