import SwiftUI

struct ProjectArchiveSheet: View {
    let request: ProjectArchiveRequest
    let export: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var name = "Signal Bench Projects"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Projects as ZIP").font(.title2.weight(.semibold))
            Text("The ZIP contains the complete saved files for each selected Project.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(request.folders, id: \.self) { folder in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(folder.lastPathComponent).fontWeight(.medium)
                                Text(folder.deletingLastPathComponent().path)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        } icon: {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 155)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text("Archive name").font(.headline)
                TextField("Archive name", text: $name)
                    .labelsHidden().textFieldStyle(.roundedBorder).focused($nameFocused)
                if let filename = try? ProjectArchive.filename(name) {
                    Text(filename).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choose Destination…") {
                    export(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled((try? ProjectArchive.filename(name)) == nil)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear { nameFocused = true }
    }
}
