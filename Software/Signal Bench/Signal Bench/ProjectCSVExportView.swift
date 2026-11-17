import SwiftUI

struct ProjectCSVExportButton: View {
    @EnvironmentObject private var model: BenchModel
    let title: String
    let source: ProjectCSVSource
    @State private var export = false

    var body: some View {
        Button(title) { export = true }
            .disabled(!model.canExportFiles)
            .sheet(isPresented: $export) { ProjectCSVExportView(source: source) }
    }
}

struct ProjectCSVExportView: View {
    @EnvironmentObject private var model: BenchModel
    @Environment(\.dismiss) private var dismiss
    let source: ProjectCSVSource
    @State private var name: String
    @State private var description = ""

    init(source: ProjectCSVSource) {
        self.source = source
        _name = State(initialValue: source.defaultName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Export Raw CSV").font(.title2.weight(.semibold))
                Text("Saved to the open Project’s Exports folder.").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Filename").font(.callout.weight(.medium))
                TextField("Filename", text: $name).labelsHidden().accessibilityLabel("CSV filename")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Description").font(.callout.weight(.medium))
                TextEditor(text: $description)
                    .font(.body).frame(height: 84)
                    .padding(4).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("CSV description")
                Text("The filename and description are included on the first sample row.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !name.isEmpty && ProjectCSVRequest(filename: name, description: description) == nil {
                Text("Enter a filename without slashes and a description of up to 4,096 bytes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export CSV") {
                    guard let request = ProjectCSVRequest(filename: name, description: description) else { return }
                    if model.exportProjectCSV(source, request: request) { dismiss() }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(ProjectCSVRequest(filename: name, description: description) == nil || !model.canExportFiles)
            }
        }
        .padding(22).frame(width: 470)
    }
}
