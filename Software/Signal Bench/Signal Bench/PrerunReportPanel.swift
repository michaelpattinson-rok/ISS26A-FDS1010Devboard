import SwiftUI

struct PrerunReportPanel: View {
    let report: CalibratedPrerun.Report
    let approved: Bool
    var historical = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(report.passed ? (approved || historical ? "Dark prerun passed" : "Previous prerun passed") : "Dark prerun did not pass",
                  systemImage: report.passed ? (approved ? "checkmark.circle" : "clock") : "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(report.passed ? (approved ? Color.green : .secondary) : .orange)
            if report.passed && !approved && !historical {
                Text("Record a fresh prerun for the current connection and setup.").foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 6) {
                metric("Sampled", seconds(report.coverage.sampled))
                metric("Usable", seconds(report.coverage.usable))
                metric("Missing in checked range", seconds(report.coverage.unknown))
                metric("Baseline", codes(report.baseline))
                metric("Noise", codes(report.noise))
                metric("Largest drift", codes(report.drift))
                metric("Clipped readings", report.quality.railSamples.formatted())
                metric("ADC error readings", report.quality.adcErrors.formatted())
            }
            if report.coverage.uncertainInterruption {
                Text("Coverage after the last saved reading is unconfirmed.").foregroundStyle(.secondary)
            }
            if !report.issues.isEmpty {
                DisclosureGroup("Why the check failed") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(report.issues.enumerated()), id: \.offset) { _, issue in Text(issue) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }
                Text("Check the dark cover, the ADC connection and its ground. If the spectrum shows 60 Hz, preview the notch in Studio.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: 620, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }.accessibilityElement(children: .combine)
    }

    private func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2))) + " s"
    }

    private func codes(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(0...2))) + " codes" } ?? "Unavailable"
    }
}

struct PrerunSpaceEstimate: View {
    let rate: Int
    let averaging: ADCAveraging?
    let board: AcquisitionBoard
    let prerun: Double
    let measurement: Double
    let location: URL?
    let recorded: Bool

    var body: some View {
        if let check = estimate(prerun), let run = estimate(measurement) {
            let required = (recorded ? 0 : check.requiredBytes) + run.requiredBytes
            Grid(alignment: .leading, horizontalSpacing: 15, verticalSpacing: 4) {
                row("Prerun estimate", recorded ? "Already saved" : bytes(check.projectBytes))
                row("Measurement estimate", bytes(run.projectBytes))
                row("Free space required", bytes(required))
                row("Available on Project volume", (run.availableBytes ?? check.availableBytes).map(bytes) ?? "Unavailable")
            }.font(.caption).padding(10)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
        }
    }

    private func estimate(_ seconds: Double) -> RecordingEstimate? {
        .init(rate: rate, averaging: averaging, seconds: seconds, gpio: false, location: location, board: board)
    }

    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().gridColumnAlignment(.trailing)
        }
    }
}
