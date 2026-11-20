import Combine
import SwiftUI

@MainActor final class LocalAISettings: ObservableObject {
    @Published var enabled = false
    @Published var endpoint = LMStudioClient.defaultEndpoint {
        didSet { if endpoint != oldValue { cancelDiscovery(); models = []; options = [:]; rejected = [:]; preferences = [:]; verified = nil; imagesVerified = false; connectionVerified = false; status = nil } }
    }
    @Published var model = "" {
        didSet { if model != oldValue { verified = nil; imagesVerified = false; if !checking { status = nil } } }
    }
    @Published private(set) var models: [String] = []
    @Published private(set) var status: String?
    @Published private(set) var checking = false
    @Published private(set) var connectionVerified = false
    @Published private(set) var visionModels: Set<String> = []
    @Published private(set) var imagesVerified = false
    typealias Reasoning = LMStudioClient.Reasoning
    @Published private(set) var options: [String: [Reasoning]] = [:]
    @Published private var preferences: [String: Reasoning] = [:]
    @Published private var verified: String?
    @Published private var rejected: [String: Set<Reasoning>] = [:]
    var reasoningChoices: [Reasoning] {
        [.modelDefault] + (options[model] ?? []).filter { rejected[model]?.contains($0) != true }
    }
    var reasoning: Reasoning {
        get {
            let preferred = preferences[model] ?? .modelDefault
            return reasoningChoices.contains(preferred) ? preferred : .modelDefault
        }
        set {
            guard !model.isEmpty, reasoningChoices.contains(newValue),
                  preferences[model] != nil || preferences.count < 128 else { return }
            preferences[model] = newValue
            verified = nil
            imagesVerified = false
            status = nil
        }
    }
    var discovered: Bool { enabled && connectionVerified && models.contains(model) }
    var ready: Bool { discovered && verified == model }
    var allowImages: Bool { ready && imagesVerified }
    private var discovery: Task<Void, Never>?
    private var generation = UUID()

    private struct Connection: Codable {
        var version = 1
        let endpoint: String
        let model: String
        var reasoning: [String: Reasoning]?
    }

    func restore(_ project: StreamProjectStore?) {
        cancelDiscovery()
        endpoint = LMStudioClient.defaultEndpoint
        models = []
        options = [:]
        rejected = [:]
        preferences = [:]
        verified = nil
        imagesVerified = false
        connectionVerified = false
        model = ""
        status = nil
        guard let project else { return }
        do {
            try project.verify()
            let file = project.folder.appendingPathComponent("local-ai.json")
            guard try StreamFiles.isPresent(file) else { return }
            let value = try StreamFiles.decoder.decode(Connection.self, from: StreamFiles.read(file, limit: 65_536))
            guard [1, 2].contains(value.version), value.model.utf8.count <= 512,
                  (value.reasoning?.count ?? 0) <= 128 else { throw ReviewWorkerError.unsupported }
            let client = try LMStudioClient(value.endpoint)
            client.session.invalidateAndCancel()
            endpoint = value.endpoint
            model = value.model
            preferences = value.reasoning ?? [:]
        } catch { status = error.localizedDescription }
    }

    func remember(_ project: StreamProjectStore) {
        do {
            let client = try LMStudioClient(endpoint)
            client.session.invalidateAndCancel()
            try project.verify()
            let file = project.folder.appendingPathComponent("local-ai.json")
            let replace = try StreamFiles.isPresent(file)
            try StreamFiles.publish(Connection(version: 2, endpoint: endpoint, model: model, reasoning: preferences), at: file, replace: replace)
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
        verified = nil
        imagesVerified = false
        status = "Checking LM Studio…"
        discovery = Task { [weak self] in
            do {
                let client = try LMStudioClient(address)
                defer { client.session.invalidateAndCancel() }
                let catalog = try await client.catalog()
                let served = catalog.ids
                guard let self, !Task.isCancelled, self.generation == attempt else { return }
                self.models = served
                self.visionModels = catalog.vision
                self.options = catalog.reasoning
                self.rejected = [:]
                self.connectionVerified = true
                if served.isEmpty {
                    self.status = "LM Studio is running. Load a model, then check again."
                } else if !self.model.isEmpty && !served.contains(self.model) {
                    self.status = "The previous model is unavailable. Choose a served model."
                } else {
                    if self.model.isEmpty, served.count == 1 { self.model = served[0] }
                    self.status = self.preferences[self.model].map { $0 != .modelDefault && !self.reasoningChoices.contains($0) } == true
                        ? "The saved reasoning setting is unavailable. This model is set to Model Default." : nil
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
        guard discovered else { return }
        let address = endpoint, selected = model, effort = reasoning, attempt = UUID()
        verified = nil
        imagesVerified = false
        generation = attempt
        checking = true
        status = "Testing tool calling…"
        discovery = Task { [weak self] in
            do {
                let client = try LMStudioClient(address)
                defer { client.session.invalidateAndCancel() }
                try await client.testTools(model: selected, reasoning: effort)
                guard let self, !Task.isCancelled, self.generation == attempt else { return }
                self.verified = selected
                self.status = "Tool Calling Verified · \(effort.title)"
                self.checking = false
            } catch {
                guard let self, !Task.isCancelled, self.generation == attempt else { return }
                if effort != .modelDefault,
                   [400, 404, 405, 422, 501].contains(where: { error.localizedDescription.contains("HTTP \($0) for /\(effort.route)") }) {
                    self.rejected[selected, default: []].insert(effort)
                    self.preferences[selected] = .modelDefault
                }
                self.status = effort == .modelDefault ? error.localizedDescription :
                    "This reasoning setting did not pass the tool test. \(error.localizedDescription) Try Model Default."
                self.checking = false
            }
        }
    }

    func testImages() {
        guard ready, !checking else { return }
        cancelDiscovery()
        let address = endpoint, selected = model, effort = reasoning, attempt = UUID()
        imagesVerified = false
        generation = attempt
        checking = true
        status = "Testing waveform images…"
        discovery = Task { [weak self] in
            do {
                let client = try LMStudioClient(address)
                defer { client.session.invalidateAndCancel() }
                try await client.testImages(model: selected, reasoning: effort)
                guard let self, !Task.isCancelled, self.generation == attempt else { return }
                self.imagesVerified = true
                self.status = "Waveform images and tool calling verified."
                self.checking = false
            } catch {
                guard let self, !Task.isCancelled, self.generation == attempt else { return }
                self.status = "Waveform image test failed. Numeric review is available. \(error.localizedDescription)"
                self.checking = false
            }
        }
    }

    func disableImages() { imagesVerified = false }

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
        return settings.discovered ? "Discovered. Test tool calling before starting a review." : "Connected. Choose a served model."
    }

    private var connectionButton: some View {
        Button(settings.connectionVerified ? "Refresh Models" : "Check Connection") { settings.check() }
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
                if settings.discovered {
                    Picker("Reasoning", selection: $settings.reasoning) {
                        ForEach(settings.reasoningChoices, id: \.self) { Text($0.title).tag($0) }
                    }.disabled(settings.checking)
                    if settings.reasoningChoices.count == 1 {
                        Text("This connection offers Model Default for app tools.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if settings.enabled {
                    Label(settings.status ?? connectionLabel,
                          systemImage: settings.ready ? "checkmark.circle" : "info.circle")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if settings.ready {
                    LabeledContent("Waveform Images") {
                        if settings.allowImages {
                            Button("Disable Images") { settings.disableImages() }
                        } else {
                            Button("Test and Enable") { settings.testImages() }.disabled(settings.checking)
                        }
                    }
                    Text(settings.allowImages ? "An approved review may send one waveform image to this model." :
                        settings.visionModels.contains(settings.model) ?
                        "Test this model with a synthetic image before sending waveform images." :
                        "Vision support is unlisted. Test this model to enable images.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if settings.connectionVerified { connectionButton }
                    else { connectionButton.buttonStyle(.borderedProminent) }
                    if settings.checking {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { settings.cancelDiscovery() }
                    }
                    Button("Test Tool Calling") { settings.testTools() }
                        .disabled(!settings.discovered || settings.checking)
                    if let project {
                        Button("Remember in Project") { settings.remember(project) }
                            .disabled(!settings.discovered || settings.checking)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, idealWidth: 540, maxWidth: 760).frame(minHeight: 270)
        .onChange(of: settings.enabled) { _, enabled in if !enabled { settings.cancelDiscovery(); settings.disableImages() } }
    }
}
