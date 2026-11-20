import SwiftUI

struct DiagnosisHealthView: View {
    let data: LiveStreamPreview
    let stopping: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Signal Health") {
                VStack(alignment: .leading, spacing: 8) {
                    if data.healthEnabled {
                        if let health = data.health {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                let age = data.healthReceipt.map {
                                    let elapsed = $0.duration(to: .now).components
                                    return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                                } ?? 0
                                LabeledContent("Latest Uno snapshot", value: stopping || age > 2.5 ? "Stale" : "\(age.formatted(.number.precision(.fractionLength(1)))) s old")
                            }
                            Text("Conversions \(health.firstConversion.formatted()) to \((health.firstConversion + UnoSignalHealth.block - 1).formatted())")
                                .font(.caption).foregroundStyle(.secondary)
                            LabeledContent("Mean baseline", value: codes(health.baseline))
                            LabeledContent("RMS noise", value: codes(health.noise))
                            LabeledContent("Valid minimum and maximum", value: extrema(health))
                            LabeledContent("Low rail", value: health.low.formatted())
                            LabeledContent("High rail", value: health.high.formatted())
                            LabeledContent("ADC errors", value: health.errors.formatted())
                        } else {
                            Text("Waiting for a device snapshot.").foregroundStyle(.secondary)
                        }
                        LabeledContent("Snapshot coverage", value: "\(data.healthReports.formatted()) of \(data.healthOpportunities.formatted()) scheduled")
                        if data.rejectedHealthReports > 0 {
                            LabeledContent("Rejected reports", value: data.rejectedHealthReports.formatted())
                        }
                    } else {
                        Text("Latest sample block, estimated on the Mac").font(.caption).foregroundStyle(.secondary)
                        LabeledContent("Median baseline", value: codes(data.baseline))
                        LabeledContent("Robust noise", value: codes(data.noise))
                    }
                    Text("Floating inputs can pick up repeating signals. A 60 Hz peak can have several coupling paths. Clipped readings lose peak amplitude.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            GroupBox("Recording Health") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current segment").font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Readings saved", value: data.saved.formatted())
                    LabeledContent("Known missing readings", value: data.loss.formatted())
                    LabeledContent("Peak Mac writer queue", value: data.hostQueuePeak.formatted())
                    LabeledContent("Longest observed writer call", value: data.maximumWriterUS == 0 ? "Waiting" : "\(data.maximumWriterUS.formatted()) µs")
                    Text("Device queue and USB backpressure totals are reported at Stop when supported.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
        }
    }

    private func codes(_ value: Double?) -> String {
        value.map { "\($0.formatted(.number.precision(.fractionLength(1)))) codes" } ?? "Unavailable"
    }

    private func extrema(_ value: UnoSignalHealth) -> String {
        guard let low = value.minimum, let high = value.maximum else { return "Unavailable" }
        return "\(low.formatted()) to \(high.formatted()) codes"
    }
}
