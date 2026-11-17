import SwiftUI

struct WaveformView: View {
    let record: CaptureRecord
    @State private var zoom: Double = 1
    @State private var position: Double = 0
    @State private var cursorA: Double = 0
    @State private var cursorB: Double = 0

    private var indexA: Int { min(max(0, Int(cursorA)), max(0, record.samples.count - 1)) }
    private var indexB: Int { min(max(0, Int(cursorB)), max(0, record.samples.count - 1)) }
    private var statistics: SampleStatistics { SampleStatistics.calculate(record.samples, from: indexA, to: indexB) }

    private var range: Range<Int> {
        let n = record.samples.count
        guard n > 0 else { return 0..<0 }
        let width = max(1, min(n, Int(Double(n) / zoom)))
        let start = min(n - width, Int(Double(n - width) * position))
        return start..<(start + width)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Waveform").font(.headline)
                    Text("ADC codes · sample time is nominal").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Zoom").font(.caption).foregroundStyle(.secondary)
                Slider(value: $zoom, in: 1...32, step: 1).frame(width: 125).accessibilityLabel("Waveform zoom")
                Text("\(Int(zoom))×").font(.caption.monospacedDigit()).frame(width: 28, alignment: .trailing)
            }
            if record.samples.isEmpty {
                ContentUnavailableView("No waveform", systemImage: "waveform", description: Text("This record contains no retained samples."))
                    .frame(height: 240)
            } else {
                Canvas { context, size in
                    drawWaveform(context: &context, size: size)
                }
                .frame(height: 245)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Waveform, samples \(range.lowerBound) to \(max(range.lowerBound, range.upperBound - 1))")
                HStack {
                    Text("Sample \(range.lowerBound)")
                    Spacer()
                    Text("Sample \(max(range.lowerBound, range.upperBound - 1))")
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Label("ADC", systemImage: "minus").foregroundStyle(Color.accentColor)
                    if record.metadata["baseline"] != nil { Label("Baseline", systemImage: "minus").foregroundStyle(.orange) }
                    if record.metadata["threshold"] != nil { Label(record.metadata["tag"] == "CAL" ? "Quiet limits" : "Threshold", systemImage: "minus").foregroundStyle(.red) }
                    if !record.events.isEmpty { Label("Candidate peak", systemImage: "line.diagonal").foregroundStyle(.purple) }
                }.font(.caption)
                if zoom > 1 {
                    Slider(value: $position, in: 0...1).accessibilityLabel("Waveform position")
                }
                measurementControls
            }
        }
        .onAppear(perform: resetCursors)
        .onChange(of: record.id) { _, _ in resetCursors() }
        .onChange(of: record.capturedAt) { _, _ in resetCursors() }
    }

    private func resetCursors() {
        cursorA = 0
        cursorB = Double(max(0, record.samples.count - 1))
        zoom = 1; position = 0
    }

    private func cursorLabel(_ index: Int) -> String {
        let word = record.samples[index]
        let value = Int(word & 0x0fff)
        let timestamp = SampleStatistics.nominalMicroseconds(index: index, sampleRate: record.metadata["sample_hz"])
        let time = timestamp.map { String(format: " · %.1f µs nominal", $0) } ?? " · time unavailable"
        return "Sample \(index) · \(value) codes\(time)" + (word & 0x8000 != 0 ? " · ADC error" : "")
    }

    @ViewBuilder private var measurementControls: some View {
        let upper = Double(max(1, record.samples.count - 1))
        let stats = statistics
        VStack(alignment: .leading, spacing: 10) {
            Divider().padding(.top, 4)
            Text("Measure samples").font(.headline)
            Text("Cursor A is blue and B is orange. Markers appear when their samples are in view. Times use the configured sample rate.")
                .font(.caption).foregroundStyle(.secondary)
            cursorControl("A", value: $cursorA, index: indexA, upper: upper)
            cursorControl("B", value: $cursorB, index: indexB, upper: upper)
            let delta = Int(record.samples[indexB] & 0x0fff) - Int(record.samples[indexA] & 0x0fff)
            let interval = SampleStatistics.nominalMicroseconds(index: abs(indexB - indexA), sampleRate: record.metadata["sample_hz"]).map { indexB < indexA ? -$0 : $0 }
            Text("B minus A: \(delta) codes · \(interval.map { String(format: "%.1f µs nominal", $0) } ?? "time unavailable")")
                .font(.callout.monospacedDigit())
            if record.samples[indexA] & 0x8000 != 0 || record.samples[indexB] & 0x8000 != 0 {
                Text("A cursor is on a sample with an ADC error; its value is diagnostic only.").font(.caption).foregroundStyle(.orange)
            }
            if let mean = stats.mean, let deviation = stats.deviation, let low = stats.minimum, let high = stats.maximum {
                Text("Selected interval: \(stats.count) samples · mean \(mean, specifier: "%.2f") codes · standard deviation \(deviation, specifier: "%.2f") codes · range \(low) to \(high)")
                    .font(.callout.monospacedDigit()).textSelection(.enabled)
            } else {
                Text("No valid samples in the selected interval.").font(.callout).foregroundStyle(.secondary)
            }
            Text("\(stats.errorCount) ADC error samples excluded. Standard deviation describes the selected samples; choose a quiet interval to investigate noise.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func cursorControl(_ label: String, value: Binding<Double>, index: Int, upper: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(label): \(cursorLabel(index))").font(.caption.monospacedDigit())
            HStack(spacing: 10) {
                Slider(value: value, in: 0...upper, step: 1).disabled(record.samples.count < 2)
                    .accessibilityLabel("Cursor \(label) sample")
                Stepper("Cursor \(label)", value: value, in: 0...upper, step: 1)
                    .labelsHidden().disabled(record.samples.count < 2).accessibilityLabel("Adjust cursor \(label)")
            }
        }
    }

    private var thresholdLevels: [Double] {
        guard let base = record.metadata["baseline"].flatMap(Double.init), base.isFinite,
              let threshold = record.metadata["threshold"].flatMap(Double.init), threshold.isFinite,
              (0...4095).contains(base), (0...4095).contains(threshold) else { return [] }
        if record.metadata["tag"] == "CAL" && threshold > 0 { return [base - threshold, base + threshold] }
        let negative = (record.metadata["profile"] ?? record.metadata["processing_profile"]) == "NEGATIVE"
        return [base + (negative ? -threshold : threshold)]
    }

    private func drawWaveform(context: inout GraphicsContext, size: CGSize) {
        guard !range.isEmpty, size.width > 0, size.height > 0 else { return }
        let left: CGFloat = 46, right: CGFloat = 10, top: CGFloat = 12, bottom: CGFloat = 12
        let width = max(1, size.width - left - right), height = max(1, size.height - top - bottom)
        let samples = record.samples
        var low = 4095, high = 0
        for index in range { let value = Int(samples[index] & 0x0fff); low = min(low, value); high = max(high, value) }
        if let baseline = record.metadata["baseline"].flatMap(Double.init), baseline.isFinite, baseline >= 0, baseline <= 4095 { low = min(low, Int(baseline)); high = max(high, Int(baseline)) }
        for level in thresholdLevels {
            low = min(low, Int(floor(level))); high = max(high, Int(ceil(level)))
        }
        let pad = max(8, (high - low) / 10)
        low = max(0, low - pad); high = min(4095, high + pad)
        if high <= low { high = low + 1 }
        func y(_ value: Double) -> CGFloat { top + height * (1 - CGFloat((value - Double(low)) / Double(high - low))) }
        for tick in 0...4 {
            let value = Double(low) + Double(high - low) * Double(tick) / 4
            let yy = y(value)
            var line = Path(); line.move(to: CGPoint(x: left, y: yy)); line.addLine(to: CGPoint(x: left + width, y: yy))
            context.stroke(line, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)
            context.draw(Text("\(Int(value))").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: left - 6, y: yy), anchor: .trailing)
        }
        // Keep every sample represented in an extrema envelope when zoomed out.
        // Do not create empty bins for short records. Each sample then shares
        // its horizontal coordinate with the cursor and candidate markers.
        let columns = WaveformProjection.columnCount(sampleCount: range.count, pixelWidth: Int(width.rounded(.down)))
        var trace = Path()
        for column in 0..<columns {
            let first = range.lowerBound + column * range.count / columns
            let last = min(range.upperBound, range.lowerBound + (column + 1) * range.count / columns)
            guard first < last else { continue }
            var lo = 4095, hi = 0
            for index in first..<last { let v = Int(samples[index] & 0x0fff); lo = min(lo, v); hi = max(hi, v) }
            let x = left + CGFloat(column) / CGFloat(max(1, columns - 1)) * width
            let lowY = y(Double(lo)), highY = y(Double(hi))
            if lo == hi {
                // A zero-length stroke is invisible. Give a constant bin a
                // small horizontal mark so quiet traces remain visible.
                trace.move(to: CGPoint(x: max(left, x - 0.5), y: lowY))
                trace.addLine(to: CGPoint(x: min(left + width, x + 0.5), y: lowY))
            } else {
                trace.move(to: CGPoint(x: x, y: lowY))
                trace.addLine(to: CGPoint(x: x, y: highY))
            }
        }
        context.stroke(trace, with: .color(.accentColor), lineWidth: 1)
        // Draw reference levels over the envelope so dense noise does not hide them.
        if let base = record.metadata["baseline"].flatMap(Double.init), base.isFinite, (Double(low)...Double(high)).contains(base) {
            var baseline = Path(); baseline.move(to: CGPoint(x: left, y: y(base))); baseline.addLine(to: CGPoint(x: left + width, y: y(base)))
            context.stroke(baseline, with: .color(.orange.opacity(0.9)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        for level in thresholdLevels where (Double(low)...Double(high)).contains(level) {
            var line = Path(); line.move(to: CGPoint(x:left,y:y(level))); line.addLine(to:CGPoint(x:left+width,y:y(level)))
            context.stroke(line,with:.color(.red.opacity(0.9)),style:StrokeStyle(lineWidth:1,dash:[2,4]))
        }

        for event in record.events {
            guard let text = event["peak"], let peak = Int(text), range.contains(peak) else { continue }
            let x = left + CGFloat(WaveformProjection.fraction(index: peak, first: range.lowerBound, count: range.count)) * width
            var marker = Path(); marker.move(to: CGPoint(x: x, y: top)); marker.addLine(to: CGPoint(x: x, y: top + height))
            context.stroke(marker, with: .color(.purple.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        for (index, color) in [(indexA, Color.blue), (indexB, Color.orange)] where range.contains(index) {
            let x = left + CGFloat(WaveformProjection.fraction(index: index, first: range.lowerBound, count: range.count)) * width
            var marker = Path(); marker.move(to: CGPoint(x: x, y: top)); marker.addLine(to: CGPoint(x: x, y: top + height))
            context.stroke(marker, with: .color(color.opacity(0.85)), style: StrokeStyle(lineWidth: 1, dash: [6, 3]))
        }
    }
}

struct RecordDetailsView: View {
    let record: CaptureRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Record details").font(.headline)
            Text("Qualified heights are not a radiation identification. Exposure is not qualified for a rate.")
                .font(.callout).foregroundStyle(.secondary)
            if !record.complete {
                Label("This record is incomplete. Its data is retained for inspection.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.callout)
            }
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 7) {
                ForEach(record.metadata.keys.sorted(), id: \.self) { key in
                    GridRow {
                        Text(key.replacingOccurrences(of: "_", with: " ").capitalized).foregroundStyle(.secondary)
                        Text(record.metadata[key] ?? "").textSelection(.enabled)
                    }
                }
            }.font(.callout)
            if !record.events.isEmpty {
                Divider().padding(.vertical, 4)
                Text("Candidates").font(.headline)
                ForEach(Array(record.events.enumerated()), id: \.offset) { index, event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Candidate \(index + 1)").font(.subheadline.weight(.semibold))
                        Text(event.keys.sorted().map { "\($0): \(event[$0] ?? "")" }.joined(separator: "  ·  "))
                            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                }
            }
        }
    }
}
