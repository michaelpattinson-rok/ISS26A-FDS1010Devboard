import SwiftUI

struct BurstCaptureControls: View {
    @EnvironmentObject private var model: BenchModel
    let workspace: String
    @State private var channel = 0
    @State private var confirmRelease = false
    @State private var burstCount = 10
    @State private var timed = false
    @State private var duration = 300
    @State private var customSeconds = "300"

    private var runSeconds: Double? {
        guard let seconds = duration == 0 ? Double(customSeconds) : Double(duration),
              seconds.isFinite, (1...7200).contains(seconds) else { return nil }
        return seconds
    }

    private var canStartManualRun: Bool {
        model.calibrated && model.gainConfirmed && model.connected && model.currentSession != nil && !model.manualActive &&
            !model.busy && !model.sequenceRunning && !model.pendingUnsaved && !model.manualCSVBusy
    }

    var body: some View {
        GroupBox("Waveform recording") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Save a finite waveform at nominally 100,000 samples per second. Every burst keeps its raw samples and processing details in the selected session.")
                    .font(.callout).foregroundStyle(.secondary)
                if !model.burstSupported {
                    Label("Connect firmware with waveform burst support.", systemImage: "info.circle")
                } else {
                    if workspace == "Stage Diagnostics" {
                        Picker("Signal", selection: $channel) {
                            Text("Final ADC0").tag(0)
                            Text("GP27: \(model.stageLabels[0].rawValue)").tag(1)
                            Text("GP28: \(model.stageLabels[1].rawValue)").tag(2)
                        }.disabled(model.busy || model.stageActive)
                    }
                    if model.currentSession == nil {
                        HStack { Button("New Project", action: model.createSession); Button("Open Project", action: model.openSession) }
                    }
                    HStack {
                        Button("Confirm Low Gain") { model.changeGain("LOW") }
                        Button("Confirm High Gain") { model.changeGain("HIGH") }
                    }.disabled(model.busy || model.pendingUnsaved || model.manualActive || model.stageActive)
                    Text("Confirm the actual J4 position. Remove USB before changing it.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Quiet Calibration", action: model.calibrate)
                            .disabled(model.busy || !model.gainConfirmed || model.manualActive || model.stageActive || model.currentSession == nil)
                        Button(model.manualActive ? "Release Outputs and Stop" : "Record Waveform") {
                            if model.manualActive { confirmRelease = true }
                            else { model.recordBurst(workspace: workspace, channel: channel) }
                        }.buttonStyle(.borderedProminent)
                            .disabled(model.busy || model.pendingUnsaved || model.stageActive || model.sequenceRunning ||
                                      model.manualCSVBusy || model.currentSession == nil || !model.gainConfirmed ||
                                      (workspace == "Manual" && !model.manualActive && !model.calibrated))
                    }
                    if workspace == "Manual" {
                        manualRun
                    }
                    Text(model.calibrationProgress).font(.caption).foregroundStyle(.secondary)
                    Text(workspace == "Manual" ? "Stop GPIO control, then calibrate before recording. Sparse monitor readings have no pulse counts." : "Stop live diagnostics first. Optional stages provide waveform and noise statistics. Final ADC0 qualification needs a matching quiet calibration.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let record = model.selectedRecord, record.metadata["host_workspace"] == (workspace == "Manual" ? "manual" : "stage") {
                        HStack {
                            Text("Saved waveform").font(.headline)
                            Spacer()
                            ProjectCSVExportButton(title: "Export Waveform CSV…", source: .record(record.id))
                        }
                        Text("Firmware result: \(record.metadata["candidates"] ?? "0") candidates · \(record.events.filter { $0["qualified"] == "1" }.count) qualified pulses")
                            .font(.caption.monospacedDigit())
                        WaveformView(record: record)
                        SignalAnalysisView(record: record, canSave: model.canExportFiles && !model.shutdownInProgress, onSave: model.saveAnalysis)
                        SavedAnalysesView(analyses: model.savedAnalyses)
                    }
                }
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Release Manual outputs?", isPresented: $confirmRelease) {
            Button("Release Outputs and Stop", action: model.exitManual)
        } message: { Text("All controllable pins return to inputs. After Stop, run quiet calibration and choose Record Waveform. Earlier output states stay released.") }
    }

    private var manualRun: some View {
        DisclosureGroup("Waveform run") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Finish after", selection: $timed) {
                    Text("Capture count").tag(false)
                    Text("Duration").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                .disabled(model.sequenceRunning)
                if timed {
                    Picker("Duration", selection: $duration) {
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                        Text("15 minutes").tag(900)
                        Text("30 minutes").tag(1800)
                        Text("1 hour").tag(3600)
                        Text("2 hours").tag(7200)
                        Text("Custom").tag(0)
                    }
                    .frame(maxWidth: 260)
                    .disabled(model.sequenceRunning)
                    if duration == 0 {
                        TextField("1 to 7,200 seconds", text: $customSeconds)
                            .frame(maxWidth: 180)
                            .accessibilityLabel("Custom duration in seconds")
                            .disabled(model.sequenceRunning)
                    }
                    Text("Duration includes transfer and saving. The last burst finishes saving before the run stops.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Stepper("\(burstCount) waveform bursts", value: $burstCount, in: 1...1000)
                        .disabled(model.sequenceRunning)
                }
                Button("Start Waveform Run") {
                    if timed {
                        if let runSeconds { model.startTimedRun(tag: "MANUAL", seconds: runSeconds, workspace: "Manual") }
                    } else {
                        model.startRun(tag: "MANUAL", count: burstCount)
                    }
                }
                .disabled(!canStartManualRun || (timed && runSeconds == nil))
                if let run = model.measurementRun, run.tag == "MANUAL" {
                    if model.sequenceRunning {
                        Button("Pause After This Capture", action: model.pauseRun)
                    } else if model.canResumeRun {
                        Button("Continue Run", action: model.resumeRun)
                    }
                    Text("\(run.completed) saved · \(run.candidates) candidates · \(run.qualifiedPulses) qualified · \(run.rejectedWindows) rejected windows")
                        .font(.caption.monospacedDigit())
                    if let duration = run.durationSeconds {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let remaining = Duration.seconds(max(0, duration - run.elapsedSeconds))
                            Text("\(remaining.formatted(.time(pattern: .hourMinuteSecond))) remaining")
                                .font(.caption.monospacedDigit())
                        }
                    }
                    if run.completed > 0 {
                        ProjectCSVExportButton(title: "Export Waveform Run CSV…", source: .waveformRun(run.id))
                    }
                }
                let saved = model.savedRuns.filter { $0.tag == "MANUAL" }
                if !saved.isEmpty {
                    Menu("Saved waveform runs") {
                        ForEach(saved) { run in
                            Button(run.startedAt.formatted(date: .abbreviated, time: .standard)) { model.restoreRun(run) }
                        }
                    }
                    .disabled(model.busy || model.sequenceRunning || model.manualActive || model.manualCSVBusy)
                }
            }
            .padding(.top, 5)
        }
    }
}
