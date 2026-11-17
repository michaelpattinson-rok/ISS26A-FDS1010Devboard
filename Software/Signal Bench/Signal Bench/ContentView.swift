import SwiftUI

private enum BenchWorkspace: String, CaseIterable {
    case measurements = "Main", calibrated = "Calibrated Run", legacy = "Legacy Measurements", manual = "Manual", stages = "Diagnosis"
}

struct ContentView: View {
    @EnvironmentObject private var model: BenchModel
    @State private var projectSheet: ProjectSheet?
    @State private var showRecoveryConfirmation = false
    @State private var recoveryRequest: RecoveryRequest?
    @State private var setupOpen = false
    @State private var diagnosticsOpen = false
    @State private var workspace = BenchWorkspace.measurements

    private enum ProjectSheet: Identifiable {
        case rename(SessionMetadata), details(SessionMetadata), trash(ProjectTrashSelection)

        var id: UUID {
            switch self {
            case .rename(let project), .details(let project): project.id
            case .trash(let selection): selection.id
            }
        }
    }

    private struct RecoveryRequest {
        let token: String
        let sessionID: UUID
        let sessionName: String
        let unlinked: Bool
    }

    private func requestRecovery() {
        guard model.recoveryMatchesSession, let token = model.pendingCaptureToken,
              let session = model.currentSession else { return }
        recoveryRequest = .init(token: token, sessionID: session.id, sessionName: session.name,
                                unlinked: model.recoveryIsUnlinked)
        showRecoveryConfirmation = true
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 195, ideal: 235)
        } detail: {
            VStack(spacing: 0) {
                if workspace != .measurements && model.appRootURL == nil {
                    HStack {
                        Label(model.currentSession == nil ? "Choose the Signal Bench folder for app data." : "Close the project to choose the app data folder.", systemImage: "folder.badge.questionmark")
                        Spacer()
                        Button("Choose Folder", action: model.chooseAppFolder)
                            .disabled(model.busy || model.stageActive || model.pendingUnsaved || model.currentSession != nil)
                    }.font(.callout).padding(.horizontal, 22).padding(.vertical, 10)
                    Divider()
                }
                connectionBar
                Divider()
                if workspace == .manual {
                    ManualBenchView().environmentObject(model)
                } else if workspace == .stages {
                    StageDiagnosticsView().environmentObject(model)
                } else if workspace == .measurements {
                    MainRecordingView()
                } else if workspace == .calibrated {
                    CalibratedRunView()
                } else {
                    measurementContent
                }
            }
            .frame(minWidth: 520, minHeight: 460)
        }
        .disabled(model.shutdownInProgress)
        .overlay {
            if model.shutdownInProgress {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Finishing before quitting").font(.headline)
                    Text("The current capture and saved progress are being resolved.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Workspace", selection: $workspace) {
                    ForEach(BenchWorkspace.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu).frame(maxWidth: 180).disabled(model.busy || model.sequenceRunning || model.manualActive || model.stageActive)
                Button("Setup Guide", systemImage: "checklist") { setupOpen = true }
                Button("Connection Diagnostics", systemImage: "cable.connector") { diagnosticsOpen = true }
                if workspace != .measurements {
                    Menu("Export", systemImage: "square.and.arrow.up") {
                        Button("Selected Record…") { model.requestExport(.record) }.disabled(model.selectedRecord == nil)
                        Button("Current Run…") { model.requestExport(.run) }.disabled(model.measurementRun == nil)
                        Button("Entire Project…") { model.requestExport(.session) }.disabled(model.currentSession == nil)
                    }.disabled(!model.canExportFiles)
                }
                Button("New Project", systemImage: "plus", action: model.createSession).disabled(!model.canCreateProject)
                Button("Open Project", systemImage: "folder", action: model.openSession).disabled(!model.canOpenProject)
                projectActions
            }
        }
        .alert(recoveryRequest?.unlinked == true ? "Import an unlinked record?" : "Recover the pending capture?",
               isPresented: $showRecoveryConfirmation, presenting: recoveryRequest) { request in
            Button(request.unlinked ? "Import Unlinked Record" : "Recover Record") {
                model.retryPending(allowUnlinked: request.unlinked, expectedToken: request.token, expectedSession: request.sessionID)
            }
            Button("Cancel", role: .cancel) { }
        } message: { request in
            Text(request.unlinked
                 ? "This older capture has no verified original project. Import into \(request.sessionName) with its original setup marked unknown."
                 : "Signal Bench will check the capture receipt in \(request.sessionName) before retrieving the record.")
        }
        .sheet(item: $model.exportScope) { scope in
            ExportOptionsView(scope: scope, recordCount: model.exportRecordCount,
                              projectFolderAvailable: model.appRootURL != nil,
                              onExport: model.exportSelectedData)
        }
        .sheet(item: $projectSheet) { sheet in
            switch sheet {
            case .rename(let project):
                ProjectRenameView(project: project) { name in
                    try model.saveProjectDetails(name: name, details: project.details, expected: project)
                }
            case .details(let project):
                ProjectDetailsView(project: project) { details in
                    try model.saveProjectDetails(name: project.name, details: details, expected: project)
                }
            case .trash(let selection):
                ProjectTrashView(selection: selection) { typedName in
                    try model.moveProjectToTrash(selection, typedName: typedName)
                }
            }
        }
        .sheet(isPresented: $setupOpen) { SetupGuideView().environmentObject(model) }
        .sheet(isPresented: $diagnosticsOpen) { ConnectionDiagnosticsView().environmentObject(model) }
        .alert("Signal Bench", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onAppear {
            refreshAvailableDevices()
            if workspace == .measurements { model.setObservationOnly(true) }
            if workspace == .calibrated || workspace == .legacy { model.setObservationOnly(false) }
        }
        .task {
            while !Task.isCancelled {
                if !model.connected && !model.busy && !model.shutdownInProgress { refreshAvailableDevices() }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
            }
        }
        .onChange(of: model.busy) { _, busy in
            guard !busy, model.connected, !model.sequenceRunning else { return }
            if workspace == .measurements { model.setObservationOnly(true) }
            if workspace == .calibrated || workspace == .legacy { model.setObservationOnly(false) }
        }
        .onChange(of: workspace) { old, new in
            if new == .measurements { model.setObservationOnly(true) }
            if new == .calibrated || new == .legacy { model.setObservationOnly(false) }
            if old == .manual && new != .manual { model.exitManual() }
            if old == .stages && new != .stages { model.exitStageDiagnostics() }
        }
    }

    private var projectActions: some View {
        Menu("Project Actions", systemImage: "ellipsis.circle") {
            Button("Rename Project…") {
                if let project = model.currentSession { projectSheet = .rename(project) }
            }.disabled(!model.canManageProject)
            Button("Project Details…") {
                if let project = model.currentSession { projectSheet = .details(project) }
            }.disabled(!model.canManageProject)
            Divider()
            Button("Show Project in Finder", action: model.openSessionFolder)
                .disabled(model.currentSession == nil)
            Button("Show Exports in Finder", action: model.openProjectExports)
                .disabled(model.currentSession == nil || !model.canOpenProject)
            Button("Show Last Export in Finder", action: model.showLastExport)
                .disabled(model.lastExportURL == nil)
            Divider()
            Button("Close Project", action: model.closeSession).disabled(!model.canManageProject)
            Button("Move Project to Trash…", role: .destructive) {
                do { projectSheet = .trash(try model.projectTrashSelection()) }
                catch { model.error = error.localizedDescription }
            }.disabled(!model.canManageProject)
        }
        .disabled(model.currentSession == nil)
    }

    private var sidebarRecords: [CaptureRecord] {
        model.records.filter { $0.metadata["host_profile_purpose"] != ProfileAcquisition.Purpose.calibrationPhase.rawValue }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PROJECT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let folder = model.sessionURL {
                    Button("Open in Finder", systemImage: "folder", action: model.openSessionFolder)
                        .labelStyle(.iconOnly).help(folder.path)
                }
            }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)
            if let session = model.currentSession {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "folder.fill").foregroundStyle(.tint).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.name).font(.headline).lineLimit(2)
                        Text(session.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 16).padding(.bottom, 15)
                if workspace == .measurements || workspace == .calibrated {
                    Spacer()
                } else {
                    Divider().padding(.horizontal, 12)
                    HStack {
                        Text("RECORDS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(sidebarRecords.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 5)
                    if sidebarRecords.isEmpty {
                        Text("Captures will appear here.").font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        Spacer()
                    } else {
                        List {
                            ForEach(Array(sidebarRecords.enumerated()), id: \.offset) { _, record in
                                Button { model.selectRecord(record) } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: record.complete ? "waveform.path" : "exclamationmark.circle")
                                            .foregroundStyle(record.complete ? Color.accentColor : Color.orange)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(recordTitle(record)).fontWeight(.medium)
                                            Text(record.capturedAt, style: .time).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }.contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(model.selectedRecord?.id == record.id && model.selectedRecord?.capturedAt == record.capturedAt && model.selectedRecord?.complete == record.complete ? Color.accentColor.opacity(0.16) : Color.clear)
                            }
                        }.listStyle(.sidebar)
                    }
                }
            } else {
                Text("No project open").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                Spacer()
            }
        }
    }

    private func refreshAvailableDevices() {
        model.refreshPorts()
        if model.selectedPort.isEmpty, model.ports.count == 1 { model.selectedPort = model.ports[0] }
    }

    private var connectionBar: some View {
        HStack(spacing: 12) {
            Circle().fill(model.connected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.connectionStatus).font(.callout.weight(.semibold))
                Text(model.connected ? model.deviceInfo : "Pico W over USB").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            if !model.connected {
                Picker("Device", selection: $model.selectedPort) {
                    Text("Select a device").tag("")
                    ForEach(model.ports, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(maxWidth: 230)
                Button("Refresh", systemImage: "arrow.clockwise", action: refreshAvailableDevices).labelStyle(.iconOnly).help("Refresh devices")
                Button("Connect", action: model.connect).disabled(model.selectedPort.isEmpty || model.busy)
            } else {
                if model.pendingUnsaved && workspace != .measurements {
                    Button("Recover Capture", action: requestRecovery).disabled(model.busy || !model.recoveryMatchesSession)
                }
                Button("Disconnect", action: model.disconnect).disabled(model.busy)
            }
        }.padding(.horizontal, 22).padding(.vertical, 12)
    }

    private func recordTitle(_ record: CaptureRecord) -> String {
        let title = record.metadata["tag"] == "CAL" ? "Calibration" : record.metadata["tag"]?.capitalized ?? "Record"
        return record.metadata["capture_provenance"] == "unlinked" ? "Imported \(title.lowercased())" : title
    }

    private var measurementContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let session = model.currentSession {
                    HStack(alignment: .top) {
                        Text(session.name).font(.title2.weight(.semibold))
                        Spacer()
                        Button("Details", systemImage: "slider.horizontal.3") { projectSheet = .details(session) }
                            .disabled(!model.canManageProject)
                    }
                }
                MeasurementWorkflowView(openSetup: { setupOpen = true }, confirmRecovery: requestRecovery)
                if let record = model.selectedRecord {
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(recordTitle(record)).font(.title3.weight(.semibold))
                            Text(record.capturedAt, format: .dateTime.month().day().hour().minute())
                                .foregroundStyle(.secondary).font(.callout)
                        }
                        Spacer()
                        Label(record.complete ? "Saved to project" : "Incomplete transfer",
                              systemImage: record.complete ? "checkmark.circle" : "exclamationmark.circle")
                            .font(.caption)
                        Button("Export…", systemImage: "square.and.arrow.up") { model.requestExport(.record) }
                            .disabled(!model.canExportFiles)
                    }
                    if record.metadata["capture_provenance"] == "unlinked" {
                        Label("Original setup unknown. The date is the import time.", systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if let id = record.metadata["calibration_record_id"] {
                        if let calibration = model.records.first(where: { $0.complete && $0.id == id }) {
                            Button("View Capture Calibration") { model.selectRecord(calibration) }
                                .buttonStyle(.link)
                        } else {
                            Text("The linked calibration record is unavailable in this project.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if let diagnosis = CalibrationDiagnosis.forRecord(record) {
                        CalibrationDiagnosisView(diagnosis: diagnosis)
                    }
                    if record.metadata["observation_only"] == "1" {
                        Label("Raw observation · provisional candidates · no qualified pulses", systemImage: "waveform.path")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    WaveformView(record: record)
                    SignalAnalysisView(record: record, canSave: model.canExportFiles && !model.shutdownInProgress, onSave: model.saveAnalysis)
                    SavedAnalysesView(analyses: model.savedAnalyses)
                    RecordComparisonView(record: record, records: model.records)
                    RecordDetailsView(record: record)
                } else if model.currentSession != nil {
                    Text("Saved records appear in the project sidebar.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

