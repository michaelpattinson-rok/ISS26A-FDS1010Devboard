import SwiftUI

struct SavedAnalysesView: View {
    let analyses: [SignalAnalysisResult]
    var body: some View {
        if !analyses.isEmpty {
            DisclosureGroup("Saved analyses (\(analyses.count))") {
                ForEach(analyses) { value in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(value.createdAt.formatted()).font(.subheadline.weight(.medium))
                        Text("Algorithm \(value.algorithmVersion) · \(value.polarity.capitalized) · \(value.qualifiedPulses) qualified pulses")
                        Text("Baseline \(value.baselineCodes.formatted(.number.precision(.fractionLength(2)))) codes · noise \(value.robustNoiseCodes.formatted(.number.precision(.fractionLength(2)))) codes · threshold \(value.thresholdCodes.formatted(.number.precision(.fractionLength(2)))) codes")
                        Text("Raw sample SHA256 \(value.inputSHA256)").font(.caption.monospaced()).textSelection(.enabled)
                    }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                }
            }
        }
    }
}
