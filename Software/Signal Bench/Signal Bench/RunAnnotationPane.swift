import SwiftUI

struct RunAnnotationPane: View {
    @ObservedObject var bench: StreamingBench
    let reader: StreamRangeReader
    let initial: StreamSelection
    let revision: RunAnnotationRevision?
    let didSave: (RunAnnotationRevision?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var segmentID: UUID?
    @State private var lower = 0.0
    @State private var upper = 1.0
    @State private var note = ""
    @State private var policy = NoisePolicy.review
    @State private var settings = ReviewSettings()
    @State private var proposal: [ReviewInterval]?
    @State private var autoRange: StreamSelection?
    @State private var controlID: UUID?
    private var controlProfile: CalibrationProfile? {
        reader.run.settings.profile ?? bench.profiles.first { $0.id == controlID && $0.ready }
    }

    private var segment: StreamRunSegment? { reader.run.segments.first { $0.id == segmentID } }
    private var range: StreamSelection { .init(lower: lower, upper: upper) }
    private var proposals: [ReviewInterval]? { autoRange == range ? proposal : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Annotate Waveform").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if reader.run.segments.count > 1 {
                Picker("Timing segment", selection: $segmentID) {
                    Text("Choose a segment").tag(UUID?.none)
                    ForEach(Array(reader.run.segments.enumerated()), id: \.element.id) { i, value in
                        Text("Segment \(i + 1)").tag(Optional(value.id))
                    }
                }
                Text("Times on either side of an unknown gap belong to separate segments.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                timeField("Start time (s)", value: $lower)
                timeField("End time (s)", value: $upper)
            }.textFieldStyle(.roundedBorder)
            TextField("Description", text: $note).textFieldStyle(.roundedBorder)
            HStack {
                Button("Flag at Start", systemImage: "flag") { manual(flag: true) }
                Button("Exclude Range", systemImage: "rectangle.slash") { manual(flag: false) }
                Spacer()
                Button("Undo Last Change") { undo() }.disabled(revision == nil)
            }.disabled(bench.busy)
            Divider()
            Picker("Automatic exclusions", selection: $policy) {
                ForEach(NoisePolicy.allCases) { Text($0.rawValue).tag($0) }
            }
            if policy == .standard && reader.run.settings.profile == nil {
                Picker("Matching control profile", selection: $controlID) {
                    Text("Choose a profile").tag(UUID?.none)
                    ForEach(bench.profiles.filter(\.ready), id: \.id) { value in Text(value.name).tag(Optional(value.id)) }
                }
                Text("Choose controls recorded with this setup.").font(.caption).foregroundStyle(.secondary)
            }
            if policy == .custom {
                VStack(alignment: .leading, spacing: 7) {
                    Stepper("Glitch width  \(settings.spikeWidth) samples", value: $settings.spikeWidth, in: 1...32)
                    slider("Glitch slope", value: $settings.spikeSlope, range: 1...4095)
                    slider("Noise limit", value: $settings.noiseLimit, range: 0.1...4095)
                    Stepper("Recovery padding  \(settings.padAfter) samples", value: $settings.padAfter, in: 0...10_000, step: 10)
                }
            }
            HStack {
                Button("Preview Exclusions") { preview() }.disabled(bench.busy || !range.valid || (policy == .standard && controlProfile == nil))
                if let proposals {
                    Button("Auto Apply") { apply(proposals) }.disabled(proposals.isEmpty || bench.busy)
                    Text("\(proposals.count.formatted()) proposed").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let proposals, !proposals.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(proposals.prefix(40).enumerated()), id: \.offset) { _, item in
                            if let segment = reader.run.segments.first(where: { $0.id == item.range.segment }) {
                                let rate = segment.configuredRate(reader.run.settings.nominalRate)
                                let start = segment.timelineStart + Double(item.range.first) / rate
                                let end = segment.timelineStart + Double(item.range.end) / rate
                                Text("\(item.reason.rawValue) · \(start.formatted(.number.precision(.fractionLength(3)))) to \(end.formatted(.number.precision(.fractionLength(3)))) s")
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.font(.caption).frame(maxHeight: 105)
            }
            if let message = bench.notice { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            if bench.busy {
                HStack { ProgressView().controlSize(.small); Button("Cancel Work") { bench.cancelWork() } }
            }
        }.padding(22).frame(width: 480)
            .onAppear {
                lower = initial.lower
                upper = initial.upper
                if reader.run.segments.count == 1 { segmentID = reader.run.segments.first?.id }
                policy = revision?.policy ?? reader.run.settings.noisePolicy ?? bench.defaults.noise
                settings = revision?.autoSettings ?? .init(profile: reader.run.settings.profile, sampleRate: reader.run.settings.nominalRate)
                controlID = revision?.noiseProfile
                bench.notice = nil
            }
            .onChange(of: policy) { _, _ in proposal = nil }
            .onChange(of: settings) { _, _ in proposal = nil }
            .onChange(of: controlID) { _, _ in proposal = nil }
    }

    private func timeField(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, value: value, format: .number.precision(.fractionLength(0...6)))
                .accessibilityLabel(title)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range).accessibilityLabel(title)
            Text(value.wrappedValue.formatted(.number.precision(.fractionLength(1))))
                .font(.caption.monospacedDigit()).frame(width: 55)
        }
    }

    private func manual(flag: Bool) {
        guard let segment else { bench.notice = "Choose a timing segment."; return }
        var next = revision ?? .init()
        do {
            if flag {
                next.flags.append(try RunAnnotations.flag(lower, segment: segment, note: note, reader: reader))
            } else {
                let description = note.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !description.isEmpty else { bench.notice = "Describe why this interval should be excluded."; return }
                let bounds = try RunAnnotations.range(range, segment: segment, reader: reader)
                next.masks.append(.init(range: bounds, reason: .manual, action: .excluded, note: description))
            }
            commit(next)
        } catch { bench.notice = error.localizedDescription }
    }

    private func preview() {
        let reader = reader, policy = policy, settings = settings, range = range, control = controlProfile
        bench.notice = nil
        bench.perform("Finding noisy intervals") {
            try RunAnnotations.preview(reader, selection: range, policy: policy, settings: settings, noiseProfile: control)
        } completion: { values in proposal = values; autoRange = range }
    }

    private func apply(_ values: [ReviewInterval]) {
        var next = revision ?? .init()
        next.policy = policy
        next.autoSettings = settings
        next.noiseProfile = controlProfile?.id
        let existing = Set(next.masks.map(\.id))
        next.masks.append(contentsOf: values.filter { !existing.contains($0.id) })
        commit(next)
    }

    private func commit(_ next: RunAnnotationRevision) {
        let reader = reader, id = revision?.id
        bench.perform("Saving annotations") {
            try RunAnnotations.save(next, reader: reader, replacing: id)
        } completion: { value in didSave(value); dismiss() }
    }

    private func undo() {
        guard let id = revision?.id else { return }
        let reader = reader
        bench.perform("Restoring previous annotations") {
            try RunAnnotations.undo(reader, revision: id)
        } completion: { value in didSave(value); dismiss() }
    }
}
