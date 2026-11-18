import SwiftUI

struct RunPlaybackControls: View {
    let playback: RunPlayback
    let range: StreamSelection
    let ready: Bool
    @Environment(\.scenePhase) private var scenePhase

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    buttons
                    Spacer(minLength: 8)
                    timeLabel
                }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 7) {
                    buttons
                    timeLabel
                }
            }
            if range.valid {
                Slider(value: Binding(get: { playback.position ?? range.lower },
                                      set: { playback.seek(to: $0, at: now) }),
                       in: range.lower...range.upper) {
                    Text("Playback position")
                }
                .labelsHidden()
                .accessibilityValue(timeString)
            }
        }
        .disabled(!ready || !range.valid)
        .onChange(of: range, initial: true) { _, value in playback.show(value) }
        .onChange(of: ready) { _, ready in if !ready { playback.pause(at: now) } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { playback.pause(at: now) } }
        .onDisappear { playback.pause(at: now) }
        .task(id: playback.playing) {
            while playback.playing, !Task.isCancelled {
                playback.advance(to: now)
                do { try await Task.sleep(for: .milliseconds(33)) }
                catch { return }
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button(playback.playing ? "Pause" : "Play", systemImage: playback.playing ? "pause.fill" : "play.fill") {
                if playback.playing { playback.pause(at: now) }
                else { playback.play(at: now) }
            }
            .buttonStyle(.borderedProminent)
            .help("Play or pause the visible waveform range")
            Button {
                playback.seek(to: range.lower, at: now)
            } label: {
                Label("Return to Start", systemImage: "backward.end.fill")
                    .labelStyle(.iconOnly)
            }
            .help("Return to the start of the visible range")
            Picker("Speed", selection: Binding(get: { playback.speed },
                                                 set: { playback.changeSpeed(to: $0, at: now) })) {
                ForEach(RunPlaybackSpeed.allCases) { Text($0.title).tag($0) }
            }.fixedSize()
        }
    }

    private var timeLabel: some View {
        Text(timeString).font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
    }

    private var timeString: String {
        guard range.valid else { return "No visible range" }
        let digits = min(9, max(2, Int(ceil(-log10(max(1e-9, range.upper - range.lower)))) + 1))
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(digits))
        let current = (playback.position ?? range.lower).formatted(format)
        let end = range.upper.formatted(format)
        return "\(current) / \(end) s · Visible range"
    }
}

/// A lightweight overlay. Moving the playhead does not redraw or reload
/// the chart's sample data, gaps, flags or cursors.
struct RunPlaybackMarker: View {
    let playback: RunPlayback
    let range: StreamSelection

    var body: some View {
        GeometryReader { geometry in
            if range.valid, playback.range == range, let position = playback.position {
                let width = max(1, geometry.size.width - StreamWaveform.left - StreamWaveform.right)
                let fraction = min(1, max(0, (position - range.lower) / (range.upper - range.lower)))
                let x = StreamWaveform.left + fraction * width
                let y = max(12, geometry.size.height - 26)
                Path { path in
                    path.move(to: CGPoint(x: x, y: 12))
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                .stroke(.purple, lineWidth: 1.5)
                Circle().fill(.purple).frame(width: 7, height: 7).position(x: x, y: 12)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
