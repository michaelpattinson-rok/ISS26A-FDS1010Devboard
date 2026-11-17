import SwiftUI

struct ExportOptionsView: View {
    let scope: ExportScope
    let recordCount: Int
    var projectFolderAvailable = false
    let onExport: (ExportOptions) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var options: ExportOptions

    init(scope: ExportScope, recordCount: Int, projectFolderAvailable: Bool = false,
         onExport: @escaping (ExportOptions) -> Void) {
        self.scope = scope; self.recordCount = recordCount
        self.projectFolderAvailable = projectFolderAvailable; self.onExport = onExport
        _options = State(initialValue: ExportOptions(scope: scope))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Export data").font(.title2.weight(.semibold))
                Text("\(scope.title) · \(recordCount) record\(recordCount == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("Include") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Record metadata and notes as JSON", isOn: $options.metadataJSON)
                            Toggle("Candidate details as CSV", isOn: $options.candidatesCSV)
                            Toggle("Quality and acquisition details as CSV", isOn: $options.qualityCSV)
                            Toggle("Related calibration records as JSON", isOn: $options.calibrationsJSON)
                            Toggle("Saved Mac analyses", isOn: $options.savedAnalyses)
                            Toggle("Raw samples as CSV", isOn: $options.rawCSV)
                            Toggle("Original sample words as binary", isOn: $options.rawBinary)
                            Toggle("Incomplete and recovery records", isOn: $options.includeIncomplete)
                        }.toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    Label("Saved in the open Project’s Exports folder.", systemImage: "folder")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Every export includes a summary with completeness, calibration, raw observation status, processing profile and measurement limits. Candidate counts can include electrical noise. Millivolts and sample timing remain nominal.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export") { onExport(options); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(recordCount == 0)
            }
        }.padding(24).frame(minWidth: 470, idealWidth: 530, maxWidth: 620, minHeight: 560)
    }
}
