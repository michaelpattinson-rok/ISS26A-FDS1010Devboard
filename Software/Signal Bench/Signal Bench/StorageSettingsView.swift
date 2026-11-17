import SwiftUI
import AppKit

struct StorageSettingsView: View {
    @EnvironmentObject private var model: BenchModel
    @State private var items: [StorageItem] = []
    @State private var pendingAction: StorageAction?
    @State private var message: String?
    private var storage: StorageManager? { model.appRootURL.map { StorageManager(root: $0) } }

    enum StorageAction: String, Identifiable {
        case cache, data
        var id: String { rawValue }
        var title: String {
            switch self {
            case .cache: "Clear Cache"
            case .data: "Delete App Data"
            }
        }
        var explanation: String {
            switch self {
            case .cache: "Removes the app cache inside Signal Bench Data."
            case .data: "Permanently removes the Support and Cache folders inside Signal Bench Data."
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Text("App data is stored in the selected Signal Bench folder. Each project contains its captures and exports. Select the folder again after relaunch.")
                    .foregroundStyle(.secondary)
                if let root = model.appRootURL {
                    LabeledContent("App Data Folder", value: root.path)
                    Button("Show App Data Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                } else {
                    Text("No Signal Bench folder is selected.").foregroundStyle(.secondary)
                }
                Button(model.appRootURL == nil ? "Choose App Data Folder" : "Change App Data Folder", action: model.chooseAppFolder)
                    .disabled(!model.canCreateProject || model.currentSession != nil)
                if model.sessionURL != nil {
                    Button("Show Project in Finder", action: model.openSessionFolder)
                    Button("Show Project Exports in Finder", action: model.openProjectExports).disabled(!model.canOpenProject)
                }
            } header: { Text("Storage") }
            Section {
                ForEach(items) { item in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).fontWeight(.medium)
                            Text(item.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Show in Finder") { storage?.reveal(item.url) }
                            .disabled(!FileManager.default.fileExists(atPath: item.url.path))
                    }.padding(.vertical, 3)
                }
                Button("Refresh Sizes") { refresh() }
                Button("Export App Data", action: exportData)
                    .disabled(!model.canExportFiles || model.pendingUnsaved || storage == nil || !FileManager.default.fileExists(atPath: storage?.appSupportURL.path ?? ""))
            } header: { Text("App Data") }
            Section {
                Button("Clear Cache") { pendingAction = .cache }.disabled(!model.canCreateProject || storage == nil)
                Button("Delete App Data", role: .destructive) { pendingAction = .data }.disabled(requiresClosedSession)
                if storage == nil {
                    Text("Choose the Signal Bench folder to manage app data.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if requiresClosedSession {
                    Text("Close the project and finish saving before deleting app data.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Manage Data") }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 600)
        .onAppear(perform: refresh)
        .onChange(of: model.appRootURL) { _, _ in refresh() }
        .alert(item: $pendingAction) { action in
            Alert(title: Text(action.title + "?"), message: Text(action.explanation),
                  primaryButton: .destructive(Text(action.title)) { perform(action) },
                  secondaryButton: .cancel())
        }
        .alert("Storage", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }

    private var requiresClosedSession: Bool { !model.canCreateProject || model.currentSession != nil || storage == nil }
    private func refresh() {
        guard let storage else { items = []; return }
        do { items = try model.withAppFolderAccess { try storage.inventory() } }
        catch { items = []; message = "Could not inspect the Signal Bench folder: \(error.localizedDescription)" }
    }
    private func perform(_ action: StorageAction) {
        guard model.canCreateProject else { message = "Finish saving before managing data."; return }
        if action == .data && model.currentSession != nil { message = "Close the project first."; return }
        guard let storage else { message = "Choose the Signal Bench folder first."; return }
        do {
            switch action {
            case .cache: try model.withAppFolderAccess { try storage.clearCache() }
            case .data: try model.withAppFolderAccess { try storage.deleteAppData() }
            }
            refresh()
        } catch { message = "Could not complete the action: \(error.localizedDescription)"; refresh() }
    }
    private func exportData() {
        guard model.canExportFiles, !model.pendingUnsaved else { return }
        guard let storage, let root = model.appRootURL else { message = "Choose the Signal Bench folder first."; return }
        let panel = NSSavePanel()
        panel.title = "Export App Data"
        panel.message = "Choose a destination inside the Signal Bench folder."
        panel.directoryURL = root
        panel.nameFieldStringValue = "Signal Bench App Data"
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.withAppFolderAccess {
                try model.checkExportAvailability()
                guard model.appRootURL == root, !model.pendingUnsaved else {
                    throw SBProtocolError.invalid("The storage state changed. Choose Export App Data again.")
                }
                try storage.exportAppData(to: url)
            }
        } catch { message = "Could not export app data. \(error.localizedDescription)" }
    }
}
