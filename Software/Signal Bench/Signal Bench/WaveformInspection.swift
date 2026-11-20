import SwiftUI

nonisolated struct WaveformZoom {
    let bounds: StreamSelection
    let minimum: Double

    var maximum: Double { bounds.upper - bounds.lower }
    var smallest: Double { min(maximum, minimum) }

    func position(for span: Double) -> Double {
        guard smallest > 0, maximum > smallest, span.isFinite else { return 0 }
        return min(1, max(0, log(maximum / max(span, smallest)) / log(maximum / smallest)))
    }

    func width(at position: Double) -> Double {
        guard smallest > 0, maximum > smallest else { return maximum }
        return position >= 1 ? smallest : maximum * exp(-position * log(maximum / smallest))
    }

    func window(center: Double, span: Double) -> StreamSelection {
        let width = min(maximum, max(smallest, span))
        let lower = max(bounds.lower, min(bounds.upper - width, center - width / 2))
        return .init(lower: lower, upper: min(bounds.upper, lower + width))
    }
}

struct WaveformZoomControl: View {
    let bounds: StreamSelection
    let selection: StreamSelection
    let minimum: Double
    let change: (Double) -> Void
    let home: () -> Void

    var body: some View {
        let zoom = WaveformZoom(bounds: bounds, minimum: minimum)
        let span = selection.upper - selection.lower
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9) {
                slider(zoom, span: span)
                readout(span)
                homeButton
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) { slider(zoom, span: span); homeButton }
                readout(span)
            }
        }
    }

    private func slider(_ zoom: WaveformZoom, span: Double) -> some View {
        HStack(spacing: 9) {
            Text("Zoom").font(.callout)
            Slider(value: Binding(get: { zoom.position(for: span) }, set: { change(zoom.width(at: $0)) }), in: 0...1)
                .accessibilityLabel("Waveform zoom")
                .accessibilityValue(WaveformTime.span(span))
                .help("Adjust the visible waveform span")
                .disabled(zoom.maximum <= zoom.smallest)
                .frame(minWidth: 58, idealWidth: 135, maxWidth: 250)
        }
    }

    private func readout(_ span: Double) -> some View {
        Text(WaveformTime.span(span)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .fixedSize().accessibilityLabel("Visible span, " + WaveformTime.span(span))
    }

    private var homeButton: some View {
        Button("Home", action: home).help("Fit the available waveform").disabled(!bounds.valid)
    }
}

nonisolated enum WaveformTime {
    static func span(_ seconds: Double) -> String {
        let microseconds = (max(0, seconds) * 1_000_000).rounded()
        let s = (microseconds / 1_000_000).formatted(.number.precision(.fractionLength(3...6)))
        let ms = (microseconds / 1_000).formatted(.number.precision(.fractionLength(0...3)))
        return "\(s) s · \(ms) ms"
    }
}

struct DotDensityControl: View {
    @Binding var percent: Double
    var plot: StudioPlot?
    var rendererLimited = false
    private var displayPercent: String { percent.formatted(.number.precision(.fractionLength(0...2))) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                Text("Dot density").font(.callout)
                Slider(value: Binding(get: { log10(percent) }, set: { percent = pow(10, $0) }), in: -2...2, step: 0.01)
                    .accessibilityLabel("Dot density")
                    .accessibilityValue("\(displayPercent) percent")
                    .frame(minWidth: 58, idealWidth: 135, maxWidth: 250)
                Text("\(displayPercent)%").font(.callout.monospacedDigit()).fixedSize()
            }
            if let plot, let dots = plot.dots {
                let shown = rendererLimited ? min(dots.values.count, WaveformDots.canvasLimit) : dots.values.count
                if dots.averaged {
                    Text("\(shown.formatted()) averaged dots · \(plot.stats.samples.formatted()) readings in overview")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    let denominator = dots.eligibleReadings ?? (plot.stats.samples - min(plot.stats.samples, plot.stats.adcErrors))
                    if denominator > 0 {
                        Text("\(shown.formatted()) original dots · \(denominator.formatted()) valid readings")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            } else if plot != nil {
                Text("Overview bins. Zoom in to see original dots.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct WaveformSignalQuality: View {
    let stats: StreamStats
    let estimated: Bool
    var board: AcquisitionBoard = .picoW

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), alignment: .leading)], alignment: .leading, spacing: 7) {
                reading("Low rail · 0", count: stats.lowRail, total: stats.samples - stats.adcErrors)
                reading("High rail · \(board.maxCode)", count: stats.highRail, total: stats.samples - stats.adcErrors)
                reading("ADC errors", count: stats.adcErrors, total: stats.samples)
            }
            if board == .unoR4 {
                Text("Devboard overload can occur below the UNO’s ADC rail. Check CSA, GAIN and SHP in Diagnosis.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if estimated {
                Text("Overview estimates. Zoom in for exact counts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if stats.clipped > 0 {
                SignalClippingHelp()
            }
        }
    }

    private func reading(_ label: String, count: UInt64?, total: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if let count, total > 0 {
                let fraction = Double(count) / Double(total)
                let percentage = fraction > 0 && fraction < 0.0001 ? "<0.01%" : fraction.formatted(.percent.precision(.fractionLength(0...2)))
                Text("\(count.formatted()) · \(percentage)")
                    .font(.caption.monospacedDigit())
            } else {
                Text("Unavailable").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SignalClippingHelp: View {
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Check clipping", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Rail codes mean the signal reached the ADC’s range limit. The original height is lost. ADC errors are counted separately.")
                Text("1. Unplug USB before moving wires or changing J4. Confirm the three J2 wires, keep signal and ground short and together, leave J1 empty, and set J4 to LOW.")
                Text("2. Reconnect USB. Measure J3.2 (3V3) and J3.3 (VMID) against J3.1 GND. Use a scope to compare CSA, GAIN, SHP and J2.3. Connect the probe ground only to GND.")
                Text("3. Compare 100,000 and 500,000 samples/s with the same wiring. For a Pico only check, remove USB power, disconnect the Devboard ADC wire, and tie GP26 to AGND. A low rail reading is expected for that control.")
                Text("4. Once the empty board is stable, unplug USB and reconnect the detector under an opaque cover.")
            }
            .font(.callout).foregroundStyle(.secondary).padding(.top, 4)
            .fixedSize(horizontal: false, vertical: true)
        }.font(.callout)
    }
}

struct WaveformFPSControl: View {
    @Binding var fps: Int

    var body: some View {
        Picker("FPS Goal", selection: $fps) {
            ForEach([5, 10, 15, 30, 60], id: \.self) { Text($0.formatted()).tag($0) }
        }
        .fixedSize()
        .help("Maximum display refreshes per second")
    }
}

struct WaveformPositionControl: View {
    let bounds: StreamSelection
    let selection: StreamSelection
    let change: (Double) -> Void

    var body: some View {
        let width = selection.upper - selection.lower
        let travel = max(0, bounds.upper - bounds.lower - width)
        HStack(spacing: 9) {
            Text("Position").font(.callout)
            Slider(value: Binding(
                get: { travel > 0 ? min(1, max(0, (selection.lower - bounds.lower) / travel)) : 0 },
                set: { change(bounds.lower + $0 * travel + width / 2) }), in: 0...1)
                .accessibilityLabel("Waveform position")
                .accessibilityValue(WaveformTime.span(selection.lower))
                .disabled(travel <= 1e-9 || !bounds.valid)
        }
    }
}
