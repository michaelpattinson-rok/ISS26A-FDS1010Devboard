import SwiftUI

struct RunBatchExportRequest: Identifiable {
    let id = UUID()
    let projectID: UUID
    let runs: [StreamRun]
}

struct RunBatchExportSheet: View {
    let request: RunBatchExportRequest
    let export: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var name = "Signal Bench Runs"

    var body: some View {
        let filename = try? ProjectArchive.filename(name)
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Runs as ZIP").font(.title2.weight(.semibold))
            Text("Save \(request.runs.count) selected \(request.runs.count == 1 ? "run" : "runs") in one archive. Each run gets its own folder.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(request.runs) { run in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(run.name).fontWeight(.medium).lineLimit(1)
                                Text(run.created, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "waveform").foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 144)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text("Archive name").font(.headline)
                TextField("Archive name", text: $name)
                    .textFieldStyle(.roundedBorder).focused($nameFocused)
                Text(filename ?? "Enter a valid ZIP name.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choose Destination…") {
                    export(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(filename == nil)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear { nameFocused = true }
    }
}
