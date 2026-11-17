import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CalibrationPanel: View {
    @ObservedObject var bench: StreamingBench
    @State private var draft = CalibrationAttempt(name: "", setup: .init(firmware: "Pico W · firmware 1.8"))
    @State private var phase = CalibrationPhase.empty
    @State private var confirmPhase = false
    @State private var runName = ""
    @State private var runNotes = ""
    @State private var extraMinutes = 0
    @State private var expanded = false
    @State private var previewImport: ImportPreview?
    @State private var previewExport: CalibrationProfile?
    @State private var electricalProfile: UUID?
    @State private var fixtureRun: UUID?

    struct ImportPreview: Identifiable {
        var id = UUID()
        var profile: CalibrationProfile
        var url: URL
    }

    var body: some View {
        DisclosureGroup("Calibration profiles", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button("New Draft") { draft = newDraft() }
                    Menu("Open Draft") {
                        ForEach(bench.attempts) { attempt in
                            Button(attempt.name) { draft = attempt; phase = attempt.phases.first ?? .empty; confirmPhase = false }
                        }
                    }.disabled(bench.attempts.isEmpty)
                    Spacer()
                    Button("Import .sigb…", action: selectImport)
                    Menu("Export .sigb") {
                        ForEach(bench.profiles, id: \.id) { profile in
                            Button(profile.name) { previewExport = profile }
                        }
                    }.disabled(bench.profiles.isEmpty)
                }
                if let saved = bench.profiles.first(where: { $0.id == draft.resultID }) {
                    phaseResults(saved)
                }
                electricalControls
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Profile name", text: $draft.name).textFieldStyle(.roundedBorder)
                    Picker("Preset", selection: $draft.preset) {
                        ForEach(CalibrationPreset.allCases) { preset in Text("\(preset.rawValue) · \(preset.seconds / 60) min").tag(preset) }
                    }.fixedSize().disabled(draft.phases.contains { savedTime($0) > 0 })
                    ProfileSetupEditor(setup: $draft.setup)
                        .disabled(draft.phases.contains { savedTime($0) > 0 })
                    DisclosureGroup("Pulse rules") { ProfileRulesEditor(rules: $draft.rules, sampleRate: Int(draft.setup.recordedHz.rounded())).padding(.top, 8) }
                    DisclosureGroup("Local validation limits") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Set acceptance limits from measured controls. The app has no validated release limits.")
                                .font(.caption).foregroundStyle(.secondary)
                            ProfileLimitsEditor(limits: $draft.limits)
                        }.padding(.top, 8)
                    }
                }.disabled(draft.locked)
                if draft.locked {
                    Text("Fit and holdout rules are locked. Start a new draft to change them.").foregroundStyle(.secondary)
                    if draft.resultID == nil {
                        Button("Continue Validation", action: evaluate).disabled(bench.busy || !draft.limits.valid)
                    }
                } else {
                    Divider()
                    phaseControls
                    HStack {
                        Button("Save Draft", action: save).disabled(!draft.valid || bench.busy)
                        Spacer()
                        Button("Lock and Validate", action: evaluate)
                            .disabled(!draft.valid || !draft.limits.valid || bench.busy || !draft.phases.allSatisfy { savedTime($0) >= Double(draft.preset.seconds) })
                    }
                }
            }.padding(.top, 14)
        }
        .onChange(of: bench.project?.identity.id) { _, _ in
            draft = newDraft()
            phase = .empty
            confirmPhase = false
        }
        .onChange(of: bench.connectionEpoch) { _, _ in confirmPhase = false }
        .onChange(of: draft.preset) { _, _ in if !draft.phases.contains(phase) { phase = .empty } }
        .onChange(of: phase) { _, _ in confirmPhase = false }
        .onChange(of: draft.setup) { _, _ in confirmPhase = false }
        .sheet(item: $previewImport) { preview in
            setupSheet(preview.profile, title: "Import Calibration Setup", action: "Import") {
                defer { previewImport = nil }
                guard let project = bench.project else { return }
                let acquired = preview.url.startAccessingSecurityScopedResource()
                defer { if acquired { preview.url.stopAccessingSecurityScopedResource() } }
                do {
                    let result = try StreamingCalibration.importSetup(preview.url, into: project, expected: preview.profile)
                    bench.refreshCalibration()
                    bench.notice = "Imported \(result.name). Record a local dark setup check before use."
                } catch { bench.notice = error.localizedDescription }
            } cancel: { previewImport = nil }
        }
        .sheet(isPresented: Binding(get: { previewExport != nil }, set: { if !$0 { previewExport = nil } })) {
            if let profile = previewExport {
                setupSheet(profile, title: "Export Calibration Setup", action: "Choose Location…") {
                    guard let project = bench.project else { return }
                    bench.export(toFolderFor: project, title: "Export Calibration Setup", progress: "Exporting calibration setup",
                                 onSelection: { previewExport = nil }) { folder in
                        try StreamingCalibration.exportSetup(profile, in: project, destination: folder)
                    }
                } cancel: { previewExport = nil }
            }
        }
    }

    private func newDraft() -> CalibrationAttempt {
        let version = bench.board == .unoR4 ? "1.0" : CalibrationSetup.streamingVersions.contains(bench.firmware) ? bench.firmware : "1.8"
        return CalibrationAttempt(name: "", setup: .init(firmware: CalibrationSetup.firmwareLabel(version, board: bench.board), acquisitionBoard: bench.board))
    }

    @ViewBuilder private var electricalControls: some View {
        let profiles = bench.profiles.filter { $0.ready && $0.setup.requiresLocalFixture && !$0.measurementReady }
        if !profiles.isEmpty {
            DisclosureGroup("Timed fixture validation") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Profile to validate", selection: $electricalProfile) {
                        Text("Choose a profile").tag(UUID?.none)
                        ForEach(profiles) { Text($0.name + " · revision " + String($0.revision)).tag(Optional($0.id)) }
                    }
                    if let selected = profiles.first(where: { $0.id == electricalProfile }) {
                        let fixtures = bench.runs.compactMap(\.run).filter { run in
                            run.curveSource == nil && run.status == .complete && run.settings.bench?.step == .fixture &&
                                run.settings.bench.map { selected.setup.matchesAcquisition($0.setup) } == true
                        }
                        Picker("Fixture run", selection: $fixtureRun) {
                            Text("Choose a run").tag(UUID?.none)
                            ForEach(fixtures) { Text($0.name).tag(Optional($0.id)) }
                        }
                        Text("Import the independently timed reference in the fixture run first. Validation checks the profile’s own pulse rules and saves a new revision.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Validate Profile with Fixture") {
                            guard let project = bench.project, let fixture = fixtureRun else { return }
                            bench.perform("Validating timed fixture pulses") {
                                try ProfileFixtureValidation.validate(selected, in: project, fixture: fixture)
                            } completion: { result in
                                bench.refreshCalibration()
                                bench.notice = "\(result.name) revision \(result.revision) passed local fixture validation."
                                electricalProfile = nil
                                fixtureRun = nil
                            }
                        }.disabled(bench.busy || !fixtures.contains(where: { $0.id == fixtureRun }))
                    }
                }.padding(.top, 6)
            }.onChange(of: electricalProfile) { _, _ in fixtureRun = nil }
        }
    }

    private var rateLocked: Bool {
        bench.runs.contains { $0.run?.curveSource == nil && $0.run?.settings.calibrationAttempt == draft.id }
    }

    private var phaseControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            SamplingRatePicker(bench: bench, selection: Binding(
                get: { draft.setup.nominalHz },
                set: { next in
                    let previous = draft.setup.recordedHz
                    draft.setup.nominalHz = next
                    draft.rules.rescaleTiming(from: previous, to: draft.setup.recordedHz)
                    confirmPhase = false
                }), seconds: Double(phaseSeconds), locked: rateLocked, averaging: Binding(
                    get: { draft.setup.picoAveraging }, set: { factor in
                        let previous = draft.setup.recordedHz
                        draft.setup.picoAveraging = factor
                        draft.rules.rescaleTiming(from: previous, to: draft.setup.recordedHz)
                        confirmPhase = false
                    }))
            Picker("Phase", selection: $phase) { ForEach(draft.phases) { Text($0.title).tag($0) } }
            Text(phase.instructions).foregroundStyle(.secondary)
            Text("Unplug USB before changing the detector, probes or J4. Wait for the baseline to settle after reconnecting.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("I confirmed this phase’s setup and J4", isOn: $confirmPhase)
            TextField("Phase run name", text: $runName).textFieldStyle(.roundedBorder)
            TextField("Phase run description", text: $runNotes).textFieldStyle(.roundedBorder)
            HStack {
                Text("\(Int(savedTime(phase))) s saved").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Stepper("Extra time \(extraMinutes) min", value: $extraMinutes, in: 0...30)
                    .fixedSize()
                Button("Record Phase", action: recordPhase).disabled(!bench.canStart || !bench.rateAvailable(draft.setup.nominalHz, averaging: draft.setup.picoAveraging) || !draft.valid || !confirmPhase ||
                    (try? SessionStore.projectName(runName)) == nil || runNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || phaseSeconds <= 0)
            }
        }
    }

    private func phaseResults(_ profile: CalibrationProfile) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(profile.ready ? "Noise Checks Passed" : "Needs More Data").font(.headline)
            Text("Independent electrical pulse validation pending.").font(.caption).foregroundStyle(.secondary)
            ForEach(profile.phases, id: \.phase) { phase in
                Text(phase.phase.title).font(.body.weight(.medium))
                Text("Fit \(phase.fit.usable.formatted(.number.precision(.fractionLength(1)))) s usable · holdout \(phase.holdout.usable.formatted(.number.precision(.fractionLength(1)))) s usable")
                    .foregroundStyle(.secondary)
                ForEach(phase.issues, id: \.self) { Text($0).foregroundStyle(.secondary) }
            }
        }.font(.callout)
    }

    private var phaseSeconds: Int { max(0, draft.preset.seconds - Int(savedTime(phase))) + extraMinutes * 60 }

    private func savedTime(_ phase: CalibrationPhase) -> Double {
        bench.runs.compactMap(\.run).filter {
            $0.curveSource == nil && $0.settings.calibrationAttempt == draft.id && $0.settings.calibrationPhase == phase
        }.reduce(0.0) { total, run in
            total + run.segments.reduce(0.0) { $0 + Double($1.accountedSamples) / $1.configuredRate(run.settings.nominalRate) }
        }
    }

    private func save() {
        guard let project = bench.project else { return }
        do { try StreamingCalibration.save(draft, to: project); bench.refreshCalibration() }
        catch { bench.notice = error.localizedDescription }
    }

    private func recordPhase() {
        guard let project = bench.project, phaseSeconds > 0 else { return }
        do {
            try StreamingCalibration.save(draft, to: project)
            bench.refreshCalibration()
            let settings = StreamRunSettings(mode: .calibration, nominalRate: draft.setup.nominalHz, duration: Double(phaseSeconds), wiring: phase.title,
                                             gain: draft.setup.gain, calibrationAttempt: draft.id, calibrationPhase: phase,
                                             calibrationSetup: draft.setup, picoAveraging: draft.setup.picoAveraging)
            bench.start(name: runName, description: runNotes, settings: settings)
        } catch { bench.notice = error.localizedDescription }
    }

    private func evaluate() {
        guard let project = bench.project else { return }
        let entered = draft
        bench.perform("Analyzing calibration phases") {
            try StreamingCalibration.evaluate(entered, project: project)
        } completion: { profile in
            bench.refreshCalibration()
            draft = bench.attempts.first { $0.id == entered.id } ?? entered
            bench.notice = profile.ready ? "Noise checks passed. Electrical pulse validation is pending." : "Calibration needs more data. Review the phase results."
        }
    }

    private func selectImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(exportedAs: CalibrationSetupDocument.type, conformingTo: .json)]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let acquired = url.startAccessingSecurityScopedResource()
        defer { if acquired { url.stopAccessingSecurityScopedResource() } }
        do { previewImport = .init(profile: try StreamingCalibration.readSetup(url), url: url) }
        catch { bench.notice = error.localizedDescription }
    }

    private func setupSheet(_ profile: CalibrationProfile, title: String, action: String,
                            save: @escaping () -> Void, cancel: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.weight(.semibold))
            Text("\(profile.name) · revision \(profile.revision)").font(.headline)
            Text("Board \(profile.setup.board) · detector \(profile.setup.detector) · J4 \(profile.setup.gain)")
            Text("Setup labels, pulse rules, phase summaries and evidence hashes are included. Raw waveforms stay in the Project.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(action, action: save).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 410)
    }
}
