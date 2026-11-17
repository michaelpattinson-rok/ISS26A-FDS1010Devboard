import SwiftUI

struct MainRecordingView: View {
    @EnvironmentObject private var model: BenchModel
    @State private var hours = 0
    @State private var minutes = 5
    @State private var requestedExport: ProjectCSVSource?
    @State private var armedRun: UUID?
    @State private var confirmUnlinked = false
    @State private var recoveryToken: String?
    @State private var recoveryProject: UUID?

    private var run: MeasurementRun? {
        guard let run = model.measurementRun, run.observationOnly, run.profileAcquisition == nil, run.workspace == "Measurements",
              run.sessionID == model.currentSession?.id else { return nil }
        return run
    }

    private var duration: Int { 60 * hours + minutes }

    private var savedRuns: [RunArchive] {
        model.savedRuns.filter { $0.observationOnly == true && $0.profileAcquisition == nil && $0.workspace == "measurements" }
            .sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Main").font(.largeTitle.weight(.semibold))
                    Text("Record raw signal from GP26 for a set time. Signal Bench saves short windows with gaps between them.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let run, run.inProgress {
                    activeRun(run)
                } else {
                    setup
                }
                if model.exporting {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Writing export…").foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel Export", action: model.cancelExport)
                    }
                }
                if let run, !run.inProgress, run.completed > 0,
                   savedRuns.contains(where: { $0.id == run.id }) {
                    GroupBox {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(run.phase == .completed ? "Recording saved" : "Interrupted recording").font(.headline)
                                Text("\(run.completed.formatted()) windows saved").foregroundStyle(.secondary)
                            }
                            Spacer()
                            ProjectCSVExportButton(title: "Export Raw CSV…", source: .waveformRun(run.id))
                                .buttonStyle(.borderedProminent)
                        }.padding(6)
                    }
                }
                if !savedRuns.isEmpty {
                    Menu("Saved Main recordings") {
                        ForEach(savedRuns) { saved in
                            Button("\(saved.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(saved.phase == "completed" ? "Saved" : "Interrupted")") {
                                requestedExport = .waveformRun(saved.id)
                            }
                        }
                    }
                    .disabled(!model.canExportFiles)
                }
            }
            .frame(maxWidth: 650, alignment: .leading)
            .padding(26).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: model.savedRuns.map { "\($0.id):\($0.phase)" }) { _, _ in
            guard let armedRun, let saved = savedRuns.first(where: { $0.id == armedRun }),
                  saved.phase == "completed", saved.completed > 0 else { return }
            offerFinishedExport(saved)
        }
        .onChange(of: model.busy) { _, busy in
            guard !busy, let armedRun, let saved = savedRuns.first(where: { $0.id == armedRun }),
                  saved.phase == "completed", saved.completed > 0 else { return }
            offerFinishedExport(saved)
        }
        .onChange(of: model.currentSession?.id) { _, _ in
            armedRun = nil
            requestedExport = nil
        }
        .sheet(item: $requestedExport) { ProjectCSVExportView(source: $0) }
        .alert("Import this older record?", isPresented: $confirmUnlinked) {
            Button("Import Record") { model.retryPending(allowUnlinked: true, expectedToken: recoveryToken, expectedSession: recoveryProject) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The original setup is unknown. This imports the record into the open Project with that status.")
        }
    }

    private func offerFinishedExport(_ saved: RunArchive) {
        guard model.canExportFiles else { return }
        armedRun = nil
        requestedExport = .waveformRun(saved.id)
    }

    @ViewBuilder private var setup: some View {
        if model.pendingUnsaved {
            GroupBox("Recover a pending recording") {
                VStack(alignment: .leading, spacing: 10) {
                    if !model.connected {
                        Text("Keep the Pico powered. Reconnect to check whether it still holds the record.")
                    } else if !model.recoveryMatchesSession {
                        Text("Open the Project where this capture began.")
                        Button("Open Project", action: model.openSession)
                    } else {
                        if let issue = model.captureSaveIssue { Text(issue).textSelection(.enabled) }
                        Button(model.recoveryIsUnlinked ? "Import Unlinked Record…" : "Retry Saving Record") {
                            recoveryToken = model.pendingCaptureToken
                            recoveryProject = model.currentSession?.id
                            if model.recoveryIsUnlinked { confirmUnlinked = true }
                            else { model.retryPending(expectedToken: recoveryToken, expectedSession: recoveryProject) }
                        }.disabled(model.busy)
                    }
                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if model.currentSession == nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose a Project for your recordings.").font(.headline)
                HStack {
                    Button("New Project…", action: model.createSession).buttonStyle(.borderedProminent)
                        .disabled(!model.canCreateProject)
                    Button("Open Project…", action: model.openSession).disabled(!model.canOpenProject)
                }
            }
        } else if !model.connected {
            Text("Connect the Pico W by USB to start recording.").foregroundStyle(.secondary)
        } else if !model.observationsSupported {
            Text("This firmware does not support raw recording. Connect a Pico W running Signal Bench firmware 1.5.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recording time").font(.headline)
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Hours").font(.callout)
                        TextField("Hours", value: $hours, format: .number.grouping(.never))
                            .labelsHidden().accessibilityLabel("Hours")
                    }.frame(width: 85)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Minutes").font(.callout)
                        TextField("Minutes", value: $minutes, format: .number.grouping(.never))
                            .labelsHidden().accessibilityLabel("Minutes")
                    }.frame(width: 85)
                }
                Button("Start Recording", systemImage: "record.circle") {
                    guard (0...2).contains(hours), (0...59).contains(minutes), (1...120).contains(duration) else { return }
                    let prior = model.measurementRun?.id
                    model.startTimedRun(tag: "BACKGROUND", seconds: Double(duration * 60))
                    if model.measurementRun?.id != prior { armedRun = model.measurementRun?.id }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!(0...2).contains(hours) || !(0...59).contains(minutes) ||
                          model.busy || model.manualCSVBusy || !model.observationOnly || !(1...120).contains(duration))
                Text("Choose 1 minute to 2 hours. Time includes capture, transfer and saving.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func activeRun(_ run: MeasurementRun) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let target = max(1, run.durationSeconds ?? 1)
                    let elapsed = min(target, run.elapsedSeconds)
                    let remaining = Duration.seconds(max(0, (target - elapsed).rounded(.up)))
                    ProgressView(value: elapsed, total: target) {
                        Text("\(remaining.formatted(.time(pattern: .hourMinuteSecond))) remaining")
                            .font(.headline.monospacedDigit())
                    }
                }
                Text("\(run.completed.formatted()) windows saved · \(model.status)")
                    .font(.callout).foregroundStyle(.secondary)
                Button(run.phase == .pausing ? "Finishing This Capture…" : "Stop After This Capture",
                       action: model.stopMainRun)
                    .disabled(run.phase == .pausing)
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
