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
            case .alerts: AlertSettingsForm()
            case .ignored: IgnoredSettingsForm()
            case .appearance:
                AppearanceSettings()
                MenuBarSettings()
            }
        }
        .formStyle(.grouped)
        .fitsContent()
        .frame(width: 520)
    }
}

/// The Settings tabs. Snapshot mode walks through every case.
enum SettingsTab: String, CaseIterable, Identifiable {
    case server, alerts, ignored, appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .server: "Server"
        case .alerts: "Alerts"
        case .ignored: "Ignored"
        case .appearance: "Appearance"
        }
    }

    var symbol: String {
        switch self {
        case .server: "server.rack"
        case .alerts: "bell.badge"
        case .ignored: "eye.slash"
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

struct AlertSettingsForm: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Notifier.Keys.crashes) private var crashes = true
    @AppStorage(Notifier.Keys.newErrors) private var newErrors = true
    @AppStorage(Notifier.Keys.gotify) private var gotify = false
    @AppStorage(Notifier.Keys.gotifyURL) private var gotifyURL = Notifier.Keys.defaultGotifyURL
    @State private var token = ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Section {
            Toggle("Crashes, out of memory, unhealthy, restart loops", isOn: $crashes)
            Toggle("New errors in a container's log", isOn: $newErrors)
                .help("Checked at every scan, about every 5 minutes")
        } header: {
            Text("Tell Me About")
        } footer: {
            Text("The same alert comes at most every 15 minutes. Click a notification to see the container's log.")
                .foregroundStyle(.secondary)
        }
        Section {
            Toggle("Also send to Gotify", isOn: $gotify)
            TextField("Gotify address", text: $gotifyURL, prompt: Text(Notifier.Keys.defaultGotifyURL))
                .help("As the server sees it. Porthole sends from the server with curl.")
                .disabled(!gotify)
            SecureField("App token", text: $token, prompt: Text("From Gotify > Apps"))
                .onSubmit { Keychain.gotifyToken = token }
                .onChange(of: token) { Keychain.gotifyToken = token }
                .disabled(!gotify)
            HStack {
                if let testResult {
                    Label(testResult, systemImage: testResult == "Sent." ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(testResult == "Sent." ? .green : .red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Send Test") {
                    testing = true
                    Task {
                        testResult = await model.notifier.testGotify(url: gotifyURL, token: token) ?? "Sent."
                        testing = false
                    }
                }
                .disabled(!gotify || token.isEmpty || testing)
            }
        } header: {
            Text("Phone")
        } footer: {
            Text("The token stays in your keychain.").foregroundStyle(.secondary)
        }
        .onAppear { if !Store.isOverridden { token = Keychain.gotifyToken ?? "" } }
    }
}

struct IgnoredSettingsForm: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            if model.ignoreRules.rules.isEmpty {
                Text("Nothing ignored. In a log, select a line and choose Ignore Messages Like This.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.ignoreRules.rules) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(rule.text).lineLimit(2)
                            Text(rule.container ?? "Every container").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") { model.removeIgnore(rule) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Count these messages as problems again")
                    }
                }
            }
        } header: {
            Text("Ignored Messages")
        } footer: {
            Text("Ignored lines still show in the log, as debug lines, but never count as warnings or errors or send alerts.")
                .foregroundStyle(.secondary)
        }
    }
}

struct MenuBarSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            Toggle("Show Porthole in the menu bar", isOn: $model.showInMenuBar)
        } footer: {
            Text("With the menu bar icon on, Porthole keeps watching after you close its window.")
                .foregroundStyle(.secondary)
        }
    }
}
