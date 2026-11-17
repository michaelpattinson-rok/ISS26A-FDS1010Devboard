import SwiftUI

struct FixtureStudyPanel: View {
    @ObservedObject var bench: StreamingBench
    let reader: StreamRangeReader
    let selection: StreamSelection
    let baseline: ReviewSettings
    var saved: StreamAnalysisManifest?
    var openSample: (StreamMatchLocation) -> Void = { _ in }
    let didSave: (StreamAnalysisManifest) -> Void
    @State private var runs: [StreamRun] = []
    @State private var templates: [FixtureStudyTemplate] = []
    @State private var training = Set<UUID>()
    @State private var noiseID: UUID?
    @State private var validation = Set<UUID>()
    @State private var templateID: UUID?
    @State private var name = ""
    @State private var before = 64
    @State private var after = 128
    @State private var declaredRev = false
    @State private var weighted = false
    @State private var operatorConfirmed = false
    @State private var preview: FixtureFitPreview?
    @State private var previewKey: FitRequest?
    @State private var report: FixtureReplayReport?
    @State private var alternate: FixtureReplayReport?
    @State private var manifest: StreamAnalysisManifest?
    @State private var message: String?
    @State private var loaded = false

    private var template: FixtureStudyTemplate? { templates.first { $0.id == templateID } }
    private struct FitRequest: Equatable {
        var template: UUID?
        var weighted: Bool
        var operatorConfirmed: Bool
        var range: StreamSelection
    }
    private var key: FitRequest { .init(template: templateID, weighted: weighted, operatorConfirmed: operatorConfirmed, range: selection) }
    private var shown: FixtureFitPreview? { previewKey == key ? preview : nil }
    private var chosenTemplate: Binding<UUID?> {
        Binding(get: { templateID }, set: { templateID = $0; weighted = false; operatorConfirmed = false })
    }
    private var fixtureRuns: [StreamRun] { runs.filter { $0.status == .complete && $0.settings.bench?.step == .fixture } }
    private var noiseRuns: [StreamRun] { runs.filter { $0.status == .complete && [.empty, .repeatEmpty].contains($0.settings.bench?.step) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Fixture Pulse Matches").font(.headline)
                StudioHelp(title: "Pulse alignment", detail: "Build a shape from independently timed training pulses. Complete separate runs test it. The fitted marker follows the timing reference; the pulse peak can occur later.", assets: ["FitAlignment"], illustration: true)
            }
            Text("Review only. Fixture counting awaits Rev E.1 bench validation.")
                .font(.callout).foregroundStyle(.secondary)
            DisclosureGroup("Build a template revision") {
                buildControls.padding(.top, 8)
            }
            HStack {
                Picker("Template", selection: chosenTemplate) {
                    Text("Choose a template").tag(UUID?.none)
                    ForEach(templates) { Text($0.name + " · " + String($0.id.uuidString.prefix(6))).tag(Optional($0.id)) }
                }
            }
            if let template {
                DisclosureGroup("Template evidence") { templateEvidence(template).padding(.top, 6) }
                HStack {
                    Toggle("Use measured noise weighting", isOn: $weighted).disabled(template.ar == nil)
                    StudioHelp(title: "Noise weighting", detail: "An optional first order noise model is fitted to a separate Empty Board run. Compare a new replay with weighting off and on. Both fits remove baseline offset and slope.", assets: ["FitResidual"], illustration: true)
                }
                if !template.compatible(reader) && template.compatible(reader, operatorConfirmed: true) {
                    Toggle("This run used \(template.setup.board) at \(template.setup.gain.lowercased()) gain", isOn: $operatorConfirmed)
                        .help("Your setup confirmation will be saved with the fit. It does not qualify this run as fixture validation.")
                }
                HStack {
                    Button("Fit Selected Range", action: inspect).buttonStyle(.borderedProminent)
                        .disabled(bench.busy || !selection.valid || selection.upper - selection.lower > 3
                                  || !template.compatible(reader, operatorConfirmed: operatorConfirmed))
                    Button("Replay Complete Run", action: replay).disabled(bench.busy || !FixtureReplay.eligible(reader, template: template))
                    StudioHelp(title: "Held aside replay", detail: "Both detectors scan every saved sample before fixture event times are loaded. Training runs and noise fit runs cannot serve as validation. Invalid data, clipping and gaps remove shared coverage.", assets: ["FitReview"], illustration: true)
                }
                if !FixtureReplay.eligible(reader, template: template) {
                    Text("Complete run replay is available for a matching fixture or empty board recording reserved for validation or recorded after this template.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let shown {
                    FixtureFitPlot(preview: shown)
                    HStack {
                        Text("Score \(shown.fit.score.formatted(.number.precision(.fractionLength(4))))")
                        Text("Amplitude \(shown.fit.amplitude.formatted(.number.precision(.fractionLength(2)))) ADC codes")
                    }.font(.callout)
                    let alignment = Double(shown.fit.alignment) + shown.fit.fractionalOffset
                    if let kernel = try? template.kernel(weighted: weighted) {
                        Text("Template half height width \(Double(kernel.halfHeightWidth) * 1_000_000 / template.setup.recordedHz, format: .number.precision(.fractionLength(1))) µs").font(.caption)
                    }
                    Text("Alignment \(alignment.formatted(.number.precision(.fractionLength(0...3)))) · peak sample \(shown.fit.peakIndex.formatted()) · residual \(shown.fit.residual.formatted(.number.precision(.fractionLength(3)))) ADC codes RMS")
                        .font(.caption).textSelection(.enabled)
                    HStack {
                        Label(shown.reason ?? "Within the fitted shape limits", systemImage: shown.reason == nil ? "waveform.path" : "flag")
                        StudioHelp(title: "Fit residual and review", detail: "The residual is the original trace minus the fitted pulse and baseline line. A poor shape match stays available for review. Amplitude uses ADC codes and has no calibrated energy scale.", assets: ["FitResidual", "FitReview"], illustration: true)
                    }.font(.callout).foregroundStyle(shown.reason == nil ? Color.secondary : Color.orange)
                    Button("Save Waveform Fit", action: saveFit).disabled(bench.busy)
                }
            }
            if let report {
                Divider()
                Text("Complete run comparison").font(.headline)
                Text(report.template.name + " · " + String(report.template.id.uuidString.prefix(6)))
                    .font(.callout).foregroundStyle(.secondary)
                Text("\((report.sampledSeconds ?? Double(report.sampled) / report.template.setup.recordedHz), format: .number.precision(.fractionLength(3))) s sampled · \((report.usableSeconds ?? Double(report.usable) / report.template.setup.recordedHz), format: .number.precision(.fractionLength(3))) s eligible for comparison")
                    .font(.caption)
                Text("\(report.knownMissing.formatted()) missing samples · \(report.clippedWords.formatted()) clipped · \(report.adcErrorWords.formatted()) ADC errors")
                    .font(.caption).foregroundStyle(.secondary)
                if report.unknownTime { Text("Time between disconnected segments is unknown.").font(.caption).foregroundStyle(.orange) }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        metrics("Existing detector", report.existing)
                        metrics("Template detector", report.matchedFilter)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        metrics("Existing detector", report.existing)
                        metrics("Template detector", report.matchedFilter)
                    }
                }
                Text(report.weighted ? "This revision uses measured noise weighting." : "This revision uses equal sample weighting.")
                    .font(.caption).foregroundStyle(.secondary)
                if let alternate, alternate.templateSHA256 == report.templateSHA256, alternate.weighted != report.weighted,
                   alternate.annotationRevision == report.annotationRevision {
                    DisclosureGroup(alternate.weighted ? "Compare Measured Noise Weighting" : "Compare Equal Sample Weighting") {
                        HStack(alignment: .top, spacing: 20) {
                            metrics("Existing detector", alternate.existing)
                            metrics("Template detector", alternate.matchedFilter)
                        }.padding(.top, 6)
                    }
                }
                if let decisions = report.decisionPreview, !decisions.isEmpty {
                    DisclosureGroup("Review Detector Decisions") {
                        ForEach(Array(decisions.enumerated()), id: \.offset) { _, decision in
                            decisionRow(decision)
                        }
                    }
                }
                Button("Export Replay Results", action: export).disabled(bench.busy || manifest == nil)
            }
            if let message { Text(message).font(.callout).textSelection(.enabled) }
            if bench.busy { ProgressView().controlSize(.small) }
        }.task { initialize() }
            .onChange(of: bench.busy) { _, busy in if !busy { initialize() } }
    }

    private func templateEvidence(_ template: FixtureStudyTemplate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(template.training.count) for training · \(template.pulses.count) pulses · \(template.reservedValidationRuns.count) reserved for validation")
            Text("\(template.setup.gain) gain · \(template.polarity.rawValue) polarity · \(template.setup.recordedHz.formatted(.number.precision(.fractionLength(0...2)))) readings/s")
            if let low = template.pulses.map(\.height).min(), let high = template.pulses.map(\.height).max(),
               let narrow = template.pulses.map(\.halfHeightWidth).min(), let wide = template.pulses.map(\.halfHeightWidth).max() {
                Text("Training range \(low.formatted(.number.precision(.fractionLength(1)))) to \(high.formatted(.number.precision(.fractionLength(1)))) ADC codes · half height width \(narrow) to \(wide) samples")
            }
        }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var buildControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField("Template name", text: $name).textFieldStyle(.roundedBorder)
            Toggle("I confirm these fixture runs use assembled Rev E.1", isOn: $declaredRev)
            if fixtureRuns.isEmpty { Text("Record fixture runs in Bench Test and import their independent timing on the Filters tab.").font(.caption) }
            ForEach(fixtureRuns) { run in
                Toggle(run.name, isOn: Binding(get: { training.contains(run.id) }, set: {
                    if $0 { training.insert(run.id) } else { training.remove(run.id) }
                })).font(.callout)
            }
            HStack {
                ProfileSampleField("Samples before marker", samples: $before)
                ProfileSampleField("Samples after marker", samples: $after)
            }
            Text("Choose a clean pulse with baseline on both sides. Total support must be 16 to 1,024 samples. Each timing file describes the same independently observed marker.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Empty board noise fit", selection: $noiseID) {
                Text("None").tag(UUID?.none)
                ForEach(noiseRuns) { Text($0.name).tag(Optional($0.id)) }
            }
            DisclosureGroup("Reserve held aside recordings") {
                ForEach((fixtureRuns + noiseRuns).filter { !training.contains($0.id) && $0.id != noiseID }) { run in
                    Toggle(run.name, isOn: Binding(get: { validation.contains(run.id) }, set: {
                        if $0 { validation.insert(run.id) } else { validation.remove(run.id) }
                    })).font(.callout)
                }
                Text("You can also replay matching runs recorded after this revision was saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Current pulse criteria are frozen as the existing detector comparison. Template amplitude, score and residual limits come from the training pulses.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Build from Training Runs", action: build)
                .disabled(bench.busy || !declaredRev || training.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.disabled(bench.busy)
    }

    private func decisionRow(_ item: FixtureReplayDecision) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Button("\(item.detector.capitalized) · peak sample \(item.peakIndex.formatted())") {
                openSample(.init(segment: item.segment, sample: item.peakIndex))
            }.buttonStyle(.link)
            Text("Alignment \(item.alignment, format: .number.precision(.fractionLength(0...3))) · height \(item.amplitude, format: .number.precision(.fractionLength(2))) ADC codes")
            if let width = item.widthUS { Text("Width \(width, format: .number.precision(.fractionLength(2))) µs") }
            if let residual = item.residual { Text("Residual \(residual, format: .number.precision(.fractionLength(2))) ADC codes RMS") }
            Text(item.rejectionReason ?? item.decision.replacingOccurrences(of: "_", with: " ").capitalized)
                .foregroundStyle(.secondary)
        }.font(.caption).padding(.vertical, 3)
    }

    private func metrics(_ title: String, _ values: FixtureReplayMetrics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            if let total = values.totalMatches { Text("\(total) Pulse Matches") }
            Text("\(values.matches) associated with fixture timing")
            Text("\(values.missedInCoverage) in coverage misses")
            Text("\(values.outsideCoverage) outside coverage · \(values.ambiguousTiming) ambiguous")
            Text("\(values.unassociated) unassociated · \(values.earlyTriggerHidLater) preempted")
            if values.untimedDetections > 0 { Text("\(values.untimedDetections) on segments without a timing reference") }
            if let rate = values.falseMatchesPerUsableMinute { Text("\(rate.formatted(.number.precision(.fractionLength(3)))) false matches per usable minute") }
            if let error = values.rmsTimingErrorUS { Text("Timing RMS \(error.formatted(.number.precision(.fractionLength(2)))) µs") }
            if let error = values.rmsAmplitudeErrorCodes { Text("Amplitude RMS \(error.formatted(.number.precision(.fractionLength(2)))) ADC codes") }
            else { Text("Independent amplitude reference unavailable") }
        }.font(.caption).fixedSize(horizontal: false, vertical: true)
    }

    private func initialize() {
        guard !loaded, !bench.busy else { return }
        loaded = true
        let reader = reader, saved = saved
        bench.perform("Loading fixture evidence") {
            let runs = try reader.store.list().compactMap(\.run)
            let templates = try FixtureTemplateStudy.templates(reader.store)
            let report = try saved.flatMap { $0.analyzer == FixtureReplay.analyzer ? try FixtureReplay.load(reader, manifest: $0) : nil }
            let fit = try saved.flatMap { $0.analyzer == FixtureSelection.analyzer ? try FixtureSelection.load(reader, manifest: $0) : nil }
            return (runs, templates, report, fit)
        } completion: {
            runs = $0.0; templates = $0.1; report = $0.2
            manifest = $0.2 == nil ? nil : saved
            let restored = $0.2?.template ?? $0.3?.template
            if let restored, !templates.contains(where: { $0.id == restored.id }) { templates.append(restored) }
            templateID = restored?.id ?? templates.first?.id
            weighted = $0.2?.weighted ?? $0.3?.weighted ?? false
            if let fit = $0.3 {
                operatorConfirmed = fit.operatorConfirmed
                preview = fit.preview
                if let saved {
                    previewKey = .init(template: fit.template.id, weighted: fit.weighted,
                                       operatorConfirmed: fit.operatorConfirmed, range: saved.selection)
                }
            }
        }
    }

    private func build() {
        let selected = runs.filter { training.contains($0.id) }.map { StreamRangeReader(store: reader.store, run: $0) }
        let noise = runs.first { $0.id == noiseID }.map { StreamRangeReader(store: reader.store, run: $0) }
        var rules = baseline
        rules.template = nil
        // Other filters have separate saved review workflows.
        rules.notch60 = false; rules.notch120 = false
        let frozenRules = rules
        let name = name, before = before, after = after
        let reserved = validation.subtracting(training).filter { $0 != noiseID }
        bench.perform("Fitting training pulses") {
            try FixtureTemplateStudy.build(name, training: selected, noise: noise, before: before, after: after,
                                           baseline: frozenRules, reserve: Array(reserved))
        } completion: {
            templates.insert($0, at: 0); templateID = $0.id; weighted = false; operatorConfirmed = false
            message = "Template revision saved. Use separate runs for validation."
        }
    }

    private func inspect() {
        guard let template else { return }
        let reader = reader, selection = selection, weighted = weighted, request = key, confirmed = operatorConfirmed
        preview = nil
        bench.perform("Fitting selected waveform") {
            try FixtureTemplateStudy.inspect(reader, selection: selection, template: template, weighted: weighted, operatorConfirmed: confirmed)
        } completion: {
            preview = $0; previewKey = request
            message = $0 == nil ? "No complete, clean pulse window with positive fitted amplitude is available." : nil
        }
    }

    private func replay() {
        guard let template else { return }
        let reader = reader, weighted = weighted
        bench.perform("Replaying both detectors") {
            let manifest = try FixtureReplay.run(reader, template: template, weighted: weighted)
            return (manifest, try FixtureReplay.load(reader, manifest: manifest))
        } completion: {
            if let report, report.templateSHA256 == $0.1.templateSHA256, report.weighted != $0.1.weighted {
                alternate = report
            }
            manifest = $0.0; report = $0.1; didSave($0.0)
            message = "Replay saved as a new analysis revision."
        }
    }

    private func saveFit() {
        guard let template, shown != nil else { return }
        let reader = reader, selection = selection, weighted = weighted, confirmed = operatorConfirmed
        bench.perform("Saving waveform fit") {
            try FixtureSelection.save(reader, selection: selection, template: template, weighted: weighted, operatorConfirmed: confirmed)
        } completion: {
            didSave($0.0)
            message = "Waveform fit saved as a new analysis revision."
        }
    }

    private func export() {
        guard let manifest else { return }
        let reader = reader
        bench.export(toFolderFor: reader.store, title: "Export Replay Results", progress: "Exporting fixture analysis") { folder in
            try FixtureReplay.export(reader, manifest: manifest, destination: folder)
        }
    }
}

struct FixtureFitPlot: View {
    let preview: FixtureFitPreview
    private var low: Double { (preview.raw + preview.fitted).min().map { floor($0) - 1 } ?? 0 }
    private var high: Double { (preview.raw + preview.fitted).max().map { ceil($0) + 1 } ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 9) {
                VStack(alignment: .trailing) {
                    Text(high.formatted(.number.precision(.fractionLength(0))))
                    Spacer()
                    Text(low.formatted(.number.precision(.fractionLength(0))))
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(height: 140)
                VStack(spacing: 4) {
                    Canvas { context, size in
                        func point(_ i: Double, _ y: Double) -> CGPoint {
                            .init(x: 8 + i / Double(max(1, preview.raw.count - 1)) * (size.width - 16),
                                  y: 8 + (high - y) / (high - low) * (size.height - 16))
                        }
                        let marker = Double(preview.fit.alignment - preview.fit.first) + preview.fit.fractionalOffset
                        var mark = Path()
                        mark.move(to: point(marker, low)); mark.addLine(to: point(marker, high))
                        context.stroke(mark, with: .color(.orange.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        for (values, color) in [(preview.raw, Color.secondary), (preview.fitted, Color.blue)] {
                            var path = Path()
                            for i in values.indices {
                                if i == 0 { path.move(to: point(Double(i), values[i])) }
                                else { path.addLine(to: point(Double(i), values[i])) }
                            }
                            context.stroke(path, with: .color(color), lineWidth: 1.5)
                        }
                    }.frame(height: 140).background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Original ADC waveform and fitted pulse with baseline offset and slope")
                    HStack {
                        Text(preview.fit.first.formatted())
                        Spacer()
                        Text("Original sample index")
                        Spacer()
                        Text((preview.fit.first + UInt64(preview.raw.count - 1)).formatted())
                    }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text("Gray raw ADC codes · blue fitted pulse and baseline · dotted alignment marker")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
