import SwiftUI

struct CurveQualityView: View {
    let manifest: CurveManifest
    var body: some View {
        let stats = manifest.stats
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            row("Maximum error", stats.count > 0 ? codes(stats.maximum) : "Unavailable")
            row("RMS error", codes(stats.rms))
            row("Signed bias", codes(stats.bias))
            row("95th and 99th percentiles", codes(stats.p95) + " / " + codes(stats.p99))
            row("Exact and modeled readings", "\(stats.exact.formatted()) / \(stats.modeled.formatted())")
            row("Clipped and invalid readings", "\(stats.clipped.formatted()) / \(stats.invalid.formatted())")
            row("Known missing time", manifest.missingSeconds.formatted(.number.precision(.fractionLength(0...6))) + " s")
            row("Known missing readings", manifest.missingReadings.formatted())
            row("Recorded coverage", manifest.capturedSeconds.formatted(.number.precision(.fractionLength(0...6))) + " s")
            row("Unknown boundaries", manifest.unknownBoundaries.count.formatted())
            row(manifest.wholeRun ? "Source samples and indexes" : "Source blocks and indexes",
                ByteCountFormatter.string(fromByteCount: manifest.sourceBytes + manifest.sourceIndexBytes, countStyle: .file))
            row("Measured lossless alternative", ByteCountFormatter.string(fromByteCount: manifest.losslessBytes, countStyle: .file))
        }.font(.callout).textSelection(.enabled)
        Text("Error uses every valid reading. Percentiles round up to the nearest 1/256 ADC code. A reading can have both clipping and ADC errors.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }

    private func codes(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(0...6))) + " codes" } ?? "Unavailable"
    }
}

struct CurveFitSheet: View {
    let runName: String
    let duration: Double
    let selection: StreamSelection
    let preserve: [ReviewRange]
    let reader: StreamRangeReader
    @ObservedObject var bench: StreamingBench
    let close: () -> Void
    @State private var name = "Waveform Curve"
    @State private var choice: Double = 1
    @State private var custom = 1.0
    @State private var visible = false
    @State private var preview: CurveManifest?
    @State private var previewRequest: CurveRequest?
    @State private var previewRange: StreamSelection?
    private var limit: Double { choice == 0 ? custom : choice }
    private var range: StreamSelection { visible ? selection : .init(lower: 0, upper: duration) }
    private var request: CurveRequest { .init(tolerance: limit, preserve: preserve) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Curve to Run").font(.title2.weight(.semibold))
            Text(runName).foregroundStyle(.secondary)
            TextField("Curve name", text: $name)
            Picker("Range", selection: $visible) {
                Text("Full Run").tag(false)
                Text("Visible Range").tag(true)
            }.pickerStyle(.segmented)
            Picker("Maximum error", selection: $choice) {
                ForEach([1.0, 4, 16, 32], id: \.self) { Text($0.formatted() + " code" + ($0 == 1 ? "" : "s")).tag($0) }
                Text("Custom").tag(0.0)
            }
            if choice == 0 { TextField("ADC codes, 0.125 to 64", value: $custom, format: .number).textFieldStyle(.roundedBorder) }
            Text("The original stays available. No curve is fitted across gaps or bad readings.")
                .font(.callout).foregroundStyle(.secondary)
            if !preserve.isEmpty { Text("\(preserve.count) ranges will stay exact.").font(.callout) }
            if let preview, previewRequest?.tolerance == limit, previewRange == previewSelection {
                DisclosureGroup("Measured Preview") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(preview.selection.lower.formatted()) to \(preview.selection.upper.formatted()) s")
                        Text("Stored curve " + ByteCountFormatter.string(fromByteCount: preview.storedBytes, countStyle: .file))
                        CurveQualityView(manifest: preview)
                    }.padding(.top, 5)
                }
            }
            if let operation = bench.operation { Text(operation).foregroundStyle(.secondary) }
            if let notice = bench.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Button("Cancel") { if bench.busy { bench.cancelWork() }; close() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Preview Selected Range") { makePreview() }.disabled(bench.busy || !request.valid || !previewSelection.valid)
                Button("Queue Fit") {
                    bench.queueCurve(reader, name: name, selection: range,
                        spec: .init(action: .fit, curve: UUID(), request: request)) { close() }
                }.keyboardShortcut(.defaultAction)
                    .disabled(bench.busy || !request.valid || !range.valid || (try? SessionStore.projectName(name)) == nil)
            }
        }.padding(22).frame(width: 490)
    }

    private var previewSelection: StreamSelection {
        let width = 2_000_000 / reader.run.settings.recordedRate
        return .init(lower: min(selection.lower, duration), upper: min(duration, selection.upper, selection.lower + width))
    }

    private func makePreview() {
        let input = reader, range = previewSelection, request = request
        bench.perform("Measuring preview range") {
            let pin = try ProjectJob.Input.pin(input, selection: range)
            let parent = try input.store.runDirectory(input.run.id)
            let stage = try StreamFiles.directory(".curve-preview-" + UUID().uuidString, in: parent, create: true)
            defer { try? FileManager.default.removeItem(at: stage) }
            return try CurveStore.fit(input, id: UUID(), name: "Preview", selection: range, request: request, fingerprint: pin.source,
                stage: stage, checkpoint: { try Task.checkCancellation() }, progress: { _ in })
        } completion: { result in preview = result; previewRequest = request; previewRange = range }
    }
}

struct CurveCopySheet: View {
    let reader: StreamRangeReader
    let manifest: CurveManifest
    @ObservedObject var bench: StreamingBench
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Create Standalone Curve Run").font(.title2.weight(.semibold))
            TextField("Run name", text: $name).textFieldStyle(.roundedBorder)
            Text("The new run includes timing, settings, notes, and original analysis reports. Modeled readings are for diagnostic review. The source stays in the Library.")
                .foregroundStyle(.secondary)
            Text("Verified representation " + ByteCountFormatter.string(fromByteCount: manifest.storedBytes, countStyle: .file))
                .font(.headline.monospacedDigit())
            CurveQualityView(manifest: manifest)
            if let notice = bench.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Queue Copy") {
                    bench.queueCurve(reader, name: name, selection: manifest.selection,
                        spec: .init(action: .standalone, curve: manifest.id, indexHash: manifest.indexHash)) { dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(bench.busy || (try? SessionStore.projectName(name)) == nil)
            }
        }.padding(22).frame(width: 470)
            .onAppear {
                var prefix = reader.run.name
                while prefix.utf8.count > 110 { prefix.removeLast() }
                name = prefix + " Curve"
            }
    }
}

struct CurveExportSheet: View {
    let reader: StreamRangeReader
    let manifest: CurveManifest
    let selection: StreamSelection
    @ObservedObject var bench: StreamingBench
    let close: () -> Void
    @State private var name = ""
    @State private var csv = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Curve").font(.title2.weight(.semibold))
            Picker("Format", selection: $csv) {
                Text("Curve ZIP").tag(false)
                Text("Visible Range CSV").tag(true)
            }
            TextField("File name", text: $name).textFieldStyle(.roundedBorder)
            Text(csv ? "CSV includes original reading indices and identifies exact and modeled values." :
                    "ZIP includes the full saved representation, original timing, quality, flags, and exclusions.")
                .foregroundStyle(.secondary)
            if let notice = bench.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Choose Folder…") {
                    bench.queueCurve(reader, name: name, selection: csv ? selection : manifest.selection,
                        spec: .init(action: csv ? .csv : .zip, curve: manifest.id, indexHash: manifest.indexHash),
                        destination: true, onQueued: close)
                }.keyboardShortcut(.defaultAction).disabled(bench.busy || (try? SessionStore.projectName(name)) == nil)
            }
        }.padding(22).frame(width: 420).onAppear { name = manifest.name }
    }
}

struct CurveTrashSheet: View {
    let source: StreamRun
    let bytes: Int64?
    let standalone: StreamRun
    @ObservedObject var bench: StreamingBench
    let blockers: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move Source to Trash").font(.title2.weight(.semibold))
            Text(source.name).font(.headline)
            if let url = try? bench.project?.runDirectory(source.id) {
                Text(url.path).font(.caption).textSelection(.enabled)
            }
            if let bytes { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " of source sample files").font(.callout) }
            Text("Original readings, reports, and notes in this folder move to Trash. Modeled values cannot recover the discarded readings. Emptying Trash frees the space.")
                .foregroundStyle(.secondary)
            Text("Type the source run name to confirm.")
            TextField("Source run name", text: $typed).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Move to Trash", role: .destructive) {
                    bench.trashCurveSource(standalone, typed: typed)
                    dismiss()
                }.disabled(typed != source.name || bench.busy || bench.projectJobsUnfinished || !blockers.isEmpty)
            }
        }.padding(22).frame(width: 460)
    }
}
