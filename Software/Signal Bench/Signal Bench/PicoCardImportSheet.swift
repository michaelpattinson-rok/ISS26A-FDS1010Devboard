import SwiftUI

struct PicoCardImportSheet: View {
    let request: PicoCardRequest
    let action: ([PicoCardImport.Preview], PicoCardImport.Wiring, Date?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID>
    @State private var wiring = PicoCardImport.Wiring.unknown
    @State private var addDate = false
    @State private var date = Date()

    init(request: PicoCardRequest, action: @escaping ([PicoCardImport.Preview], PicoCardImport.Wiring, Date?) -> Void) {
        self.request = request
        self.action = action
        _selected = State(initialValue: Set(request.runs.filter(\.complete).map(\.id)))
    }

    private var listHeight: CGFloat {
        let rows = request.runs.reduce(0) { $0 + ($1.complete ? 66 : 86) }
        return CGFloat(min(310, max(112, rows + request.issues.count * 31)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Import Pico Card").font(.title2.weight(.semibold))
                Text("Copy verified recordings into this Project. The card stays untouched.")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(request.runs) { run in
                        Toggle(isOn: Binding(get: { selected.contains(run.id) }, set: {
                            if $0 { selected.insert(run.id) } else { selected.remove(run.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(run.url.lastPathComponent).font(.headline)
                                Text("\(run.complete ? "Complete" : "Interrupted") · \(Double(run.saved) / 100_000, format: .number.precision(.fractionLength(2))) s saved")
                                Text("\(run.missing.formatted()) known missing · \(run.low.formatted()) low rails · \(run.high.formatted()) high rails · \(run.errors.formatted()) ADC errors")
                                    .foregroundStyle(.secondary)
                                if let issue = run.issue { Text(issue).foregroundStyle(.secondary) }
                            }
                        }.toggleStyle(.checkbox)
                    }
                    ForEach(Array(request.issues.enumerated()), id: \.offset) { _, issue in
                        Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: listHeight)
            Divider()
            Picker("Input during recording", selection: $wiring) {
                ForEach(PicoCardImport.Wiring.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if selected.count == 1 {
                Toggle("Add approximate start time", isOn: $addDate)
                if addDate { DatePicker("Approximate start", selection: $date) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import \(selected.count) \(selected.count == 1 ? "Run" : "Runs")") {
                    action(request.runs.filter { selected.contains($0.id) }, wiring, selected.count == 1 && addDate ? date : nil)
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(selected.isEmpty)
            }
        }.padding(22).frame(width: 555)
    }
}
