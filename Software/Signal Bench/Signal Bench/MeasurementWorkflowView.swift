import SwiftUI

struct MeasurementWorkflowView: View {
    @EnvironmentObject private var model: BenchModel
    let openSetup: () -> Void
    let confirmRecovery: () -> Void
    @State private var selectedGain = "LOW"
    @State private var runTag = "BACKGROUND"
    @State private var captureCount = "10"
    @State private var timed = true
    @State private var duration = 300
    @State private var customDuration = "60"
    @State private var runPlanExpanded = true
    @State private var showGainConfirmation = false
    @State private var mainOptions = MainObservationOptions()
    @State private var noiseReview: MainNoiseReviewRequest?

    private var mainRuns: [RunArchive] {
        model.savedRuns.filter { $0.workspace == "measurements" && $0.observationOnly == true && $0.profileAcquisition == nil }
    }
    private var captureOptions: MainObservationOptions? { model.observationOnly ? mainOptions : nil }
    private var pulseCriteriaValid: Bool { captureOptions?.criteria.isValid ?? true }

    private var step: MeasurementStep { model.measurementStep(selectedGain: selectedGain) }
    private var latestCalibration: CaptureRecord? {
        model.records.last { $0.complete && $0.metadata["tag"] == "CAL" && $0.metadata["gain"] == model.gain }
    }
    private var plannedCount: Int? {
        guard let count = Int(captureCount.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...MeasurementRun.maximumCaptures).contains(count) else { return nil }
        return count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.observationOnly ? "MAIN" : "CALIBRATED RUN").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if step == .ready {
                    Label(model.observationOnly ? "Raw observations" : "Quiet calibration accepted", systemImage: model.observationOnly ? "waveform.path" : "checkmark.circle").font(.caption)
                }
            }
            if model.connected {
                recordingPolicy
            }
            if let run = model.measurementRun {
                runSummary(run)
            }
            guidance
            if model.currentSession != nil {
                HStack {
                    if model.observationOnly || !mainRuns.isEmpty {
                        Button("Review Noise Runs…", systemImage: "chart.xyaxis.line") {
                            guard let context = model.mainNoiseReviewContext() else { return }
                            let raw = model.selectedRecord.flatMap {
                                $0.complete && $0.metadata["observation_only"] == "1" ? $0 : nil
                            }
                            noiseReview = MainNoiseReviewRequest(context: context, runs: mainRuns, selectedCapture: raw,
                                                                criteria: mainOptions.criteria)
                        }
                        .disabled(model.mainNoiseReviewContext() == nil || model.sequenceRunning || model.busy || model.pendingUnsaved)
                    }
                    Button("Export Session…") { model.requestExport(.session) }
                        .disabled(!model.canExportFiles || model.records.isEmpty)
                    if model.selectedRecord != nil {
                        Button("Export Selected Record…") { model.requestExport(.record) }
                            .disabled(!model.canExportFiles)
                    }
                }
            }
            ObservationGuideView(record: model.selectedRecord, calibration: latestCalibration,
                                 calibrationExpanded: step == .calibration)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .onAppear { selectedGain = model.gain }
        .onChange(of: model.gain) { _, gain in selectedGain = gain }
        .onChange(of: model.currentSession?.id) { _, _ in
            noiseReview = nil
            mainOptions.condition = .unspecified
        }
        .onChange(of: model.sessionURL) { _, _ in noiseReview = nil }
        .sheet(item: $noiseReview) { request in
            MainNoiseReviewView(request: request) { recordID in
                if let record = model.records.first(where: { $0.id == recordID }) {
                    model.selectRecord(record)
                }
            }
        }
        .alert("Confirm physical gain?", isPresented: $showGainConfirmation) {
            Button("Confirm \(selectedGain.capitalized)") { model.changeGain(selectedGain) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Check J4 with USB power removed. Open means low gain. A fitted shunt means high gain. Confirming a position requires a fresh quiet calibration.")
        }
    }

    private var recordingPolicy: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(model.observationOnly ? "Main · raw observations" : "Calibrated Run · qualified pulses", systemImage: model.observationOnly ? "waveform.path" : "checkmark.circle")
                .font(.subheadline.weight(.medium))
            if model.observationOnly {
                Text("Main saves raw windows even when quiet calibration fails. Review saved runs to find pulse matches using your criteria and compare noise over time.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !model.observationsSupported {
                Text("Firmware 1.5 adds raw observations without quiet calibration. Build and load that paired firmware to enable this option.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var guidance: some View {
        switch step {
        case .connect:
            if model.ports.isEmpty {
                instruction("Plug in the Pico W", "Use a USB data cable, then refresh the device list above.")
            } else {
                instruction("Connect to the Pico W", "Select its USB serial port above and click Connect.")
            }
            Button("Open Setup Guide", action: openSetup)
        case .reconnect:
            instruction("Reconnect to check the pending capture", "Keep the Pico powered. Select its USB port above and click Connect to check whether it still holds the record.")
        case .exporting:
            progress("Exporting selected data", "The export keeps the saved records and their original processing results intact.")
            Button("Cancel Export", action: model.cancelExport)
        case .checking:
            progress("Checking the Pico", model.status)
        case .capturing:
            progress("Capturing samples", "Keep the detector and leads still while the Pico captures this window.")
        case .receiving:
            progress("Receiving and saving", "Keep the Pico connected. Signal Bench checks the record before saving it to this session.")
        case .confirmingSave:
            progress("Saved to this session", "Waiting for the Pico to confirm that it released the record.")
        case .stopDiagnostics:
            instruction("Stop live diagnostics", "Stop the active workspace before running a quiet calibration or taking a capture.")
            if model.manualActive {
                Button("Release Outputs and Stop", action: model.exitManual).disabled(model.manualStopping)
            } else {
                Button("Stop Diagnostics", action: model.exitStageDiagnostics).disabled(model.stageStopping)
            }
        case .recoverySession:
            instruction("Open the original session", "Keep the Pico powered and open the session where the capture began. Signal Bench checks its saved capture receipt before recovery.")
            Button("Open Project", action: model.openSession).buttonStyle(.borderedProminent).disabled(!model.canOpenProject)
        case .recover:
            if model.recoveryIsUnlinked {
                instruction("Older record awaiting import", "Keep the Pico powered. The original setup for this record is unknown.")
            } else {
                instruction(model.pendingHasSavedCopy ? "Confirm the saved capture" : "Recover the pending capture",
                            "Keep the Pico powered. Signal Bench will verify the capture receipt in this session.")
            }
            if let issue = model.captureSaveIssue {
                Text("Save failed. Check folder access and free disk space. \(issue)")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Button(model.recoveryIsUnlinked ? "Import Unlinked Record" : "Retry Pending Record", action: confirmRecovery)
                .buttonStyle(.borderedProminent)
        case .session:
            instruction("Choose where captures go", "Create a session for this run or open an existing session. Calibration records and captures save there automatically.")
            HStack {
                Button("New Project", action: model.createSession).buttonStyle(.borderedProminent).disabled(!model.canCreateProject)
                Button("Open Project", action: model.openSession).disabled(!model.canOpenProject)
            }
        case .gain:
            instruction("Confirm the J4 gain", "Match the setting to the physical jumper. Unplug USB before moving the shunt.")
            gainControls
        case .calibration:
            if let record = latestCalibration, record.metadata["calibrated"] == "0" {
                instruction("Run a fresh quiet calibration", "The last saved calibration at this gain was rejected. Review its waveform and checks before retrying.")
                if model.selectedRecord?.id != record.id || model.selectedRecord?.complete != true {
                    Button("View Last Calibration") { model.selectRecord(record) }
                }
            } else {
                instruction("Run a quiet calibration", "Cover the detector, let the signal settle and keep the leads still. Calibrate before taking Background or Source captures.")
            }
            HStack {
                Button("Calibrate", action: model.calibrate).buttonStyle(.borderedProminent)
                SetupHelpButton(topic: .baseline)
            }
            gainOptions
        case .ready:
            instruction(model.observationOnly ? "Record the signal" : "Take a measurement", model.observationOnly ? "Record Background or Source without quiet calibration. Raw samples and provisional candidate details save automatically." : "Start with Background. Choose Source when the source is in its measurement position. Each capture saves automatically.")
            if model.observationOnly && !model.gainConfirmed {
                Text("Physical gain is unconfirmed. The reported LOW/HIGH value is a stored setting. Verify J4 before using gain for comparisons.").font(.caption).foregroundStyle(.secondary)
            }
            if let record = model.activeCalibrationRecord {
                HStack {
                    Text("Session calibration · \(record.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("View Calibration") { model.selectRecord(record) }.buttonStyle(.borderless)
                }
            }
            if model.observationOnly {
                MainPulseControls(options: $mainOptions)
                    .disabled(model.sequenceRunning || model.busy || model.pendingUnsaved)
                if let frozen = model.measurementRun?.mainObservationOptions, model.canResumeRun {
                    Text("Continuing uses the saved criteria and detector label for this run (\(frozen.condition.label)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(model.observationOnly ? "Record Background" : "Capture Background") {
                    model.capture(tag: "BACKGROUND", mainOptions: captureOptions)
                }.buttonStyle(.borderedProminent)
                Button(model.observationOnly ? "Record Source" : "Capture Source") {
                    model.capture(tag: "SOURCE", mainOptions: captureOptions)
                }
                if !model.observationOnly { Button("Recalibrate", action: model.calibrate) }
            }.disabled(!pulseCriteriaValid || model.sequenceRunning)
            if model.burstSupported {
                Picker("Pulse profile", selection: Binding(get: { model.processingProfile }, set: model.selectProcessingProfile)) {
                    Text("Detector: negative").tag("NEGATIVE")
                    Text("Electrical test: positive").tag("POSITIVE")
                }.disabled(model.busy || model.pendingUnsaved || model.sequenceRunning || model.manualActive || model.stageActive)
                Text("\(model.calibrationProgress)").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("This firmware uses the original positive pulse profile. Update firmware for the negative detector profile.")
                    .font(.caption).foregroundStyle(.orange)
            }
            runPlan
            gainOptions
            Text("Captures include blind gaps. Each record retains its pulse profile and qualification flags. Radiation response and a valid count rate still require separate validation.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var runPlan: some View {
        DisclosureGroup("Run plan", isExpanded: $runPlanExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Finish after", selection: $timed) {
                    Text("Duration").tag(true); Text("Capture count").tag(false)
                }.pickerStyle(.segmented).frame(maxWidth: 320)
                runType
                if timed {
                    Picker("Duration", selection: $duration) {
                        Text("1 minute").tag(60); Text("5 minutes").tag(300)
                        Text("15 minutes").tag(900); Text("30 minutes").tag(1800)
                        Text("1 hour").tag(3600); Text("2 hours").tag(7200); Text("Custom").tag(0)
                    }.frame(maxWidth: 320)
                    if duration == 0 {
                        TextField("Seconds, from 1 to 7200", text: $customDuration).frame(maxWidth: 220)
                    }
                    Button("Start Timed Run") {
                        model.startTimedRun(tag: runTag, seconds: duration == 0 ? Double(customDuration) ?? 0 : Double(duration), mainOptions: captureOptions)
                    }.disabled(model.busy || !model.canRecordMeasurements || model.sequenceRunning || model.pendingUnsaved || !pulseCriteriaValid)
                    Text("Duration includes capture, transfer and saving, and excludes explicit pauses. The current capture finishes saving at the deadline. Recorded signal and blind gaps are shown separately.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { runCount; startRun }
                        VStack(alignment: .leading) { runCount; startRun }
                    }
                }
                if model.measurementRun != nil {
                    HStack {
                        Button("Export Run…") { model.requestExport(.run) }

                    }.disabled(!model.canExportFiles)
                    if model.exporting { Button("Cancel Export", action: model.cancelExport) }
                }
                if !model.savedRuns.isEmpty {
                    Menu("Saved runs") {
                        ForEach(model.savedRuns) { run in
                            Button("\(run.startedAt.formatted()) · \(run.tag.capitalized)") { model.restoreRun(run) }
                        }
                    }.disabled(model.busy || model.sequenceRunning)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
        }
    }

    private var runType: some View {
        Picker("Capture type", selection: $runTag) {
            Text("Background").tag("BACKGROUND")
            Text("Source").tag("SOURCE")
        }.fixedSize()
    }

    private var runCount: some View {
        HStack {
            Text("Captures")
            TextField("Number of captures", text: $captureCount)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
        }.fixedSize()
    }

    private var startRun: some View {
        Button(model.measurementRun == nil ? "Start Run" : "Start New Run") {
            if let plannedCount { model.startRun(tag: runTag, count: plannedCount, mainOptions: captureOptions) }
        }.disabled(plannedCount == nil || !pulseCriteriaValid || model.sequenceRunning || model.busy || model.pendingUnsaved)
    }

    private func runSummary(_ run: MeasurementRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(run.tag.capitalized) run").font(.headline)
                Spacer()
                Text(runStatus(run.phase)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            if model.currentSession?.id != run.sessionID {
                Text("Started in \(run.sessionName)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            ProgressView(value: run.durationSeconds == nil ? Double(run.completed) : min(run.durationSeconds!, run.elapsedSeconds), total: run.durationSeconds ?? Double(run.target)) {
                Text(run.durationSeconds == nil ? "\(run.completed.formatted()) of \(run.target.formatted()) windows saved and confirmed" : "\(run.completed.formatted()) windows saved and confirmed")
                    .font(.callout.monospacedDigit())
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 4) {
                    if let target = run.durationSeconds {
                        Text("Remaining \(max(0, target - run.elapsedSeconds).formatted(.number.precision(.fractionLength(0)))) seconds")
                            .font(.callout.monospacedDigit())
                    }
                    Text("Active elapsed \(run.elapsedSeconds.formatted(.number.precision(.fractionLength(1)))) s")
                    Text("Sampled \(run.sampledSeconds.formatted(.number.precision(.fractionLength(2)))) s · blind \(max(0, run.elapsedSeconds - run.sampledSeconds).formatted(.number.precision(.fractionLength(2)))) s")
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                runMetric(run.observationOnly ? "Pico candidates" : "Candidates", value: run.candidates)
                if !run.observationOnly { runMetric("Qualified pulses", value: run.qualifiedPulses) }
                runMetric(run.observationOnly ? "Flagged windows" : "Rejected windows", value: run.rejectedWindows)
            }
            if !model.runRecoveryNote.isEmpty { Text(model.runRecoveryNote).font(.caption).foregroundStyle(.secondary) }
            if run.observationOnly {
                Text("\(run.observationWindows.formatted()) raw windows. Pico candidates use its original settings. Review Noise Runs applies your pulse criteria to these saved windows.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Candidates are summed across saved windows. Qualified pulses passed the firmware checks in accepted windows.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Export This Run…") { model.requestExport(.run) }.disabled(!model.canExportFiles)
            switch run.phase {
            case .running:
                Button("Pause After This Capture", action: model.pauseRun)
            case .pausing:
                Text("Pausing after the current capture is saved and acknowledged.")
                    .font(.callout).foregroundStyle(.secondary)
            case .paused:
                Button("Resume Run", action: model.resumeRun)
                    .disabled(step != .ready || !model.canResumeRun)
                if step == .ready && !model.canResumeRun {
                    Text(continuationHint(run))
                        .font(.callout).foregroundStyle(.secondary)
                }
            case .interrupted:
                Button("Continue Run", action: model.resumeRun).disabled(!model.canResumeRun)
                Text(continuationHint(run))
                    .font(.callout).foregroundStyle(.secondary)
            case .completed:
                EmptyView()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
    }

    private func continuationHint(_ run: MeasurementRun) -> String {
        if run.workspace != "Manual", run.observationOnly != model.observationOnly {
            return run.observationOnly ? "Switch to Main to continue this raw observation run." : "Switch to Calibrated Run to continue this qualified run."
        }
        return run.observationOnly
            ? "Use the original session, profile and gain confirmation. Recover any pending capture before continuing."
            : "Use the original session, profile and gain confirmation with accepted quiet calibration. Recover any pending capture before continuing."
    }

    private func runMetric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value.formatted()).font(.title3.weight(.semibold).monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func runStatus(_ phase: MeasurementRun.Phase) -> String {
        switch phase {
        case .running: "Running"
        case .pausing: "Pausing"
        case .paused: "Paused"
        case .completed: "Complete"
        case .interrupted: "Interrupted"
        }
    }

    private var gainOptions: some View {
        DisclosureGroup("J4 gain settings") {
            gainControls.padding(.top, 6)
        }
    }

    private var gainControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack { gainPicker; gainActions }
            VStack(alignment: .leading, spacing: 8) { gainPicker; gainActions }
        }
    }

    private var gainPicker: some View {
        Picker("Physical gain", selection: $selectedGain) {
            Text("Low · open").tag("LOW")
            Text("High · shunt").tag("HIGH")
        }.labelsHidden().pickerStyle(.segmented).frame(width: 205)
    }

    private var gainActions: some View {
        HStack {
            Button("Confirm Gain") { showGainConfirmation = true }.buttonStyle(.borderedProminent)
            SetupHelpButton(topic: .gain)
        }
    }

    private func instruction(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progress(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView().controlSize(.small).padding(.top, 4)
            instruction(title, detail)
        }
    }
}

struct CalibrationDiagnosisView: View {
    let diagnosis: CalibrationDiagnosis

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(diagnosis.title).font(.headline).accessibilityAddTraits(.isHeader)
            Text(diagnosis.summary).foregroundStyle(.secondary)
            ForEach(diagnosis.reasons, id: \.self) { reason in
                Label(reason, systemImage: "exclamationmark.circle")
            }
            if !diagnosis.checks.isEmpty {
                Text("What to check").fontWeight(.semibold).padding(.top, 4)
                ForEach(diagnosis.checks, id: \.self) { check in Text(check) }
            }
        }
        .font(.callout)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
