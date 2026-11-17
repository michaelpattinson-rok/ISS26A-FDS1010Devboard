import AppKit
import SwiftUI

struct ProjectRenameView: View {
    let project: SessionMetadata
    let save: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var name: String
    @State private var issue: String?

    init(project: SessionMetadata, save: @escaping (String) throws -> Void) {
        self.project = project
        self.save = save
        _name = State(initialValue: project.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Project").font(.title2.weight(.semibold))
            Text("Update the name shown in Signal Bench.").foregroundStyle(.secondary)
            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onChange(of: name) { _, _ in issue = nil }
            if let issue { Text(issue).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") {
                    do {
                        try save(name)
                        dismiss()
                    } catch {
                        issue = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == project.name)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { nameFocused = true }
    }
}

struct ProjectDetailsView: View {
    let save: ([String: String]) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var details: [String: String]
    @State private var issue: String?

    init(project: SessionMetadata, save: @escaping ([String: String]) throws -> Void) {
        self.save = save
        _details = State(initialValue: project.details)
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { details[key, default: ""] }, set: { details[key] = $0; issue = nil })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Project Details").font(.title2.weight(.semibold))
            Form {
                TextField("Board", text: binding("board"))
                TextField("Detector", text: binding("detector"))
                TextField("Enclosure", text: binding("enclosure"))
                TextField("Source geometry", text: binding("geometry"))
                TextField("Notes", text: binding("notes"), axis: .vertical).lineLimit(3...6)
            }
            .formStyle(.grouped)
            if let issue { Text(issue).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try save(details)
                        dismiss()
                    } catch {
                        issue = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480, height: 420)
    }
}

struct ProjectTrashView: View {
    let selection: ProjectTrashSelection
    let move: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var confirmationFocused: Bool
    @State private var typedName = ""
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Move Project to Trash?", systemImage: "trash")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text(selection.name).font(.headline)
                Text(selection.folder.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("The entire folder will move to the Trash, including captures, incomplete records, run progress and exports stored inside it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Type the project name to confirm", text: $typedName)
                .textFieldStyle(.roundedBorder)
                .focused($confirmationFocused)
                .onChange(of: typedName) { _, _ in issue = nil }
            if let issue {
                Text(issue).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("Show Folder in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([selection.folder])
                }
                .buttonStyle(.link)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive) {
                    do {
                        try move(typedName)
                        dismiss()
                    } catch {
                        issue = error.localizedDescription
                    }
                }
                .buttonStyle(.bordered)
                .disabled(typedName != selection.name)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { confirmationFocused = true }
    }
}
