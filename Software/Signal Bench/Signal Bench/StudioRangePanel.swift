import AppKit
import SwiftUI

struct StudioRangePanel: View {
    @ObservedObject var bench: StreamingBench
    let reader: StreamRangeReader
    let selection: StreamSelection
    let saved: StudioRangeConfig?
    let openSample: (StreamMatchLocation) -> Void
    let openTime: (Double) -> Void
    let didSave: (StreamAnalysisManifest) -> Void
    var initialPreview: StudioRangeResult? = nil
    var proposal: ReviewProposal? = nil
    var initialReference: StudioRangeResult? = nil
    var decisionChanges: [ReviewDecisionChange] = []
    var decisionChangeCount = 0
    var duration = 0.0
    var moveRange: ((Double) -> Void)? = nil
    @State private var reviewingProposal = false
    @State private var settings = ReviewSettings()
    @State private var preview: StudioRangeResult?
    @State private var reference: StudioRangeResult?
    @State private var timeline: [RunTimelineEntry] = []
    @State private var initialized = false
    @State private var spectrum = 0
    @State private var selectedProposals = Set<String>()
    @State private var undoRevision: UUID?
    @State private var showExport = false
    @State private var format = StreamExporter.Format.zip
    @State private var exportName = ""
    @State private var includeAnalyses = true

    private var current: StudioRangeResult? {
        guard preview?.config.selection == selection, preview?.config.settings == settings else { return nil }
        return preview
    }
    private var comparable: StudioRangeResult? { reference?.config.selection == selection ? reference : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let result = preview {
                if current == nil {
                    Text("Showing \(number(result.config.selection.lower)) to \(number(result.config.selection.upper)) s. \(bench.busy ? "Updating preview…" : "Select Preview Range to apply changes.")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                trace(result, title: comparable == nil ? "Waveform" : "Current preview")
                positionControl
                coverageSummary(result.quality)
            } else {
                Text(bench.busy ? "Preparing waveform…" : "Preview the selected range to see its waveform and coverage.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                positionControl
            }
            ViewThatFits(in: .horizontal) {
                HStack { previewActions; Spacer(minLength: 8); saveActions }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 7) {
                    HStack { previewActions }
                    HStack { saveActions }
                }
            }.font(.callout)
            DisclosureGroup("Processing Settings") {
                VStack(alignment: .leading, spacing: 9) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { filterToggles }.fixedSize()
                        VStack(alignment: .leading, spacing: 6) { filterToggles }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { maskToggles }.fixedSize()
                        VStack(alignment: .leading, spacing: 6) { maskToggles }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { provenance }.fixedSize()
                        VStack(alignment: .leading, spacing: 3) { provenance }
                    }.font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
            }.font(.callout)
            WaveformDisplayControls(style: $bench.waveformStyle, scale: $bench.waveformScale)
            if bench.waveformStyle == .points {
                DotDensityControl(percent: $bench.dotDensity)
                Text("Averaged dots · One mean per displayed bin").font(.caption).foregroundStyle(.secondary)
            }
            if let result = current {
                if let comparable {
                    DisclosureGroup("Comparison Preview") {
                        trace(comparable, title: "Reference waveform")
                        coverageSummary(comparable.quality)
                    }
                }
                if reviewingProposal { proposedFindings(result) }
                quality(result.quality)
                spectra(result.spectra)
                reviewItems(result)
            }
            flags
        }.sheet(isPresented: $showExport) {
            exportSheet
        }.task {
            guard !initialized else { return }
            initialized = true
            preview = initialPreview
            reviewingProposal = proposal != nil
            reference = initialReference
            settings = initialPreview?.config.settings ?? saved?.settings ?? .init(profile: reader.run.settings.profile, sampleRate: Int(reader.run.settings.recordedRate.rounded()))
            let input = reader
            let worker = Task.detached(priority: .utility) { try RunTimeline.entries(input, finished: true, resolving: false) }
            do {
                timeline = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            }
            catch { if !Task.isCancelled { bench.notice = error.localizedDescription } }
        }
    }

    @ViewBuilder private var positionControl: some View {
        if let moveRange {
            WaveformPositionControl(bounds: .init(lower: 0, upper: duration), selection: selection, change: moveRange)
        }
    }

    @ViewBuilder private var previewActions: some View {
        Button("Preview Range", action: refresh).buttonStyle(.borderedProminent)
            .disabled(bench.busy || !selection.valid)
        if reference == nil {
            Button("Keep for Comparison") { reference = current }.disabled(bench.busy || current == nil)
        } else {
            Button("Clear Comparison") { reference = nil }.disabled(bench.busy)
        }
    }

    @ViewBuilder private var saveActions: some View {
        Button("Export…") { exportName = reader.run.name; showExport = true }
            .disabled(bench.busy || !selection.valid)
        Button("Save Revision", action: save)
            .disabled(bench.busy || (current?.quality.samples ?? 0) == 0)
    }

    private func proposedFindings(_ result: StudioRangeResult) -> some View {
        GroupBox("Proposed Review") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Review the affected samples before saving or applying exclusions.")
                if decisionChangeCount > 0 {
                    DisclosureGroup("\(decisionChangeCount.formatted()) changed pulse decisions") {
                        ForEach(decisionChanges) { change in
                            Button {
                                openSample(change.location)
                            } label: {
                                Text("Sample \(change.location.sample.formatted()) · \(change.before?.decision ?? "No decision") to \(change.after?.decision ?? "no decision")")
                            }.buttonStyle(.link)
                        }
                        if decisionChangeCount > decisionChanges.count {
                            Text("Showing the first \(decisionChanges.count) changes. The worker can return more.")
                        }
                    }
                }
                if !result.pairedSpectra.isEmpty {
                    DisclosureGroup("Matched Spectrum Windows") {
                        ForEach(result.pairedSpectra, id: \.sampleRate) { spectrum in
                            if spectrum.windows > 0 {
                                Text("\(spectrum.windows) windows · \(number(spectrum.analyzedSeconds)) s at \(spectrum.sampleRate.formatted()) samples/s")
                                Text("60 Hz band power · raw \(number(spectrum.bandPower(spectrum.raw, around: 60))) · processed \(number(spectrum.bandPower(spectrum.processed, around: 60))) ADC codes²")
                            } else {
                                Text("No complete spectrum windows are shared at \(spectrum.sampleRate.formatted()) samples/s.")
                            }
                        }
                    }
                }
            }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var provenance: some View {
        if let profile = reader.run.settings.profile {
            Text("Calibration \(profile.name) · \(profile.id.uuidString.prefix(8))")
        } else {
            Text("No saved calibration")
        }
        if let revision = preview?.config.annotationRevision ?? saved?.annotationRevision {
            Text("Exclusions revision \(revision.uuidString.prefix(8))")
        } else if preview != nil {
            Text("No approved exclusions")
        }
    }

    @ViewBuilder private var filterToggles: some View {
        Toggle("Remove baseline drift", isOn: $settings.drift)
        Toggle("60 Hz notch", isOn: $settings.notch60)
        Toggle("120 Hz notch", isOn: $settings.notch120)
    }

    @ViewBuilder private var maskToggles: some View {
        Toggle("Exclude short glitches", isOn: $settings.maskGlitches)
        Toggle("Exclude noisy blocks", isOn: $settings.maskNoise)
    }

    private func trace(_ result: StudioRangeResult, title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ReviewTrace(result: result.trace, fps: bench.reviewFPS, style: bench.waveformStyle, density: bench.dotDensity, scale: bench.waveformScale)
            HStack(spacing: 14) {
                Label("Raw", systemImage: "line.diagonal").foregroundStyle(.secondary)
                Label("Processed", systemImage: "line.diagonal").foregroundStyle(.blue)
                Label("Excluded", systemImage: "rectangle.fill").foregroundStyle(.orange)
                Spacer()
                Text("ADC codes")
            }.font(.caption)
            if comparable != nil {
                Text(result.config.settings.filterSummary).font(.caption).foregroundStyle(.secondary)
            }
            if result.quality.minutes.contains(where: { $0.usableSeconds > 0 }) {
                Text("\(result.quality.rawMatches.formatted()) raw · \(result.quality.processedMatches.formatted()) processed Pulse Matches")
                    .font(.callout.monospacedDigit())
            } else {
                Text("\(result.quality.rawMatches.formatted()) raw Pulse Matches · No eligible processed samples")
                    .font(.callout.monospacedDigit())
            }
        }
    }

    private func coverageSummary(_ quality: StudioRangeQuality) -> some View {
        let sampled = quality.minutes.reduce(0) { $0 + $1.sampledSeconds }
        let usable = quality.minutes.reduce(0) { $0 + $1.usableSeconds }
        let missing = quality.minutes.reduce(0) { $0 + $1.knownMissingSeconds }
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(number(sampled)) s sampled · \(number(usable)) s usable after processing · \(number(missing)) s known missing")
                .monospacedDigit()
            if quality.gaps.contains(where: { $0.end == nil }) {
                Label("Some missing time could not be measured.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
        }.font(.caption)
    }

    private func quality(_ quality: StudioRangeQuality) -> some View {
        DisclosureGroup("Quality and Coverage") {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(quality.excluded.formatted()) excluded samples · \(quality.settling.formatted()) in filter settling")
                Divider()
                ForEach(quality.minutes) { row in
                    let start = max(selection.lower, Double(row.id) * 60)
                    VStack(alignment: .leading, spacing: 3) {
                        Button("Minute \(row.id + 1) · \(number(start)) s") { openTime(start) }.buttonStyle(.link)
                        Text("Baseline \(number(row.baseline)) · robust noise \(number(row.noise)) · drift \(number(row.drift)) ADC codes")
                        Text("\(row.clips.formatted()) clipped · \(row.errors.formatted()) ADC errors · \(number(row.knownMissingSeconds)) s known missing")
                    }
                }
                if !quality.gaps.isEmpty {
                    Divider()
                    ForEach(Array(quality.gaps.prefix(100).enumerated()), id: \.offset) { _, gap in
                        let label = gap.end.map { "Gap from \(number(gap.start)) to \(number($0)) s" }
                            ?? "Unknown time at \(number(gap.start)) s"
                        if let location = gap.location {
                            Button(label) { openSample(location) }.buttonStyle(.link)
                        } else {
                            Button(label) { openTime(gap.start) }.buttonStyle(.link)
                        }
                    }
                    if quality.gaps.count > 100 { Text("Showing the first 100 gaps. Save a revision for the full list.") }
                }
            }.font(.caption).padding(.top, 6)
        }
    }

    private func spectra(_ values: [PostRunAnalysis.Spectrum]) -> some View {
        DisclosureGroup("Raw Spectrum") {
            if values.indices.contains(spectrum) {
                if values.count > 1 {
                    Picker("Sample rate", selection: $spectrum) {
                        ForEach(values.indices, id: \.self) { i in
                            Text("\(number(values[i].sampleRate)) samples/s").tag(i)
                        }
                    }
                }
                NoiseSpectrumView(spectrum: values[spectrum]).padding(.top, 6)
            } else {
                Text("No complete spectrum windows in this range.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func reviewItems(_ result: StudioRangeResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup("Quality Issues and Exclusions") {
                if result.intervals.isEmpty { Text("No quality issues in this range.").font(.caption) }
                ForEach(Array(result.intervals.prefix(60).enumerated()), id: \.offset) { _, interval in
                    let location = StreamMatchLocation(segment: interval.range.segment, sample: interval.evidenceIndex ?? interval.range.first)
                    let approved = result.config.exclusions.contains { mask in
                        mask.reason == interval.reason && mask.range.segment == interval.range.segment
                        && mask.range.first <= interval.range.first && interval.range.end <= mask.range.end
                    }
                    HStack {
                        if saved == nil, interval.action == .excluded, !approved {
                            Toggle("Select exclusion at sample \(location.sample)", isOn: Binding(
                                get: { selectedProposals.contains(interval.id) },
                                set: { if $0 { selectedProposals.insert(interval.id) } else { selectedProposals.remove(interval.id) } }
                            )).labelsHidden().disabled(bench.busy)
                        }
                        Button("\(interval.reason.rawValue) · \(interval.action == .review ? "Review" : approved ? "Approved exclusion" : "Excluded in preview") · sample \(location.sample.formatted())") {
                            openSample(location)
                        }.buttonStyle(.link)
                    }.font(.caption)
                }
                if result.intervals.count > 60 { Text("Save a revision for all intervals.").font(.caption) }
                if saved == nil {
                    HStack {
                        Button("Apply Selected Exclusions") { apply(result) }
                            .disabled(bench.busy || selectedProposals.isEmpty)
                        if let undoRevision {
                            Button("Undo Last Apply") { undo(undoRevision) }.disabled(bench.busy)
                        }
                    }
                }
            }
            DisclosureGroup("Pulse Matches and Decisions") {
                if result.decisions.isEmpty { Text("No pulse decisions in this range.").font(.caption) }
                ForEach(result.decisions.prefix(60)) { item in
                    let location = StreamMatchLocation(segment: item.pulse.range.segment, sample: item.pulse.peakIndex)
                    Button {
                        openSample(location)
                    } label: {
                        Text("\(item.trace.capitalized) · \(item.pulse.decision.capitalized) · \(number(item.pulse.height)) codes · \(number(item.widthUS)) µs · sample \(location.sample.formatted())")
                    }.buttonStyle(.link).font(.caption)
                }
                if result.quality.decisionCount > 60 { Text("Save a revision for all decisions.").font(.caption) }
            }
        }
    }

    private var flags: some View {
        let placed = timeline.filter { item in
            guard item.state == .placed, let position = item.position, let time = RunTimeline.time(of: position, in: reader.run) else { return false }
            return selection.lower <= time && time < selection.upper
        }
        return DisclosureGroup("Flags in Range (\(placed.count))") {
            if placed.isEmpty { Text("No placed flags in this range.").font(.caption).foregroundStyle(.secondary) }
            ForEach(placed) { entry in
                if let position = entry.position {
                    Button("\(entry.label) · sample \(position.index.formatted())") {
                        openSample(.init(segment: position.segment, sample: position.index))
                    }.buttonStyle(.link).font(.callout)
                    if !entry.note.isEmpty { Text(entry.note).font(.caption).textSelection(.enabled) }
                }
            }
        }
    }

    private func number(_ value: Double?) -> String {
        value?.formatted(.number.precision(.fractionLength(0...3))) ?? "—"
    }

    private func refresh() {
        let reader = reader, selection = selection, settings = settings
        let saved = proposal == nil ? saved : nil
        bench.notice = nil
        bench.perform("Reviewing selected samples") {
            let config: StudioRangeConfig
            if let saved {
                config = .init(selection: selection, settings: settings, annotationRevision: saved.annotationRevision,
                               exclusions: saved.exclusions, profileRevision: saved.profileRevision, comparisonContext: saved.comparisonContext)
            } else {
                config = try StudioRangeReview.config(reader, selection: selection, settings: settings)
            }
            return try StudioRangeReview.analyze(reader, config: config)
        } completion: { result in
            preview = result
            if reviewingProposal { reference = nil }
            reviewingProposal = false
            selectedProposals = []
            spectrum = 0
        }
    }

    private func apply(_ result: StudioRangeResult) {
        let chosen = result.intervals.filter { $0.action == .excluded && selectedProposals.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let reader = reader, expected = result.config.annotationRevision, settings = result.config.settings
        let proposal = reviewingProposal ? proposal : nil
        bench.perform("Applying reviewed exclusions") {
            if let proposal {
                try proposal.checkCurrent(reader)
                _ = try StudioRangeReview.analyze(reader, config: result.config, includePulses: false,
                    expectedSourceHash: proposal.sourceHash, contextSettings: proposal.reference)
            }
            var revision = try RunAnnotations.read(reader) ?? .init()
            let existing = Set(revision.masks.map(\.id))
            revision.masks.append(contentsOf: chosen.filter { !existing.contains($0.id) })
            revision.autoSettings = settings
            return try RunAnnotations.save(revision, reader: reader, replacing: expected)
        } completion: { revision in
            undoRevision = revision.id
            refresh()
        }
    }

    private func undo(_ revision: UUID) {
        let reader = reader
        bench.perform("Undoing reviewed exclusions") {
            try RunAnnotations.undo(reader, revision: revision)
        } completion: { _ in
            undoRevision = nil
            refresh()
        }
    }

    private var exportSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Selected Range").font(.title2.weight(.semibold))
            TextField("Export name", text: $exportName).textFieldStyle(.roundedBorder)
            Picker("Format", selection: $format) {
                ForEach(StreamExporter.Format.allCases) { Text($0.rawValue).tag($0) }
            }
            if !format.includesRunInfo {
                Toggle("Include saved analyses", isOn: $includeAnalyses)
            }
            Text(format.detail).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showExport = false }.keyboardShortcut(.cancelAction)
                Button("Choose Location…", action: export).keyboardShortcut(.defaultAction)
                    .disabled((try? SessionStore.projectName(exportName)) == nil)
            }
        }.padding(22).frame(width: 410)
    }

    private func export() {
        let reader = reader, range = selection, name = exportName, format = format, analyses = includeAnalyses
        bench.queueExport(reader, name: name, selection: range, format: format, includeAnalyses: analyses) {
            showExport = false
        }
    }

    private func save() {
        guard let config = current?.config else { return }
        let reader = reader
        let proposal = reviewingProposal ? proposal : nil
        bench.perform("Saving review revision") {
            try StudioRangeReview.save(reader, config: config, proposal: proposal)
        } completion: { manifest in
            didSave(manifest)
            bench.notice = "Review revision saved."
        }
    }
}
