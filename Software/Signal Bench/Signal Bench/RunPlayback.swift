import Foundation
import Observation

enum RunPlaybackSpeed: Double, CaseIterable, Identifiable {
    case quarter = 0.25, half = 0.5, normal = 1, double = 2, five = 5, ten = 10, twentyFive = 25

    var id: Double { rawValue }
    var title: String { rawValue.formatted(.number.precision(.fractionLength(0...2))) + "×" }
}

/// Follows the times on a saved waveform. The wall clock only determines
/// how quickly the cursor moves. Playback never reads or changes samples.
@MainActor @Observable
final class RunPlayback {
    private(set) var range: StreamSelection?
    private(set) var position: Double?
    private(set) var playing = false
    private(set) var speed: RunPlaybackSpeed = .normal

    @ObservationIgnored private var startedAt = 0.0
    @ObservationIgnored private var startedFrom = 0.0

    func show(_ range: StreamSelection) {
        guard self.range != range else { return }
        playing = false
        self.range = range.valid ? range : nil
        if let position, let range = self.range, (range.lower...range.upper).contains(position) { return }
        position = nil
    }

    func play(at now: Double) {
        guard !playing, let range, now.isFinite else { return }
        let start = position.flatMap { $0 < range.upper ? $0 : nil } ?? range.lower
        seek(to: start, at: now)
        playing = true
    }

    func pause(at now: Double) {
        advance(to: now)
        playing = false
    }

    func seek(to time: Double, at now: Double) {
        guard let range, time.isFinite, now.isFinite else { return }
        let bounded = min(range.upper, max(range.lower, time))
        position = bounded
        startedAt = now
        startedFrom = bounded
        if bounded == range.upper { playing = false }
    }

    func changeSpeed(to newSpeed: RunPlaybackSpeed, at now: Double) {
        guard now.isFinite else { return }
        advance(to: now)
        speed = newSpeed
        if playing, let position { seek(to: position, at: now) }
    }

    func advance(to now: Double) {
        guard playing, let range, now.isFinite else { return }
        let next = min(range.upper, startedFrom + max(0, now - startedAt) * speed.rawValue)
        position = next
        if next == range.upper { playing = false }
    }
}
