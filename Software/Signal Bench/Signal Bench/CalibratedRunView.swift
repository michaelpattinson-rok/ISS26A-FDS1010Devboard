import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CalibratedRunView: View {
    @EnvironmentObject private var model: BenchModel
    @State private var attempts: [CalibrationAttempt] = []
    @State private var profiles: [CalibrationProfile] = []
    @State private var draft: CalibrationAttempt?
    @State private var newName = ""
    @State private var preset = CalibrationPreset.standard
    @State private var newSetup = CalibrationSetup()
    @State private var creating = false
    @State private var profileID: UUID?
    @State private var phase: CalibrationPhase = .empty
    @State private var wiringConfirmed = false
    @State private var settleUntil: ContinuousClock.Instant?
    @State private var evaluation: ProfileEvaluation?
    @State private var setupEvaluation: ProfileSetupEvaluation?
    @State private var checkGroup: UUID?
    @State private var checkConnection: UUID?
    @State private var runName = ""
    @State private var runNotes = ""
    @State private var measuring = false
    @State private var hours = 0
    @State private var minutes = 5
    @State private var reviewID: UUID?
    @State private var openFinishedRun: UUID?
    @State private var review: ProfileRunReview?
    @State private var revisions: [ProfileAnalysisRevision] = []
    @State private var selectedRevision: UUID?
    @State private var reviewRules = ProfilePulseRules()
    @State private var manualMasks: [ProfileManualExclusion] = []
    @State private var maskStart = 0
    @State private var maskEnd = 0
    @State private var maskReason = ""
    @State private var preview: Preview?
    @State private var transfer: SetupTransfer?
    @State private var exportOptions = ProfileResultsOptions()
    @State private var exportName = ""
    @State private var exportOpen = false
    @State private var fixtureRun: UUID?
    @State private var job: Task<Void, Never>?
    @State private var jobLabel = ""
    @State private var issue: String?

    private struct Preview: Sendable {
        let record: CaptureRecord
        let result: ProfileWindowResult
    }

    private struct SetupTransfer: Identifiable {
        let id = UUID()
        var document: CalibrationSetupDocument
        var importing: Bool
    }

    private var profile: CalibrationProfile? { profiles.first { $0.id == profileID } }
    private var idle: Bool { model.canExportFiles && !model.pendingUnsaved && job == nil }
    private var recording: MeasurementRun? {
        guard let run = model.measurementRun, run.profileAcquisition != nil, run.inProgress else { return nil }
        return run
    }
    private var runs: [RunArchive] {
        model.savedRuns.filter { $0.profileAcquisition?.purpose == .profileRun }.sorted { $0.startedAt > $1.startedAt }
    }
    private var selectedRun: RunArchive? { runs.first { $0.id == reviewID } }
    private var activeRevision: ProfileAnalysisRevision? { revisions.first { $0.id == selectedRevision } }
    private var duration: Int? {
        guard (0...2).contains(hours), (0...59).contains(minutes), (1...120).contains(60 * hours + minutes) else { return nil }
        return (60 * hours + minutes) * 60
    }
    private var settled: Bool { settleUntil.map { ContinuousClock().now >= $0 } ?? false }
    private var currentCheckRuns: [RunArchive] {
        guard let checkGroup, checkConnection == model.profileConnection else { return [] }
        return model.savedRuns.filter { $0.profileAcquisition?.group == checkGroup && $0.profileAcquisition?.purpose == .setupCheck }
            .sorted { $0.startedAt < $1.startedAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Calibrated Run").font(.largeTitle.weight(.semibold))
                    Text("Check a named profile against your setup, then record finite ADC windows. Results are pulse matches within sampled windows.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if model.currentSession == nil {
                    HStack {
                        Button("New Project…", action: model.createSession).buttonStyle(.borderedProminent)
                        Button("Open Project…", action: model.openSession)
                    }
                } else if let recording {
                    active(recording)
                } else {
                    if let issue { Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.orange).textSelection(.enabled) }
                    if job != nil {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(jobLabel)
                            Spacer()
                            Button("Cancel") { job?.cancel() }
                        }
                    }
                    library
                    if let draft { calibration(draft) }
                    if let profile { runControls(profile) }
                    if !runs.isEmpty { results }
                }
                if model.pendingUnsaved {
                    Text("Keep the Pico powered. Reconnect and use Recover Capture in the original Project before continuing.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 740, alignment: .leading).padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: model.currentSession?.id, initial: true) { old, new in
            if old != new {
                job?.cancel()
                draft = nil
                profiles = []
                attempts = []
                profileID = nil
                reviewID = nil
                review = nil
            }
            reload()
        }
        .onChange(of: model.savedRuns.map { "\($0.id):\($0.phase)" }) { _, _ in openFinished() }
        .onChange(of: model.busy) { _, busy in if !busy { openFinished() } }
        .onChange(of: model.profileConnection) { _, _ in
            wiringConfirmed = false
            setupEvaluation = nil
        }
        .onChange(of: profileID) { _, _ in
            wiringConfirmed = false
            model.forgetProfileSetup()
            setupEvaluation = nil
            checkGroup = nil
        }
        .onDisappear { job?.cancel() }
        .sheet(isPresented: $creating) { newProfileSheet }
        .sheet(item: $transfer) { item in transferSheet(item) }
        .sheet(isPresented: $exportOpen) { resultsExportSheet }
    }

    private var library: some View {
        GroupBox("Calibration profiles") {
            VStack(alignment: .leading, spacing: 10) {
                if profiles.isEmpty {
                    Text("Create a profile to compare the empty board with the dark detector.").foregroundStyle(.secondary)
                } else {
                    Picker("Profile", selection: $profileID) {
                        Text("Choose a profile").tag(UUID?.none)
                        ForEach(profiles) { item in
                            Text("\(item.name) · Revision \(item.revision) · \(item.ready ? "Ready" : "Review required")").tag(Optional(item.id))
                        }
                    }
                    if let profile {
                        Label(profile.ready ? (profile.origin == "imported" ? "Source Noise Checks Passed" : "Noise Checks Passed") : "Noise Checks Need Review",
                              systemImage: profile.ready ? "checkmark.circle" : "exclamationmark.circle")
                        if let electrical = profile.electrical {
                            Label(electrical.passed
                                  ? (profile.locallyVerifiedElectrical == true ? "Electrical Pulse Check Passed" : "Electrical check reported by source")
                                  : "Electrical Pulse Check Needs Review",
                                  systemImage: electrical.passed ? "checkmark.circle" : "exclamationmark.circle")
                            Text("Tested \(format(electrical.minimumHeight)) to \(format(electrical.maximumHeight)) codes and \(electrical.minimumWidthSamples * 10) to \(electrical.maximumWidthSamples * 10) µs")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("\(electrical.hits) hits · \(electrical.missed) in-window misses · \(electrical.inGaps) in gaps · \(electrical.uncertain) uncertain · \(electrical.falseMatches) unmatched detections")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Electrical pulse check pending.").font(.caption).foregroundStyle(.secondary)
                        }
                        DisclosureGroup("Phase evidence") {
                            ForEach(profile.phases, id: \.phase) { phase in
                                Text("\(phase.phase.title) · \(phase.fit.usableWindows) fit / \(phase.holdout.usableWindows) holdout windows")
                                ForEach(phase.issues, id: \.self) { Text($0).foregroundStyle(.orange) }
                            }
                        }.font(.callout)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack { libraryActions }
                    VStack(alignment: .leading) { libraryActions }
                }.disabled(!idle)
                if !attempts.isEmpty {
                    Menu("Open calibration attempt") {
                        ForEach(attempts) { item in
                            Button("\(item.name) · Revision \(item.revision) · \(item.locked ? "Locked" : "Draft")") {
                                draft = item
                                phase = .empty
                                evaluation = nil
                                preview = nil
                                wiringConfirmed = false
                            }
                        }
                    }.disabled(!idle)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    @ViewBuilder private var libraryActions: some View {
        Button("New Profile…") {
            newName = ""
            newSetup = CalibrationSetup()
            newSetup.board = model.currentSession?.details["board"] ?? ""
            newSetup.detector = model.currentSession?.details["detector"] ?? ""
            creating = true
        }
        Button("Import Calibration Setup…", action: chooseImport)
        if let profile {
            Button("Export Calibration Setup…") {
                do { transfer = .init(document: try SessionStore.calibrationSetupDocument(profile), importing: false) }
                catch { issue = error.localizedDescription }
            }
        }
    }

    private var newProfileSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Calibration Profile").font(.title2.weight(.semibold))
            TextField("Profile name", text: $newName).textFieldStyle(.roundedBorder)
            Picker("Preset", selection: $preset) {
                ForEach(CalibrationPreset.allCases) { item in Text(item.rawValue).tag(item) }
            }
            Text("\(preset.seconds / 60) minutes per phase · \(preset.seconds / 60 * preset.phases.count) minutes of capture time, plus setup and settling.")
                .font(.caption).foregroundStyle(.secondary)
            ProfileSetupEditor(setup: $newSetup)
            HStack {
                Spacer()
                Button("Cancel") { creating = false }.keyboardShortcut(.cancelAction)
                Button("Save Draft") {
                    guard let name = try? SessionStore.projectName(newName) else { return }
                    let attempt = CalibrationAttempt(name: name, preset: preset, setup: newSetup)
                    creating = false
                    saveDraft(attempt)
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!newSetup.valid || (try? SessionStore.projectName(newName)) == nil)
            }
        }.padding(24).frame(width: 490)
    }

    private func calibration(_ attempt: CalibrationAttempt) -> some View {
        GroupBox("Calibrate \(attempt.name)") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(attempt.locked ? "Rules locked" : "Draft").font(.headline)
                    Spacer()
                    Button("Close Attempt") { draft = nil; evaluation = nil; preview = nil }.disabled(!idle)
                }
                if !attempt.locked {
                    Picker("Phase", selection: $phase) {
                        ForEach(attempt.phases) { item in Text(item.title).tag(item) }
                    }.onChange(of: phase) { _, _ in wiringConfirmed = false }
                    Text(phase.instructions).font(.callout)
                    let elapsed = phaseElapsed(attempt.id, phase: phase)
                    Text("\(Int(elapsed)) s saved of \(attempt.preset.seconds) s planned")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    setupConfirmation(attempt.setup)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Button(elapsed > 0 ? "Record More for This Phase" : "Record This Phase") {
                            startPhase(attempt, elapsed: elapsed)
                        }.buttonStyle(.borderedProminent)
                            .disabled(!idle || !wiringConfirmed || !settled || !model.profileCanCapture
                                      || model.gain != attempt.setup.gain || !phaseAllowed(attempt))
                    }
                    if attempt.preset != .deep && !attempt.extraRepeat {
                        Button("Add an Empty Board Repeat") {
                            var updated = attempt
                            updated.extraRepeat = true
                            saveDraft(updated)
                        }.disabled(!idle)
                    }
                    if draft != nil {
                        DisclosureGroup("Pulse rules and local limits") {
                            ProfileRulesEditor(rules: Binding(get: { draft?.rules ?? attempt.rules }, set: {
                                draft?.rules = $0
                                preview = nil
                            }))
                            Divider()
                            ProfileLimitsEditor(limits: Binding(get: { draft?.limits ?? attempt.limits }, set: { draft?.limits = $0 }))
                        }.disabled(!idle)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { draftActions(attempt) }
                        VStack(alignment: .leading) { draftActions(attempt) }
                    }.disabled(!idle)
                    if let preview { ProfilePreview(record: preview.record, result: preview.result) }
                } else {
                    Text("The holdout belongs to this locked revision. Editing the rules starts a new attempt with fresh data.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button(attempt.resultID == nil ? "Evaluate Locked Revision" : "Review Holdout Blocks") {
                            if attempt.resultID == nil { lockAndFit(attempt) }
                            else { operate("Reading locked holdout…", work: { context in
                                try context.store.fitCalibration(attempt, in: context.folder, project: context.sessionID)
                            }) { evaluation = $0 } }
                        }
                        Button("New Revision with Fresh Data") {
                            var fresh = attempt
                            fresh.id = UUID()
                            fresh.predecessor = attempt.id
                            fresh.revision = max(attempt.revision, profiles.filter { $0.profileID == attempt.profileID }.map(\.revision).max() ?? 0) + 1
                            fresh.locked = false
                            fresh.resultID = nil
                            saveDraft(fresh)
                        }
                    }.disabled(!idle)
                    if let evaluation, evaluation.profile.id == attempt.id {
                        Text(evaluation.profile.ready ? "Noise Checks Passed" : "Needs more data or review").font(.headline)
                        ForEach(evaluation.profile.phases, id: \.phase) { summary in
                            Text("\(summary.phase.title) · fit \(format(summary.fit.usable)) s · holdout \(format(summary.holdout.usable)) s")
                            ForEach(summary.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                            if let blocks = evaluation.blocks[summary.phase] { blockList(blocks) }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    @ViewBuilder private func draftActions(_ attempt: CalibrationAttempt) -> some View {
        Button("Suggest Fit Threshold") {
            guard let draft else { return }
            operate("Fitting the threshold on earlier windows…", work: { context in
                try context.store.suggestedPulseRules(draft, in: context.folder)
            }) { rules in
                self.draft?.rules = rules
                preview = nil
                model.status = "Suggested threshold from fit windows. Review and lock it before evaluating holdout."
            }
        }.disabled(!(draft?.rules.valid ?? false))
        Button("Preview Fit Waveform") { previewTraining(attempt) }
        Button("Save Draft") { if let draft { saveDraft(draft) } }
        Button("Lock and Evaluate") { if let draft { lockAndFit(draft) } }
            .buttonStyle(.borderedProminent)
            .disabled(!(draft?.limits.valid ?? false) || !(draft?.rules.valid ?? false)
                      || !attempt.phases.allSatisfy { phaseElapsed(attempt.id, phase: $0) >= Double(attempt.preset.seconds) })
    }

    private func setupConfirmation(_ setup: CalibrationSetup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(setup.board) · \(setup.detector) · J4 \(setup.gain.lowercased())")
                .font(.callout).foregroundStyle(.secondary)
            Text("\(setup.cable) · \(setup.enclosure) · \(setup.conditions)")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Confirm the physical setup", isOn: $wiringConfirmed)
                .onChange(of: wiringConfirmed) { _, confirmed in
                    settleUntil = confirmed ? ContinuousClock().now.advanced(by: .seconds(10)) : nil
                    if !confirmed { model.forgetProfileSetup() }
                }
            if wiringConfirmed {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    HStack {
                        Text(settled ? "Settling time complete" : "Let the signal settle")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Wait 15 More Seconds") { settleUntil = ContinuousClock().now.advanced(by: .seconds(15)) }
                    }
                }
                if !model.gainConfirmed || model.gain != setup.gain {
                    Button("Confirm J4 \(setup.gain.lowercased()) on Pico") { model.changeGain(setup.gain) }
                        .disabled(!model.connected || model.busy || model.pendingUnsaved)
                }
            }
        }.disabled(!idle)
    }

    private func runControls(_ profile: CalibrationProfile) -> some View {
        GroupBox("Record with \(profile.name)") {
            VStack(alignment: .leading, spacing: 11) {
                if profile.ready {
                    if !model.hasProfileSetup(profile) {
                        Text("Restore the dark detector setup. A local check is required for this connection.")
                            .font(.callout).foregroundStyle(.secondary)
                        setupConfirmation(profile.setup)
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            HStack {
                                Button(currentCheckRuns.isEmpty ? "Record Two Minute Dark Check" : "Extend Dark Check") {
                                    startCheck(profile)
                                }.disabled(!wiringConfirmed || !settled || !model.profileCanCapture || model.gain != profile.setup.gain)
                                if currentCheckRuns.contains(where: { $0.phase == "completed" }) {
                                    Button("Evaluate Check") { evaluateCheck(profile) }
                                }
                            }.disabled(!idle)
                        }
                        if let setupEvaluation {
                            coverage(setupEvaluation.coverage)
                            ForEach(setupEvaluation.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                        }
                    } else {
                        Label("Local dark check passed", systemImage: "checkmark.circle")
                        Button("Setup Changed") { model.forgetProfileSetup(); wiringConfirmed = false; checkGroup = nil }
                        TextField("Run name", text: $runName).textFieldStyle(.roundedBorder)
                        TextField("Run notes", text: $runNotes).textFieldStyle(.roundedBorder)
                        Picker("Label", selection: $measuring) {
                            Text("Background").tag(false)
                            Text("Measurement").tag(true)
                        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
                        HStack(spacing: 12) {
                            durationField("Hours", $hours)
                            durationField("Minutes", $minutes)
                        }
                        if let duration {
                            let mb = Double(duration) / 7200 * 241
                            Text("About \(format(mb)) MB of raw words at the historical capture cadence. Exports may be much larger.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Start Run") { startProfileRun(profile) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!idle || !model.profileCanCapture || duration == nil || runNotes.utf8.count > 2048
                                      || (try? SessionStore.projectName(runName)) == nil)
                    }
                } else {
                    Text("Complete the noise checks before recording with this profile.").foregroundStyle(.secondary)
                }
                DisclosureGroup("Independent electrical check") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("With USB power removed, use the documented electrical fixture in place of the detector. Drive it externally and use a scope reference aligned independently of the pulse decisions.")
                            .font(.caption).foregroundStyle(.secondary)
                        setupConfirmation(profile.setup)
                        Button("Record Fixture Windows for Two Minutes") {
                            begin(.fixture, owner: profile.id, name: "Fixture reference", setup: profile.setup, profile: profile, seconds: 120)
                        }.disabled(!idle || !model.profileCanCapture || !wiringConfirmed || !settled)
                        Picker("Saved fixture run", selection: $fixtureRun) {
                            Text("Choose a run").tag(UUID?.none)
                            ForEach(model.savedRuns.filter { $0.profileAcquisition?.purpose == .fixture && $0.profileAcquisition?.owner == profile.id }) {
                                Text($0.startedAt.formatted()).tag(Optional($0.id))
                            }
                        }
                        Button("Load Timed Fixture Evidence…") { chooseFixture(profile) }
                            .disabled(!idle || fixtureRun == nil)
                    }.padding(.top, 7)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private var results: some View {
        GroupBox("Saved profile runs") {
            VStack(alignment: .leading, spacing: 11) {
                Picker("Run", selection: $reviewID) {
                    Text("Choose a run").tag(UUID?.none)
                    ForEach(runs) { run in
                        Text("\(run.profileAcquisition?.name ?? "Run") · \(run.startedAt.formatted(date: .abbreviated, time: .shortened))").tag(Optional(run.id))
                    }
                }.onChange(of: reviewID) { _, _ in
                    review = nil
                    preview = nil
                    revisions = []
                    selectedRevision = nil
                    manualMasks = []
                    if let selectedRun { reviewRun(selectedRun) }
                }
                if let run = selectedRun {
                    Text(run.phase == "completed" ? "Saved" : "Interrupted or paused").font(.callout)
                    if let reason = run.profilePauseReason { Text(reason).font(.callout).foregroundStyle(.orange) }
                    if run.phase != "completed", let snapshot = run.profileAcquisition?.snapshot {
                        Button("Continue After Local Check") {
                            model.restoreRun(run)
                            if model.canResumeRun { openFinishedRun = run.id; model.resumeRun() }
                            else { issue = "Check the original profile and recover any pending capture before continuing." }
                        }.disabled(!idle || !model.hasProfileSetup(snapshot))
                    }
                    if let review {
                        coverage(review.coverage)
                        Text("\(review.coverage.matches.formatted()) pulse matches").font(.headline.monospacedDigit())
                        blockList(review.blocks)
                        if !revisions.isEmpty {
                            Picker("Analysis", selection: $selectedRevision) {
                                Text("Original rules").tag(UUID?.none)
                                ForEach(revisions) { Text($0.createdAt.formatted()).tag(Optional($0.id)) }
                            }.onChange(of: selectedRevision) { _, _ in reviewRun(run, revision: activeRevision) }
                        }
                        DisclosureGroup("Preview and reanalyze") {
                            ProfileRulesEditor(rules: $reviewRules)
                            Menu("Preview Saved Waveform") {
                                ForEach(review.recordIDs, id: \.self) { id in
                                    Button("Window \(id.prefix(8))") { previewRunWindow(id, run: run) }
                                }
                            }.disabled(!idle || !reviewRules.valid)
                            if let preview {
                                ProfilePreview(record: preview.record, result: preview.result)
                                Text("Exclude samples in this window").font(.callout.weight(.medium))
                                HStack {
                                    durationField("Start index", $maskStart)
                                    durationField("End index, exclusive", $maskEnd)
                                }
                                TextField("Reason for exclusion", text: $maskReason)
                                Button("Add Exclusion") {
                                    let exclusion = ProfileManualExclusion(recordID: preview.record.id, start: maskStart, end: maskEnd, reason: maskReason)
                                    if exclusion.valid && exclusion.end <= preview.record.samples.count && manualMasks.count < 256 {
                                        manualMasks.append(exclusion)
                                        previewRunWindow(preview.record.id, run: run)
                                    }
                                }
                                if !manualMasks.isEmpty {
                                    Text("\(manualMasks.count) operator exclusions").font(.caption)
                                    Button("Clear Draft Exclusions") {
                                        manualMasks = []
                                        previewRunWindow(preview.record.id, run: run)
                                    }
                                }
                            }
                            Button("Save New Analysis Revision") { reanalyze(run) }
                                .disabled(!idle || !reviewRules.valid)
                        }
                    }
                    HStack {
                        ProjectCSVExportButton(title: "Export Raw CSV…", source: .waveformRun(run.id))
                        Button("Export Results…") {
                            exportName = "Profile results " + String(run.id.uuidString.prefix(8))
                            exportOpen = true
                        }.disabled(!idle || review?.coverage.windows == 0)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private func active(_ run: MeasurementRun) -> some View {
        GroupBox(run.profileAcquisition?.name ?? "Recording") {
            VStack(alignment: .leading, spacing: 12) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let target = run.durationSeconds ?? 1
                    let remaining = max(0, target - run.elapsedSeconds)
                    ProgressView(value: min(target, run.elapsedSeconds), total: target) {
                        Text("\(Int(ceil(remaining))) s remaining · \(run.completed) saved windows")
                    }
                    coverage(model.profileLiveCoverage)
                }
                Text(model.status).font(.callout).foregroundStyle(.secondary)
                Button(run.phase == .pausing ? "Finishing This Capture…" : "Stop After This Capture", action: model.stopMainRun)
                    .disabled(run.phase == .pausing)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private func durationField(_ title: String, _ value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption)
            TextField(title, value: value, format: .number.grouping(.never)).labelsHidden().accessibilityLabel(title)
        }.frame(maxWidth: 122)
    }

    private func coverage(_ value: ProfileCoverage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(format(value.elapsed)) s elapsed · \(format(value.sampled)) s nominal sampled")
            Text("\(format(value.usable)) s usable · \(format(value.unknown)) s unsampled or unknown")
            if value.uncertainInterruption { Text("Interruption length is unknown.") }
            if value.missing > 0 { Text("\(value.missing) windows missing or unverified") }
        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }

    private func blockList(_ blocks: [ProfileBlock]) -> some View {
        DisclosureGroup("Minute blocks") {
            ForEach(blocks.prefix(120)) { block in
                Text("Minute \(block.minute + 1) · \(format(block.coverage.usable)) s usable · \(block.coverage.matches) matches · \(block.burstWindows) clusters")
                Text("Baseline \(format(block.medianBaseline)) · noise \(format(block.medianNoise)) · drift \(format(block.maximumDrift)) · headroom \(format(block.minimumHeadroom)) codes · peak \(format(block.medianSpectralPeakHz)) Hz nominal")
                    .foregroundStyle(.secondary)
            }
        }.font(.caption)
    }

    private func format(_ number: Double?) -> String {
        number.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "—"
    }
}

extension CalibratedRunView {
    private func reload(select: UUID? = nil) {
        guard model.currentSession != nil else { return }
        operate("Reading Project profiles…", work: { context in
            try context.store.profileLibrary(in: context.folder, project: context.sessionID)
        }) { library in
            attempts = library.0
            profiles = library.1
            if let select { profileID = select }
            else if profileID == nil, library.1.count == 1 { profileID = library.1.first?.id }
        }
    }

    private func saveDraft(_ attempt: CalibrationAttempt) {
        operate("Saving calibration draft…", work: { context in
            try context.store.saveCalibrationAttempt(attempt, in: context.folder, project: context.sessionID)
            return try context.store.profileLibrary(in: context.folder, project: context.sessionID)
        }) { library in
            if draft?.id != attempt.id { phase = .empty; wiringConfirmed = false }
            draft = attempt
            attempts = library.0
            profiles = library.1
            evaluation = nil
        }
    }

    private func lockAndFit(_ attempt: CalibrationAttempt) {
        var revised = attempt
        revised.locked = true
        let locked = revised
        draft = locked
        operate("Evaluating locked fit and holdout…", work: { context in
            try context.store.saveCalibrationAttempt(locked, in: context.folder, project: context.sessionID)
            let result = try context.store.fitCalibration(locked, in: context.folder, project: context.sessionID)
            try context.store.saveCalibrationProfile(result.profile, in: context.folder, project: context.sessionID)
            var completed = locked
            completed.resultID = result.profile.id
            try context.store.saveCalibrationAttempt(completed, in: context.folder, project: context.sessionID)
            let library = try context.store.profileLibrary(in: context.folder, project: context.sessionID)
            return (result, completed, library.0, library.1)
        }) { result in
            evaluation = result.0
            draft = result.1
            attempts = result.2
            profiles = result.3
            profileID = result.0.profile.id
        }
    }

    private func phaseRuns(_ attempt: UUID, phase: CalibrationPhase) -> [RunArchive] {
        model.savedRuns.filter {
            $0.profileAcquisition?.owner == attempt && $0.profileAcquisition?.phase == phase
        }.sorted { $0.startedAt < $1.startedAt }
    }

    private func phaseElapsed(_ attempt: UUID, phase: CalibrationPhase) -> Double {
        phaseRuns(attempt, phase: phase).map { ($0.profileAcquisition?.offsetSeconds ?? 0) + $0.elapsedActiveSeconds }.max() ?? 0
    }

    private func phaseAllowed(_ attempt: CalibrationAttempt) -> Bool {
        guard let boot = model.profileBoot else { return false }
        switch phase {
        case .empty: return true
        case .dark:
            return phaseElapsed(attempt.id, phase: .empty) >= Double(attempt.preset.seconds)
                && phaseRuns(attempt.id, phase: .empty).last?.profileAcquisition?.boot != boot
        case .repeatEmpty:
            return phaseElapsed(attempt.id, phase: .dark) >= Double(attempt.preset.seconds)
                && phaseRuns(attempt.id, phase: .dark).last?.profileAcquisition?.boot != boot
        }
    }

    private func startPhase(_ attempt: CalibrationAttempt, elapsed: Double) {
        guard phaseAllowed(attempt) else { issue = ProfileWorkflowError.powerCycle.localizedDescription; return }
        let remaining = Double(attempt.preset.seconds) - elapsed
        let seconds = remaining > 0 ? max(1, remaining) : 60
        guard elapsed + seconds <= 7200 else { issue = "This phase has reached the two hour limit."; return }
        begin(.calibrationPhase, owner: attempt.id, name: phase.title, setup: attempt.setup,
              phase: phase, offset: elapsed, seconds: seconds)
    }

    private func startCheck(_ profile: CalibrationProfile) {
        if checkConnection != model.profileConnection || checkGroup == nil {
            checkGroup = UUID()
            checkConnection = model.profileConnection
        }
        let validRuns = currentCheckRuns.filter { $0.phase == "completed" }
        let elapsed = validRuns.map { ($0.profileAcquisition?.offsetSeconds ?? 0) + $0.elapsedActiveSeconds }.max() ?? 0
        guard elapsed < 7140 else { issue = "The local check reached its maximum duration."; return }
        begin(.setupCheck, owner: profile.id, name: "Local dark check", setup: profile.setup, profile: profile,
              group: checkGroup, offset: elapsed, seconds: elapsed == 0 ? 120 : 60)
    }

    private func evaluateCheck(_ profile: CalibrationProfile) {
        let runs = currentCheckRuns.filter { $0.phase == "completed" }
        let connection = model.profileConnection
        operate("Checking the local setup…", work: { context in
            try context.store.checkProfileSetup(profile, runs: runs, in: context.folder)
        }) { result in
            setupEvaluation = result
            if let last = runs.last {
                model.acceptProfileSetup(profile, check: last, result: result, connection: connection)
            }
        }
    }

    private func startProfileRun(_ profile: CalibrationProfile) {
        guard let seconds = duration, let name = try? SessionStore.projectName(runName) else { return }
        begin(.profileRun, owner: profile.id, name: name, setup: profile.setup, profile: profile,
              seconds: Double(seconds), notes: runNotes, measurement: measuring)
    }

    private func begin(_ purpose: ProfileAcquisition.Purpose, owner: UUID, name: String, setup: CalibrationSetup,
                       profile: CalibrationProfile? = nil, phase: CalibrationPhase? = nil,
                       group: UUID? = nil, offset: Double = 0, seconds: Double, notes: String = "", measurement: Bool = false) {
        guard let boot = model.profileBoot, let folder = model.sessionURL else {
            issue = ProfileWorkflowError.unavailable.localizedDescription
            return
        }
        if let capacity = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           Double(capacity) < 32_000_000 + seconds / 7200 * 362_000_000 {
            issue = "The Project volume has too little space for this capture estimate."
            return
        }
        let request = ProfileAcquisition(purpose: purpose, owner: owner, name: name, notes: notes, phase: phase,
                                         group: group, offsetSeconds: offset, setup: setup, snapshot: profile, boot: boot)
        issue = nil
        if model.startProfileAcquisition(request, seconds: seconds, measurement: measurement) {
            if purpose == .profileRun { openFinishedRun = model.measurementRun?.id }
        } else { issue = ProfileWorkflowError.incompatibleSetup.localizedDescription }
    }

    private func openFinished() {
        guard !model.busy, let id = openFinishedRun,
              let run = runs.first(where: { $0.id == id }),
              ["completed", "interrupted", "paused"].contains(run.phase) else { return }
        openFinishedRun = nil
        reviewID = id
    }

    private func previewTraining(_ attempt: CalibrationAttempt) {
        let rules = draft?.rules ?? attempt.rules
        let selectedPhase = phase
        operate("Reading a fit waveform…", work: { context in
            let ids = try context.store.trainingRecordIDs(attempt, in: context.folder)
            let summaries = try context.store.listRecordSummaries(context.folder)
            let phaseRuns = try context.store.loadRuns(context.folder).filter { $0.profileAcquisition?.owner == attempt.id && $0.profileAcquisition?.phase == selectedPhase }
            let allowed = Set(phaseRuns.map { $0.id.uuidString })
            let known = Set(ids)
            guard let item = summaries.first(where: { known.contains($0.id) && allowed.contains($0.metadata["host_run_id"] ?? "") && $0.complete })
            else { throw ProfileWorkflowError.moreData }
            let raw = try context.store.loadRecord(item, in: context.folder)
            let result = try ProfileAnalyzer.evaluate(raw, rules: rules, spectrum: true)
            return Preview(record: raw, result: result)
        }) { preview = $0 }
    }

    private func reviewRun(_ run: RunArchive, revision: ProfileAnalysisRevision? = nil) {
        guard let snapshot = run.profileAcquisition?.snapshot else { return }
        preview = nil
        reviewRules = revision?.rules ?? snapshot.rules
        manualMasks = revision?.exclusions ?? []
        operate("Reading saved pulse results…", work: { context in
            (try context.store.profileRunReview(run, revision: revision, in: context.folder),
             try context.store.profileRevisions(run, in: context.folder))
        }) { result in
            review = result.0
            revisions = result.1
        }
    }

    private func previewRunWindow(_ id: String, run: RunArchive) {
        guard let snapshot = run.profileAcquisition?.snapshot else { return }
        let rules = reviewRules, masks = manualMasks
        operate("Reading the original waveform…", work: { context in
            let raw = try context.store.loadRecord(id, in: context.folder)
            guard raw.metadata["host_run_id"] == run.id.uuidString else { throw ProfileWorkflowError.invalidEvidence }
            return Preview(record: raw, result: try ProfileAnalyzer.evaluate(raw, rules: rules, limits: snapshot.limits,
                                                                           envelope: snapshot.envelope, exclusions: masks))
        }) { preview = $0 }
    }

    private func reanalyze(_ run: RunArchive) {
        let revision = ProfileAnalysisRevision(rules: reviewRules, exclusions: manualMasks)
        operate("Saving a new analysis revision…", work: { context in
            let review = try context.store.saveProfileAnalysisRevision(revision, run: run, in: context.folder)
            return (review, try context.store.profileRevisions(run, in: context.folder))
        }) { result in
            review = result.0
            revisions = result.1
            selectedRevision = revision.id
        }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(exportedAs: CalibrationSetupDocument.type, conformingTo: .json)]
        panel.allowsMultipleSelection = false
        panel.message = "Select a Signal Bench calibration setup to preview."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        operate("Validating calibration setup…", work: { _ in
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            return try SessionStore.readCalibrationSetup(url)
        }) { transfer = .init(document: $0, importing: true) }
    }

    private func transferSheet(_ item: SetupTransfer) -> some View {
        let profile = item.document.profile
        return VStack(alignment: .leading, spacing: 14) {
            Text(item.importing ? "Import Calibration Setup" : "Export Calibration Setup").font(.title2.weight(.semibold))
            Text("\(profile.name) · Revision \(profile.revision) · Analyzer \(profile.algorithmVersion)")
                .font(.headline)
            Text("\(profile.setup.board) · \(profile.setup.detector) · J4 \(profile.setup.gain.lowercased())")
            Text("\(profile.setup.cable) · \(profile.setup.enclosure) · \(profile.setup.conditions)")
                .foregroundStyle(.secondary)
            Text("\(profile.rules.polarity.rawValue) · \(profile.rules.threshold.rawValue) · \(format(profile.rules.height)) ADC codes")
            Text(profile.ready ? "Source profile reports passed noise checks." : "Source profile needs review.")
                .foregroundStyle(.secondary)
            ForEach(profile.phases, id: \.phase) { phase in
                Text("\(phase.phase.title) · \(phase.fit.usableWindows) fit and \(phase.holdout.usableWindows) holdout windows")
                    .font(.caption)
            }
            Text(item.importing ? "A local dark check is required before recording." : "Includes setup requirements, rules, summaries and evidence hashes.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { transfer = nil }.keyboardShortcut(.cancelAction)
                Button(item.importing ? "Import" : "Export") {
                    transfer = nil
                    if item.importing {
                        operate("Importing setup into this Project…", work: { context in
                            let value = try context.store.importCalibrationSetup(item.document, in: context.folder, project: context.sessionID)
                            return (value, try context.store.profileLibrary(in: context.folder, project: context.sessionID))
                        }) { result in
                            attempts = result.1.0
                            profiles = result.1.1
                            profileID = result.0.id
                            model.forgetProfileSetup()
                        }
                    } else {
                        operate("Exporting calibration setup…", work: { context in
                            try context.store.exportCalibrationSetup(item.document,
                                                                     filename: String(profile.name.prefix(20)) + " " + String(profile.id.uuidString.prefix(8)),
                                                                     in: context.folder, project: context.sessionID)
                        }) { url in model.status = "Saved \(url.lastPathComponent) in Exports." }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 490)
    }

    private var resultsExportSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Profile Results").font(.title2.weight(.semibold))
            TextField("Export folder name", text: $exportName)
            Toggle("Pulse decisions", isOn: $exportOptions.pulses)
            Toggle("Exclusions", isOn: $exportOptions.exclusions).disabled(exportOptions.cleaned)
            Toggle("Cleaned samples with exclusions", isOn: $exportOptions.cleaned)
            Toggle("Minute coverage", isOn: $exportOptions.coverage)
            Toggle("Window quality", isOn: $exportOptions.quality)
            Text("The run summary and frozen profile are included. Files go in the Project’s Exports folder.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { exportOpen = false }.keyboardShortcut(.cancelAction)
                Button("Export") {
                    guard let run = selectedRun else { return }
                    let revision = activeRevision, name = exportName, options = exportOptions
                    exportOpen = false
                    operate("Writing profile results…", work: { context in
                        try context.store.exportProfileRun(run, revision: revision, options: options, name: name,
                                                           in: context.folder, cancelled: { Task.isCancelled })
                    }) { url in model.status = "Saved \(url.lastPathComponent) in Exports." }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled((try? SessionStore.projectName(exportName)) == nil)
            }
        }.padding(24).frame(width: 440)
    }

    private func chooseFixture(_ profile: CalibrationProfile) {
        guard let run = model.savedRuns.first(where: { $0.id == fixtureRun }) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Select independently timed fixture reference data."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        operate("Matching independent fixture pulses…", work: { context in
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            let updated = try context.store.evaluateFixture(url, run: run, profile: profile, in: context.folder)
            return (updated, try context.store.profileLibrary(in: context.folder, project: context.sessionID))
        }) { result in
            attempts = result.1.0
            profiles = result.1.1
            profileID = result.0.id
        }
    }

    private func operate<Value: Sendable>(_ title: String,
                                           work: @escaping @Sendable (MainNoiseReviewContext) throws -> Value,
                                           finish: @escaping (Value) -> Void) {
        guard job == nil, model.canExportFiles, let context = model.profileProjectContext() else { return }
        issue = nil
        jobLabel = title
        model.busy = true
        job = Task {
            defer { model.busy = false; job = nil }
            for attempt in 0...1 {
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    guard try context.store.openSession(context.folder).id == context.sessionID else { throw StorageError.invalidSession }
                    return try work(context)
                }
                do {
                    let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    try Task.checkCancellation()
                    model.busy = false
                    if model.currentSession?.id == context.sessionID { finish(value) }
                    return
                } catch is CancellationError {
                    return
                } catch {
                    if attempt == 0, !Task.isCancelled, !model.shutdownInProgress, BenchModel.isProfileAccessError(error) {
                        do { try model.restoreProfileFolderAccess() }
                        catch { issue = error.localizedDescription; return }
                    } else { issue = error.localizedDescription; return }
                }
            }
        }
    }
}
