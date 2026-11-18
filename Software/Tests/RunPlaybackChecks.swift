import Foundation

@main enum RunPlaybackChecks {
    @MainActor static func main() throws {
        let replay = RunPlayback()
        let range = StreamSelection(lower: 5, upper: 15)
        replay.show(range)
        replay.play(at: 100)
        replay.advance(to: 102)
        try verify(replay.position == 7 && replay.playing, "Start at the visible range")
        replay.changeSpeed(to: .double, at: 102.5)
        try verify(replay.position == 7.5, "Changing speed preserves position")
        replay.advance(to: 104)
        try verify(replay.position == 10.5, "Advance at the selected speed")
        replay.seek(to: 8, at: 105)
        replay.advance(to: 106)
        try verify(replay.position == 10 && replay.playing, "Seek while playing")
        replay.pause(at: 106.5)
        replay.advance(to: 300)
        try verify(replay.position == 11 && !replay.playing, "Pause freezes the cursor")
        replay.play(at: 400)
        replay.advance(to: 402)
        try verify(replay.position == 15 && !replay.playing, "Clamp at the end of the visible range")
        replay.play(at: 500)
        try verify(replay.position == 5 && replay.playing, "Replay from the start after reaching the end")
        replay.show(range)
        try verify(replay.playing, "Reloading the same bounds preserves playback")
        replay.show(.init(lower: 5, upper: 7))
        try verify(!replay.playing && replay.position == 5, "Adjusting the view pauses at a visible position")
        replay.show(.init(lower: 90, upper: 100))
        try verify(replay.position == nil, "A different view clears an off-screen marker")
        replay.show(.init(lower: .nan, upper: 0))
        replay.play(at: 600)
        try verify(!replay.playing && replay.position == nil, "Invalid or missing data has no playback")

        // Use a saved recording with a gap. Advancing on its time axis does
        // not manufacture samples or skip the missing interval.
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let store = try StreamProjectStore.create(named: "Gapped Playback", in: folder)
        let reader = try CurveChecks.make(store, count: 8192, rate: 10_000, gapped: true, name: "Saved waveform")
        let duration = try reader.duration()
        let savedRange = StreamSelection(lower: 0, upper: duration)
        func waveformHashes() throws -> [String] {
            var hashes: [String] = []
            try reader.visit(savedRange) { hashes.append(StreamFiles.sha($0.originalPayload)) }
            return hashes
        }
        let hash = try waveformHashes()
        let plot = try StreamStudio.plot(reader, selection: savedRange)
        guard let gap = plot.gaps.first(where: { $0.upper > $0.lower }) else {
            throw StreamFailure.storage("The saved playback fixture needs a visible gap.")
        }
        replay.show(savedRange)
        replay.changeSpeed(to: .normal, at: 100)
        replay.play(at: 100)
        let gapCenter = (gap.lower + gap.upper) / 2
        replay.advance(to: 100 + gapCenter)
        try verify(replay.position.map { gap.lower < $0 && $0 < gap.upper } == true, "The cursor preserves time through gaps")
        replay.advance(to: 100 + duration + 1)
        let after = try waveformHashes()
        try verify(replay.position == duration && !replay.playing && hash == after, "Playback leaves the saved waveform unchanged")
        print("PASS playback seek, pause, speed, replay, range changes and recording gap with unchanged sample hashes")
    }

    private static func verify(_ valid: Bool, _ message: String) throws {
        guard valid else { throw StreamFailure.storage(message) }
    }
}
