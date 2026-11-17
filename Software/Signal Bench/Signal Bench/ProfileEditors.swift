import SwiftUI

struct ProfileRulesEditor: View {
    @Binding var rules: ProfilePulseRules
    var sampleRate = StreamWire.rate

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Polarity", selection: $rules.polarity) {
                ForEach(ProfilePulseRules.Polarity.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Threshold", selection: $rules.threshold) {
                ForEach(ProfilePulseRules.Threshold.allCases) { Text($0.rawValue).tag($0) }
            }
            ProfileNumberField("Minimum height", value: $rules.height, unit: "ADC codes")
            if rules.threshold == .adaptive {
                ProfileNumberField("Noise multiplier", value: $rules.sigmaMultiplier, unit: "× robust noise")
            }
            ProfileSampleField("Minimum width", samples: $rules.minimumSamples, sampleRate: sampleRate)
            ProfileSampleField("Maximum width", samples: $rules.maximumSamples, sampleRate: sampleRate)
            ProfileSampleField("Minimum separation", samples: $rules.separationSamples, sampleRate: sampleRate)
            Divider()
            Picker("Artifacts", selection: $rules.artifactMode) {
                ForEach(ProfilePulseRules.ArtifactMode.allCases) { Text($0.rawValue).tag($0) }
            }
            ProfileNumberField("Flag tall peaks above", value: $rules.reviewHeight, unit: "ADC codes")
            if rules.artifactMode != .review {
                ProfileSampleField("Maximum spike width", samples: $rules.spikeMaximumSamples, sampleRate: sampleRate)
                ProfileNumberField("Minimum spike slope", value: $rules.spikeMinimumSlope, unit: "codes/sample")
                ProfileNumberField("Noisy interval limit", value: $rules.noisyBlockSigma, unit: "ADC codes")
                ProfileSampleField("Padding before", samples: $rules.paddingBefore, sampleRate: sampleRate)
                ProfileSampleField("Padding after", samples: $rules.paddingAfter, sampleRate: sampleRate)
                if rules.artifactMode == .strict {
                    Text("Strict uses 80% of the entered slope and noise limits and adds one sample to the spike width limit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Approve these local artifact limits", isOn: $rules.approvedArtifactLimits)
            }
            Text("Times use the configured sample interval. A tall peak alone is flagged for review.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 560)
    }
}

struct ProfileLimitsEditor: View {
    @Binding var limits: ProfileLimits

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProfileIntegerField("Fit windows per phase", value: $limits.minimumFitWindows)
            ProfileIntegerField("Holdout windows per phase", value: $limits.minimumHoldoutWindows)
            ProfileNumberField("Usable time per minute", value: $limits.minimumUsableSecondsPerMinute, unit: "s")
            ProfileNumberField("Maximum robust noise", value: $limits.maximumNoise, unit: "ADC codes")
            ProfileNumberField("Maximum drift", value: $limits.maximumDrift, unit: "ADC codes")
            ProfileNumberField("Minimum headroom", value: $limits.minimumHeadroom, unit: "ADC codes")
            ProfileNumberField("Baseline tolerance", value: $limits.baselineTolerance, unit: "ADC codes")
            ProfileIntegerField("Maximum empty board matches per minute", value: $limits.maximumEmptyMatchesPerBlock)
            Toggle("Use these limits for local validation", isOn: $limits.operatorApproved)
        }
        .frame(maxWidth: 560)
    }
}

struct ProfileSetupEditor: View {
    @Binding var setup: CalibrationSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Board label") { TextField("Board label", text: $setup.board).labelsHidden().accessibilityLabel("Board label") }
            LabeledContent("Detector label") { TextField("Detector label", text: $setup.detector).labelsHidden().accessibilityLabel("Detector label") }
            LabeledContent("USB cable and power") { TextField("USB cable and power", text: $setup.cable).labelsHidden().accessibilityLabel("USB cable and power") }
            LabeledContent("Enclosure and light cover") { TextField("Enclosure and light cover", text: $setup.enclosure).labelsHidden().accessibilityLabel("Enclosure and light cover") }
            LabeledContent("Environment and cable routing") { TextField("Environment and cable routing", text: $setup.conditions).labelsHidden().accessibilityLabel("Environment and cable routing") }
            LabeledContent("Local notes") { TextField("Local notes", text: $setup.notes).labelsHidden().accessibilityLabel("Local notes") }
            Picker("Physical J4 position", selection: $setup.gain) {
                Text("Low · open").tag("LOW")
                Text("High · shunt").tag("HIGH")
            }
            Picker("Firmware", selection: $setup.firmware) {
                ForEach(setup.acquisitionDevice == .unoR4 ? ["1.0"] : CalibrationSetup.streamingVersions, id: \.self) { version in
                    Text(version).tag(CalibrationSetup.firmwareLabel(version, board: setup.acquisitionDevice))
                }
            }
            LabeledContent("Recording device", value: setup.acquisitionDevice.title)
            Toggle("Standard J2 wiring and no optional probes", isOn: $setup.standardWiring)
            Text("Unplug USB before changing J1, J4, or the probe wiring.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
    }
}

struct ProfileNumberField: View {
    let label: String
    @Binding var value: Double
    let unit: String

    init(_ label: String, value: Binding<Double>, unit: String) {
        self.label = label
        _value = value
        self.unit = unit
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
            Spacer(minLength: 6)
            TextField(label, value: $value, format: .number.grouping(.never).precision(.fractionLength(0...4)))
                .labelsHidden().frame(width: 80).accessibilityLabel(label)
            Text(unit).font(.caption).foregroundStyle(.secondary).frame(width: 85, alignment: .leading)
        }
    }
}

struct ProfileIntegerField: View {
    let label: String
    @Binding var value: Int

    init(_ label: String, value: Binding<Int>) {
        self.label = label
        _value = value
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
            Spacer(minLength: 6)
            TextField(label, value: $value, format: .number.grouping(.never))
                .labelsHidden().frame(width: 80).accessibilityLabel(label)
            Spacer().frame(width: 85)
        }
    }
}

struct ProfileSampleField: View {
    let label: String
    @Binding var samples: Int

    var sampleRate: Int

    init(_ label: String, samples: Binding<Int>, sampleRate: Int = StreamWire.rate) {
        self.label = label
        _samples = samples
        self.sampleRate = sampleRate
    }

    var body: some View {
        ProfileNumberField(label, value: Binding(
            get: { Double(samples) * 1_000_000 / Double(sampleRate) },
            set: { input in
                if input.isFinite, (0...327_680).contains(input) { samples = Int((input * Double(sampleRate) / 1_000_000).rounded()) }
            }
        ), unit: "µs")
    }
}

struct ProfilePreview: View {
    let record: CaptureRecord
    let result: ProfileWindowResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Canvas { context, size in
                guard record.samples.count > 1 else { return }
                let n = record.samples.count
                let values = record.samples.map { Int($0 & 0x0fff) }
                let lo = max(0, (values.min() ?? 0) - 20)
                let hi = min(4095, (values.max() ?? 4095) + 20)
                let y: (Double) -> Double = { Double(size.height) * (1 - ($0 - Double(lo)) / Double(max(1, hi - lo))) }
                let x: (Int) -> Double = { Double($0) / Double(n - 1) * size.width }
                for interval in result.intervals {
                    let rect = CGRect(x: x(interval.start), y: 0,
                                      width: max(1, x(interval.end) - x(interval.start)), height: size.height)
                    context.fill(Path(rect), with: .color(.orange.opacity(interval.omitFromCleaned ? 0.24 : 0.10)))
                }
                if let baseline = result.baseline {
                    var center = Path()
                    center.move(to: CGPoint(x: 0, y: y(baseline)))
                    center.addLine(to: CGPoint(x: size.width, y: y(baseline)))
                    context.stroke(center, with: .color(.secondary), style: .init(lineWidth: 0.7, dash: [4, 3]))
                    context.draw(Text("Baseline \(Int(baseline.rounded()))").font(.caption2).foregroundStyle(.secondary),
                                 at: CGPoint(x: size.width - 7, y: min(size.height - 9, max(9, y(baseline) + 9))), anchor: .trailing)
                }
                // Min/max per screen column retains narrow pulses.
                let columns = max(1, min(n, Int(size.width)))
                var trace = Path()
                for column in 0..<columns {
                    let start = column * n / columns
                    let end = (column + 1) * n / columns
                    let block = values[start..<end]
                    let px = Double(column) / Double(columns) * size.width
                    trace.move(to: CGPoint(x: px, y: y(Double(block.min() ?? lo))))
                    trace.addLine(to: CGPoint(x: px, y: y(Double(block.max() ?? hi))))
                }
                context.stroke(trace, with: .color(.primary.opacity(0.8)), lineWidth: 1)
                for candidate in result.candidates.prefix(256) {
                    let point = CGPoint(x: x(candidate.peak), y: y(Double(values[candidate.peak])))
                    let dot = CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)
                    context.fill(Path(ellipseIn: dot), with: .color(candidate.decision == "match" ? .green : .orange))
                }
            }
            .frame(height: 175)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Original waveform with pulse peaks and excluded intervals")
            Text("0 to \(record.samples.count.formatted()) samples · raw ADC codes · orange shows exclusions or rejected peaks")
                .font(.caption).foregroundStyle(.secondary)
            if result.complete {
                Text("\(result.matchCount.formatted()) pulse matches · \(result.candidates.count.formatted()) candidates · \(result.intervals.count.formatted()) exclusions")
                    .font(.callout.monospacedDigit())
            } else {
                Text("Analysis incomplete").font(.callout.weight(.semibold)).foregroundStyle(.orange)
            }
            ForEach(result.reasons, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            if !result.candidates.isEmpty {
                DisclosureGroup("Pulse decisions") {
                    ForEach(result.candidates.prefix(24)) { candidate in
                        Text("Samples \(candidate.start) to \(candidate.end - 1) · \(candidate.decision.replacingOccurrences(of: "_", with: " "))\(candidate.review ? " · review" : "")")
                            .font(.caption.monospacedDigit())
                    }
                    if result.candidates.count > 24 { Text("Export results for the full list.").font(.caption) }
                }
            }
        }
    }
}
