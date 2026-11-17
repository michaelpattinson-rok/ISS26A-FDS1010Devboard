import Foundation

nonisolated struct RunTimelineEntry: Codable, Equatable, Identifiable, Sendable {
    struct Position: Codable, Equatable, Sendable {
        let segment: UUID
        let index: UInt64
        let word: UInt16
        let exactSum: UInt64?
        let sourceFactor: Int?
        let sourceADCErrors: Int?
        let sourceLowRail: Int?
        let sourceHighRail: Int?
        let acquisitionBoard: AcquisitionBoard?

        var readingLabel: String {
            guard let n = sourceFactor, let sum = exactSum else {
                return word & 0x8000 != 0 ? "ADC error" : "\((acquisitionBoard ?? .picoW).sampleCode(word).formatted()) ADC codes"
            }
            let group = ADCAveraging.Group(first: index * UInt64(n), count: n, sum: sum,
                adcErrors: sourceADCErrors ?? 0, lowRail: sourceLowRail ?? 0, highRail: sourceHighRail ?? 0)
            return WaveformSample(segment: segment, index: index, time: 0, word: word, group: group).readingLabel
        }

        init?(_ sample: WaveformSample) {
            guard let segment = sample.segment else { return nil }
            self.segment = segment
            index = sample.index
            word = sample.word
            exactSum = sample.group?.sum
            sourceFactor = sample.group?.count
            sourceADCErrors = sample.group?.adcErrors
            sourceLowRail = sample.group?.lowRail
            sourceHighRail = sample.group?.highRail
            acquisitionBoard = sample.board == .unoR4 ? .unoR4 : nil
        }
    }

    enum State: String, Codable, Sendable { case note, pending, placed, unavailable }
    var version = 1
    var id = UUID()
    var revision = UUID()
    var created = Date()
    var click: Date?
    var label = ""
    var note = ""
    var position: Position?
    var state: State = .note
    var valid: Bool {
        version == 1 && label.utf8.count <= 120 && note.utf8.count <= 8192
        && !label.contains("\0") && !note.contains("\0")
        && (position.map {
            $0.index < StreamWire.maxSampleBoundary &&
                ($0.sourceFactor.map { ADCAveraging(rawValue: $0) != nil } ?? true)
        } ?? true)
        && (state == .note
            ? position == nil && !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : position != nil && !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

nonisolated enum RunTimeline {
    private static func folder(_ reader: StreamRangeReader, create: Bool) throws -> URL? {
        let root = try reader.store.runDirectory(reader.run.id)
        if !create {
            guard try StreamFiles.isPresent(root.appendingPathComponent("timeline")) else { return nil }
        }
        return try StreamFiles.directory("timeline", in: root, create: create)
    }

    static func entries(_ reader: StreamRangeReader, finished: Bool, resolving: Bool = true) throws -> [RunTimelineEntry] {
        guard let folder = try folder(reader, create: false) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil && $0.pathExtension == "json" }
        guard files.count <= 2_000 else { throw StreamFailure.storage("Too many flags and notes in this run.") }
        let entries = try files.map { file in
            let item = try StreamFiles.read(RunTimelineEntry.self, file)
            guard item.valid, file.lastPathComponent == item.id.uuidString + ".json" else {
                throw StreamFailure.storage("A flag or note file could not be read.")
            }
            return item
        }
        guard resolving, entries.contains(where: {
            guard $0.state == .pending, let position = $0.position else { return false }
            return finished || isCommitted(position, in: reader.run)
        }) else {
            return entries.sorted { ($0.created, $0.id.uuidString) < ($1.created, $1.id.uuidString) }
        }
        let prepared = try reader.prepared()
        return try entries.map { try resolved($0, reader: prepared, finished: finished) }
            .sorted { ($0.created, $0.id.uuidString) < ($1.created, $1.id.uuidString) }
    }

    static func time(of position: RunTimelineEntry.Position, in run: StreamRun) -> Double? {
        run.segments.first(where: { $0.id == position.segment }).map {
            $0.timelineStart + Double(position.index) / $0.configuredRate(run.settings.nominalRate)
        }
    }

    static func sample(at time: Double, in reader: StreamRangeReader) throws -> WaveformSample? {
        guard time.isFinite, time >= 0 else { return nil }
        let prepared = try reader.prepared()
        let step = 1 / reader.run.settings.recordedRate
        let range = StreamSelection(lower: max(0, time - 2 * step), upper: time + 2 * step)
        var nearest: WaveformSample?
        try prepared.visit(range) { part in
            let rate = part.configuredRate
            let position = (time - part.segment.timelineStart) * rate
            let floor = (position + 1e-6).rounded(.down)
            guard floor >= Double(part.reference.first),
                  floor < Double(part.reference.first) + Double(part.reference.count) else { return }
            let index = min(part.reference.first + UInt64(part.reference.count - 1), UInt64(position.rounded()))
            nearest = part.sample(at: Int(index - part.reference.first))
        }
        return nearest
    }

    private static func isCommitted(_ position: RunTimelineEntry.Position, in run: StreamRun) -> Bool {
        run.segments.contains { $0.id == position.segment && position.index < $0.accountedSamples }
    }

    private static func resolved(_ entry: RunTimelineEntry, reader: StreamRangeReader, finished: Bool) throws -> RunTimelineEntry {
        guard entry.state == .pending, let position = entry.position, finished || isCommitted(position, in: reader.run) else { return entry }
        var result = entry
        if let time = time(of: position, in: reader.run),
           let sample = try sample(at: time, in: reader), RunTimelineEntry.Position(sample) == position {
            result.state = .placed
        } else if finished {
            result.state = .unavailable
        }
        return result
    }

    static func save(_ entry: RunTimelineEntry, replacing: UUID?, in reader: StreamRangeReader,
                     finished: Bool, checkCommitted: Bool = true) throws -> RunTimelineEntry {
        guard entry.valid else { throw StreamFailure.storage("Enter a flag label or note within the displayed limits.") }
        try reader.store.verify()
        guard let folder = try folder(reader, create: true) else { throw StreamFailure.storage("The timeline folder is unavailable.") }
        let lock = try StreamRunLock(folder)
        defer { withExtendedLifetime(lock) {} }
        let url = folder.appendingPathComponent(entry.id.uuidString + ".json")
        let exists = try StreamFiles.isPresent(url)
        if exists {
            let prior = try StreamFiles.read(RunTimelineEntry.self, url)
            guard prior.revision == replacing else { throw StreamFailure.storage("This entry changed. Reopen it before saving.") }
        } else {
            guard replacing == nil, try entries(reader, finished: false, resolving: false).count < 2_000 else {
                throw StreamFailure.storage("The entry was removed or this run has reached its flag and note limit.")
            }
        }
        var result = checkCommitted ? try resolved(entry, reader: reader, finished: finished) : entry
        result.revision = UUID()
        try StreamFiles.publish(result, at: url, replace: exists)
        return result
    }

    static func remove(_ entry: RunTimelineEntry, from reader: StreamRangeReader) throws {
        try reader.store.verify()
        guard let folder = try folder(reader, create: false) else { throw StreamFailure.storage("The entry is unavailable.") }
        let lock = try StreamRunLock(folder)
        defer { withExtendedLifetime(lock) {} }
        let url = folder.appendingPathComponent(entry.id.uuidString + ".json")
        guard try StreamFiles.read(RunTimelineEntry.self, url).revision == entry.revision else {
            throw StreamFailure.storage("This entry changed. Reopen it before removing it.")
        }
        try FileManager.default.removeItem(at: url)
        try StreamFiles.sync(folder)
    }
}


nonisolated struct RunTimelineRequest: Identifiable, Sendable {
    enum Tool: Sendable { case flag, note, review }
    var id = UUID()
    let runID: UUID
    let tool: Tool
    let frozen: FrozenFlagWaveform?
}

nonisolated struct RunTimelineContent: Sendable {
    let reader: StreamRangeReader
    let entries: [RunTimelineEntry]
    let duration: Double
    let overview: WaveformOverview?
}
