import SwiftUI

struct RunComparisonPane: View {
    @ObservedObject var bench: StreamingBench
    let reader: StreamRangeReader
    let showMinute: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var first: UUID?
    @State private var second: UUID?
    @State private var data: [Comparison] = []

    private struct Comparison: Identifiable, Sendable {
        let id: UUID
        let name: String
        let kind: String
        let quality: StudioRangeQuality
        let spectra: [PostRunAnalysis.Spectrum]
    }

    private var compatible: [StreamRun] {
        guard let setup = Self.setup(reader.run), reader.run.settings.gain != "Unconfirmed" else { return [] }
        return bench.runs.compactMap(\.run).filter { run in
            guard run.id != reader.run.id, !run.isManualDraft, run.status != .recording,
                  run.settings.gain == reader.run.settings.gain, run.settings.channel == reader.run.settings.channel,
                  run.settings.nominalRate == reader.run.settings.nominalRate, let other = Self.setup(run) else { return false }
            return setup.board == other.board && setup.cable == other.cable && setup.standardWiring == other.standardWiring
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Compare Runs").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(bench.busy)
            }
            Text("\(reader.run.name) · \(Self.kind(reader.run))").font(.headline)
            if compatible.isEmpty {
                Text("A comparison requires a saved board and harness, matching gain, channel and sample rate.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                HStack {
                    picker("Compare with", selection: $first, excluding: second)
                    picker("And", selection: $second, excluding: first)
                }
            }
            Button("Review Full Runs", action: load).buttonStyle(.borderedProminent).disabled(bench.busy)
            if !data.isEmpty {
                ScrollView {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(data) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.name).font(.headline)
                                Text(item.kind).font(.caption).foregroundStyle(.secondary)
                                if item.quality.gaps.contains(where: { $0.end == nil }) {
                                    Label("Unknown missing time", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                                }
                                ForEach(item.quality.minutes) { row in metric(row, primary: item.id == reader.run.id) }
                                if !item.spectra.isEmpty {
                                    DisclosureGroup("Raw Spectra") {
                                        ForEach(item.spectra, id: \.sampleRate) { NoiseSpectrumView(spectrum: $0) }
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }.padding(.bottom, 4)
                }.frame(minHeight: 230, maxHeight: 440)
            }
            if let message = bench.notice { Text(message).font(.caption).textSelection(.enabled) }
            if bench.busy {
                HStack { ProgressView().controlSize(.small); Button("Cancel Work") { bench.cancelWork() } }
            }
        }.padding(22).frame(minWidth: 550, idealWidth: 700)
            .onChange(of: first) { _, _ in data = [] }
            .onChange(of: second) { _, _ in data = [] }
    }

    private func picker(_ label: String, selection: Binding<UUID?>, excluding: UUID?) -> some View {
        Picker(label, selection: selection) {
            Text("None").tag(UUID?.none)
            ForEach(compatible.filter { $0.id != excluding }) {
                Text("\(Self.kind($0)) · \($0.name)").tag(Optional($0.id))
            }
        }.disabled(bench.busy)
    }

    private func metric(_ row: StudioRangeQuality.Minute, primary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if primary {
                Button("Minute \(row.id + 1)") { showMinute(row.id + 1); dismiss() }.buttonStyle(.link)
            } else {
                Text("Minute \(row.id + 1)").fontWeight(.semibold)
            }
            Text("\(fmt(row.sampledSeconds)) s sampled · \(fmt(row.usableSeconds)) s usable")
            Text("\(fmt(row.knownMissingSeconds)) s known missing")
            Text("Baseline \(fmt(row.baseline)) · noise \(fmt(row.noise)) · drift \(fmt(row.drift)) codes")
            Text("\(row.clips.formatted()) clipped · \(row.errors.formatted()) errors")
            Divider()
        }.font(.caption).frame(minHeight: 92, alignment: .topLeading)
    }

    private func fmt(_ value: Double?) -> String {
        value?.formatted(.number.precision(.fractionLength(0...3))) ?? "—"
    }

    private nonisolated static func setup(_ run: StreamRun) -> CalibrationSetup? {
        run.settings.bench?.setup ?? run.settings.calibrationSetup ?? run.settings.profile?.setup
    }

    private nonisolated static func kind(_ run: StreamRun) -> String {
        if let step = run.settings.bench?.step { return step.rawValue }
        if let phase = run.settings.calibrationPhase { return phase.rawValue }
        return run.settings.mode == .calibrated ? "Measurement" : run.settings.mode.rawValue
    }

    private func load() {
        let reader = reader
        let runs = [reader.run] + [first, second].compactMap { id in compatible.first { $0.id == id } }
        let settings = ReviewSettings(sampleRate: reader.run.settings.nominalRate)
        bench.notice = nil
        bench.perform("Comparing saved runs") {
            try runs.map { run in
                let input = try StreamRangeReader(store: reader.store, run: run).prepared()
                let range = StreamSelection(lower: 0, upper: try input.duration())
                let config = try StudioRangeReview.config(input, selection: range, settings: settings)
                let result = try StudioRangeReview.analyze(input, config: config, includePulses: false)
                return Comparison(id: run.id, name: run.name, kind: Self.kind(run), quality: result.quality, spectra: result.spectra)
            }
        } completion: { data = $0 }
    }
}
