import SwiftUI

/// Compares saved capture summaries; it does not infer source significance or rates.
struct RecordComparisonView: View {
    let record: CaptureRecord
    let records: [CaptureRecord]
    @State private var selection = -1

    private var alternatives: [Int] {
        records.indices.filter { records[$0].id != record.id || records[$0].capturedAt != record.capturedAt || records[$0].complete != record.complete }
    }
    private func summary(_ capture: CaptureRecord) -> SampleStatistics {
        SampleStatistics.calculate(capture.samples, from: 0, to: min(2048, capture.samples.count) - 1)
    }
    private func title(_ capture: CaptureRecord) -> String {
        let label = capture.metadata["tag"]?.capitalized ?? "Record"
        return "\(label) · \(capture.capturedAt.formatted(date: .abbreviated, time: .standard)) · \(capture.id.prefix(6))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Compare records").font(.headline)
            if alternatives.isEmpty {
                Text("Save another record in this session to compare summaries.").font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Compare with", selection: $selection) {
                    Text("Choose a record").tag(-1)
                    ForEach(alternatives, id: \.self) { index in Text(title(records[index])).tag(index) }
                }
                if alternatives.contains(selection) {
                    let other = records[selection]
                    let first = summary(record), second = summary(other)
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                        GridRow { Text(""); Text("Selected").fontWeight(.semibold); Text("Comparison").fontWeight(.semibold) }
                        GridRow { Text("Tag"); Text(record.metadata["tag"] ?? "Unknown"); Text(other.metadata["tag"] ?? "Unknown") }
                        GridRow { Text("Gain"); Text(record.metadata["gain"] ?? "Unknown"); Text(other.metadata["gain"] ?? "Unknown") }
                        GridRow { Text("Transfer"); Text(record.complete ? "Complete" : "Incomplete"); Text(other.complete ? "Complete" : "Incomplete") }
                        GridRow { Text("Quality flags"); Text(record.metadata["quality_flags"] ?? "Unknown"); Text(other.metadata["quality_flags"] ?? "Unknown") }
                        GridRow { Text("First samples used"); Text("\(first.count)"); Text("\(second.count)") }
                        GridRow { Text("Mean, codes"); Text(number(first.mean)); Text(number(second.mean)) }
                        GridRow { Text("Deviation, codes"); Text(number(first.deviation)); Text(number(second.deviation)) }
                        GridRow { Text("ADC errors excluded"); Text("\(first.errorCount)"); Text("\(second.errorCount)") }
                    }.font(.callout.monospacedDigit()).textSelection(.enabled)
                    Text("Mean and standard deviation use up to the first 2,048 retained samples, excluding ADC errors. They describe these records, not a calibrated noise floor or radiation rate. Different gain, settings, or incomplete records limit comparison.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: record.id) { _, _ in selection = -1 }
        .onChange(of: record.capturedAt) { _, _ in selection = -1 }
        .onChange(of: records.count) { _, _ in selection = -1 }
    }

    private func number(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "Unavailable" }
}
