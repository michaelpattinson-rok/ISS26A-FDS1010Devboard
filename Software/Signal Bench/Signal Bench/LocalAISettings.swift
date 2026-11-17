import Combine
import SwiftUI

@MainActor final class LocalAISettings: ObservableObject {
    @Published var enabled = false
    @Published var endpoint = LMStudioClient.defaultEndpoint {
        didSet { if endpoint != oldValue { cancelDiscovery(); models = []; connectionVerified = false; status = nil } }
    }
    @Published var model = "" {
        didSet { if model != oldValue, !checking { status = nil } }
    }
    @Published private(set) var models: [String] = []
    @Published private(set) var status: String?
    @Published private(set) var checking = false
    @Published private(set) var connectionVerified = false
    var ready: Bool { enabled && connectionVerified && models.contains(model) }
    private var discovery: Task<Void, Never>?
    private var generation = UUID()

    private struct Connection: Codable {
        var version = 1
        let endpoint: String
        let model: String
    }

    func restore(_ project: StreamProjectStore?) {
        cancelDiscovery()
        endpoint = LMStudioClient.defaultEndpoint
        models = []
        connectionVerified = false
        model = ""
        status = nil
        guard let project else { return }
        do {
            try project.verify()
            let file = project.folder.appendingPathComponent("local-ai.json")
            guard try StreamFiles.isPresent(file) else { return }
            let value = try StreamFiles.decoder.decode(Connection.self, from: StreamFiles.read(file, limit: 4096))
            guard value.version == 1, value.model.utf8.count <= 512 else { throw ReviewWorkerError.unsupported }
            let client = try LMStudioClient(value.endpoint)
            client.session.invalidateAndCancel()
            endpoint = value.endpoint
            model = value.model
        } catch { status = error.localizedDescription }
    }

    func remember(_ project: StreamProjectStore) {
        do {
            let client = try LMStudioClient(endpoint)
            client.session.invalidateAndCancel()
            try project.verify()
            let file = project.folder.appendingPathComponent("local-ai.json")
            let replace = try StreamFiles.isPresent(file)
            try StreamFiles.publish(Connection(endpoint: endpoint, model: model), at: file, replace: replace)
            status = "Connection settings saved in this Project."
        } catch { status = error.localizedDescription }
    }

    func check() {
        cancelDiscovery()
        let address = endpoint
        let attempt = UUID()
        generation = attempt
        checking = true
        connectionVerified = false
        status = "Checking LM Studio…"
        discovery = Task { [weak self] in
            do {
                let client = try LMStudioClient(address)
                defer { client.session.invalidateAndCancel() }
                let served = try await client.models()
                guard let self, !Task.isCancelled, self.generation == attempt else { return }
                self.models = served
                self.connectionVerified = true
                if served.isEmpty {
                    self.status = "LM Studio is running. Load a model, then check again."
                } else if !self.model.isEmpty && !served.contains(self.model) {
                    self.status = "The previous model is unavailable. Choose a served model."
                } else {
                    self.status = nil
                    if self.model.isEmpty, served.count == 1 { self.model = served[0] }
                }
                self.checking = false
            } catch {
                guard let self, !Task.isCancelled, self.generation == attempt else { return }
                self.models = []
                if let urlError = error as? URLError, [.cannotConnectToHost, .timedOut, .networkConnectionLost].contains(urlError.code) {
                    self.status = "LM Studio did not respond. Start its local server, then check again."
                } else {
                    self.status = error.localizedDescription
                }
                self.checking = false
            }
        }
    }

    func testTools() {
        cancelDiscovery()
        guard ready else { return }
        let address = endpoint, selected = model, attempt = UUID()
        generation = attempt
        checking = true
        status = "Testing tool calling…"
        discovery = Task { [weak self] in
            do {
                let client = try LMStudioClient(address)
                defer { client.session.invalidateAndCancel() }
                try await client.testTools(model: selected)
                guard let self, !Task.isCancelled, self.generation == attempt else { return }
                self.status = "The selected model requested the test tool."
                self.checking = false
            } catch {
                guard let self, !Task.isCancelled, self.generation == attempt else { return }
                self.status = error.localizedDescription
                self.checking = false
            }
        }
    }

    func cancelDiscovery() {
        if checking { status = nil }
        discovery?.cancel()
        discovery = nil
        generation = UUID()
        checking = false
    }
}

struct LocalAISettingsView: View {
    @ObservedObject var settings: LocalAISettings
    let project: StreamProjectStore?

    private var connectionLabel: String {
        guard settings.connectionVerified else { return "Check the connection to find available models." }
        return settings.model.isEmpty ? "Connected. Choose a model." : "Connected to LM Studio."
    }

    private var connectionButton: some View {
        Button(settings.connectionVerified ? "Check Again" : "Check Connection") { settings.check() }
            .disabled(!settings.enabled || settings.checking)
    }

    var body: some View {
        Form {
            Section("Local AI") {
                Toggle("Enable Local AI", isOn: $settings.enabled)
                Text("Use LM Studio on this Mac to review saved recordings. Signal Bench sends the prompt and selected tool results when you start a review.")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("Endpoint", text: $settings.endpoint)
                    .disabled(!settings.enabled || settings.checking)
                Picker("Model", selection: $settings.model) {
                    Text("Choose a model").tag("")
                    if !settings.model.isEmpty && !settings.models.contains(settings.model) {
                        Text(settings.model).tag(settings.model)
                    }
                    ForEach(settings.models, id: \.self) { Text($0).tag($0) }
                }.disabled(!settings.enabled || settings.checking || settings.models.isEmpty)
                if settings.enabled {
                    Label(settings.status ?? connectionLabel,
                          systemImage: settings.connectionVerified ? "checkmark.circle" : "info.circle")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    if settings.connectionVerified { connectionButton }
                    else { connectionButton.buttonStyle(.borderedProminent) }
                    if settings.checking {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { settings.cancelDiscovery() }
                    }
                    Button("Test Tool Calling") { settings.testTools() }
                        .disabled(!settings.ready || settings.checking)
                    if let project {
                        Button("Remember in Project") { settings.remember(project) }
                            .disabled(!settings.ready || settings.checking)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540).frame(minHeight: 270)
        .onChange(of: settings.enabled) { _, enabled in if !enabled { settings.cancelDiscovery() } }
    }
}
