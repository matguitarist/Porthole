import PortholeKit
import ServiceManagement
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
            case .general: GeneralSettingsForm()
            case .server: ServerSettingsForm()
            case .alerts: AlertSettingsForm()
            case .ignored: IgnoredSettingsForm()
            case .appearance: AppearanceSettings()
            case .updates: UpdateSettingsForm()
            }
        }
        .formStyle(.grouped)
        .fitsContent()
        .frame(width: 520)
    }
}

/// The Settings tabs. Snapshot mode walks through every case.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, server, alerts, ignored, appearance, updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .server: String(localized: "Server")
        case .alerts: String(localized: "Alerts")
        case .ignored: String(localized: "Ignored")
        case .appearance: String(localized: "Appearance")
        case .updates: String(localized: "Updates")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .server: "server.rack"
        case .alerts: "bell.badge"
        case .ignored: "eye.slash"
        case .appearance: "paintpalette"
        case .updates: "arrow.down.circle"
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
                .help("Checked at every scan (Settings > General)")
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
                    Label(testResult, systemImage: testResult == String(localized: "Sent.") ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(testResult == String(localized: "Sent.") ? .green : .red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Send Test") {
                    testing = true
                    Task {
                        testResult = await model.notifier.testGotify(url: gotifyURL, token: token) ?? String(localized: "Sent.")
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

struct GeneralSettingsForm: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.scanIntervalKey) private var scanMinutes = 5
    @State private var opensAtLogin = LoginItem.isOn
    @State private var loginError: String?

    var body: some View {
        @Bindable var model = model
        Section {
            Toggle("Open Porthole when you log in", isOn: $opensAtLogin)
                .onChange(of: opensAtLogin) { loginError = LoginItem.set(opensAtLogin) }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
            Toggle("Show Porthole in the menu bar", isOn: $model.showInMenuBar)
                .help("A status icon with the server's load and what needs a look")
        } header: {
            Text("Startup")
        } footer: {
            Text("With the menu bar icon on, Porthole keeps watching after you close its window.")
                .foregroundStyle(.secondary)
        }
        Section {
            Picker("Scan logs for problems", selection: $scanMinutes) {
                Text("Every minute").tag(1)
                Text("Every 5 minutes").tag(5)
                Text("Every 15 minutes").tag(15)
                Text("Every hour").tag(60)
            }
            .help("How often Porthole reads the last day's warnings and errors, for the overview and new-error alerts")
        } header: {
            Text("Watching")
        }
    }
}

struct UpdateSettingsForm: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("Automatic Updates") {
            Toggle(isOn: $model.checksForUpdates) {
                Text("Check for updates automatically")
                Text(note)
            }
            .disabled(!Updater.shared.isAvailable)
            LabeledContent("Version \(Links.version)") {
                Button("Check Now") { Updater.shared.checkForUpdates() }
                    .disabled(!Updater.shared.isAvailable)
            }
        }
    }

    private var note: String {
        guard Updater.shared.isAvailable else { return String(localized: "Updates are off in this build.") }
        guard let last = Updater.shared.lastCheck else { return String(localized: "Looks once a day for a new version on GitHub.") }
        return String(localized: "Looks once a day for a new version on GitHub. Last checked \(last.formatted(.relative(presentation: .named))).")
    }
}

/// Open at login, through the system's login items (System Settings > General > Login Items).
enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns an error to show, or nil.
    static func set(_ on: Bool) -> String? {
        guard !Store.isOverridden else { return nil }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
