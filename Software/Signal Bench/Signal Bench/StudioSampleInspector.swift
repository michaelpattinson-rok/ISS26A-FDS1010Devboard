import SwiftUI

struct StudioSampleInspector: View {
    let reader: StreamRangeReader
    let location: StreamMatchLocation
    @Environment(\.dismiss) private var dismiss
    @State private var result: Inspection?
    @State private var failure: String?

    private struct Inspection: Sendable {
        let plot: StudioPlot
        let selection: StreamSelection
        let sample: WaveformSample
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sample \(location.sample.formatted())").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let result {
                Text("\(result.sample.time.formatted(.number.precision(.fractionLength(0...7)))) s · \(result.sample.readingLabel)")
                    .font(.callout.monospacedDigit())
                if result.sample.invalid { Label("ADC error", systemImage: "exclamationmark.circle") }
                else if result.sample.clipped { Label("Clipped sample", systemImage: "exclamationmark.circle") }
                StreamWaveform(columns: result.plot.columns, breaks: result.plot.breaks, selection: result.selection,
                               height: 210, xAxis: true, faults: result.plot.faults, rails: result.plot.rails,
                               gaps: result.plot.gaps, samples: result.plot.samples, style: .trace,
                               cursorTimes: [result.sample.time])
            } else if let failure {
                Label(failure, systemImage: "exclamationmark.circle")
            } else {
                ProgressView("Reading original samples…")
            }
        }
        .padding(16).frame(width: 480)
        .task {
            let input = reader, location = location
            let work = Task.detached(priority: .utility) {
                let input = try input.prepared()
                guard let coverage = input.index?.lazy.filter({ $0.segment == location.segment }).map(\.end).max(),
                      location.sample < coverage else {
                    throw ReviewWorkerError.invalid("This sample is outside the saved data.")
                }
                let selection = try ReviewWorker.selection(.init(segment: location.segment,
                    first: location.sample > 64 ? location.sample - 64 : 0, end: min(coverage, location.sample + 65)), reader: input)
                let plot = try StreamStudio.plot(input, selection: selection)
                guard let sample = plot.samples.first(where: { $0.segment == location.segment && $0.index == location.sample }) else {
                    throw ReviewWorkerError.invalid("This sample is outside the saved data.")
                }
                return Inspection(plot: plot, selection: selection, sample: sample)
            }
            do {
                let inspection = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                result = inspection
            } catch is CancellationError {
            } catch { failure = error.localizedDescription }
        }
    }
}
