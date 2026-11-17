import Foundation

nonisolated enum BenchStep: String, CaseIterable, Codable, Identifiable, Sendable {
    case empty = "Empty Board", dark = "Dark Detector", repeatEmpty = "Repeat Empty Board", fixture = "Electrical Fixture"
    var id: Self { self }
    var helpAssets: [String] {
        switch self {
        case .fixture: ["ReviewFixture", "SetupDetectorBoard"]
        case .dark: ["SetupDetectorBoard", "SetupGainLow", "SetupGainHigh"]
        case .empty, .repeatEmpty: ["SetupWiringBoard", "SetupPicoPhoto", "SetupGainLow", "SetupGainHigh"]
        }
    }
    var instructions: String {
        switch self {
        case .empty: "Leave J1 empty. Connect the standard J2 harness and confirm the J4 position."
        case .dark: "With USB unplugged, connect the FDS1010 at J1.1 VMID and J1.2 SUM. Cover the detector completely and wait for the baseline to settle."
        case .repeatEmpty: "Power down, remove the detector and restart the Pico with J1 empty. Keep the J2 harness and J4 position unchanged."
        case .fixture: "Power down and remove the detector. Use the documented charge fixture and an independent timing reference. Signal Bench does not drive GP15."
        }
    }
}

nonisolated struct BenchSequence: Codable, Identifiable, Sendable {
    var version = 1
    var id = UUID()
    var project: UUID
    var name: String
    var setup: CalibrationSetup
    var created = Date()
    var valid: Bool {
        version == 1 && (try? SessionStore.projectName(name)) == name && setup.valid
    }
}

nonisolated struct BenchRunContext: Codable, Equatable, Sendable {
    var sequence: UUID
    var step: BenchStep
    var setup: CalibrationSetup
}

nonisolated struct BenchMoment: Codable, Sendable, Identifiable {
    var version = 1
    var id = UUID()
    var segment: UUID
    var stream: UInt64
    var receivedBoundary: UInt64
    var lastFrameDeviceUS: UInt64
    var hostTime: Date
    var note: String
}

nonisolated struct BenchMinute: Codable, Identifiable, Sendable {
    var index: Int
    var elapsed: Double
    var sampled: Double
    var validADC: Double
    var baseline: Double?
    var noise: Double?
    var drift: Double?
    var clipped: UInt64
    var adcErrors: UInt64
    var matches: Int?
    var profileUsable: Double?
    var excluded: Double? = nil
    var id: Int { index }
}

nonisolated struct BenchSummary: Codable, Identifiable, Sendable {
    var run: UUID
    var step: BenchStep
    var name: String
    var boots: [UInt64]
    var unknownInterval: Bool
    var minutes: [BenchMinute]
    var profileRevision: UUID?
    var id: UUID { run }
    var sampled: Double { minutes.reduce(0) { $0 + $1.sampled } }
    var usable: Double { minutes.reduce(0) { $0 + ($1.profileUsable ?? $1.validADC) } }
    var totalMatches: Int? { profileRevision == nil ? nil : minutes.compactMap(\.matches).reduce(0, +) }
    var falsePerMinute: Double? {
        guard step == .empty || step == .repeatEmpty, let totalMatches, usable > 0 else { return nil }
        return Double(totalMatches) / (usable / 60)
    }
}

nonisolated enum BenchStudy {
    static func save(_ sequence: BenchSequence, in project: StreamProjectStore) throws {
        try project.verify()
        guard sequence.project == project.identity.id, sequence.valid else { throw ProfileWorkflowError.incompatibleSetup }
        let folder = try StreamFiles.directory("bench", in: project.folder, create: true)
        try StreamFiles.publish(sequence, at: folder.appendingPathComponent(sequence.id.uuidString + ".json"))
    }

    static func sequences(_ project: StreamProjectStore) throws -> [BenchSequence] {
        let folder = project.folder.appendingPathComponent("bench")
        guard StreamFiles.exists(folder) else { return [] }
        try StreamFiles.directory(folder)
        let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        guard entries.count <= 1000 else { throw StreamFailure.storage("Too many saved bench sequences.") }
        return try entries.filter { $0.pathExtension == "json" }.map { file in
            let value = try StreamFiles.read(BenchSequence.self, file)
            guard value.valid, value.project == project.identity.id, value.id.uuidString + ".json" == file.lastPathComponent else {
                throw StreamFailure.storage("A saved bench sequence is invalid.")
            }
            return value
        }.sorted { $0.created > $1.created }
    }

    static func runs(_ sequence: BenchSequence, items: [StreamRunItem]) -> [StreamRun] {
        items.compactMap(\.run).filter { $0.curveSource == nil && $0.settings.bench?.sequence == sequence.id }
    }

    static func moments(_ reader: StreamRangeReader) throws -> [BenchMoment] {
        let folder = try reader.store.runDirectory(reader.run.id).appendingPathComponent("moments")
        guard StreamFiles.exists(folder) else { return [] }
        try StreamFiles.directory(folder)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        guard files.count <= 2000 else { throw StreamFailure.storage("Too many moment marks.") }
        return try files.filter { $0.pathExtension == "json" }.map {
            let item = try StreamFiles.read(BenchMoment.self, $0)
            guard item.version == 1, item.id.uuidString + ".json" == $0.lastPathComponent, item.note.utf8.count <= 512,
                  reader.run.segments.contains(where: { $0.id == item.segment && $0.stream == item.stream }) else {
                throw StreamFailure.storage("A moment mark could not be verified.")
            }
            return item
        }.sorted { $0.hostTime < $1.hostTime }
    }

    static func summary(_ reader: StreamRangeReader, profile: CalibrationProfile?) throws -> BenchSummary {
        guard let context = reader.run.settings.bench else { throw StreamFailure.storage("Choose a recording linked to a bench sequence.") }
        if let profile {
            guard profile.valid, profile.ready, profile.setup.matchesAcquisition(context.setup) else { throw ProfileWorkflowError.incompatibleSetup }
        }
        let minutes = try minuteDetails(reader, profile: profile)
        return .init(run: reader.run.id, step: context.step, name: reader.run.name,
                     boots: Array(Set(reader.run.segments.compactMap(\.boot))).sorted(),
                     unknownInterval: reader.run.hasUnknownCoverage,
                     minutes: minutes, profileRevision: profile?.id)
    }

    static func minuteDetails(_ reader: StreamRangeReader, profile: CalibrationProfile?) throws -> [BenchMinute] {
        let reader = try reader.prepared()
        let masks = RunAnnotations.merged(try RunAnnotations.read(reader)?.masks ?? [])
        let duration = try reader.duration()
        let rate = reader.run.settings.recordedRate
        var minutes: [BenchMinute] = []
        for index in 0..<Int(ceil(duration / 60)) {
            try Task.checkCancellation()
            let start = Double(index) * 60
            let end = min(duration, start + 60)
            var histogram = Array(repeating: UInt64(0), count: Int(reader.run.settings.board.maxCode) + 1)
            var block: [Double] = [], centers: [Double] = []
            var sampled: UInt64 = 0, good: UInt64 = 0, clipped: UInt64 = 0, errors: UInt64 = 0
            var previous: (UUID, UInt64)?
            var excluded: UInt64 = 0
            func endBlock() {
                if block.count >= 64, let center = ProfileAnalyzer.median(block) { centers.append(center) }
                block.removeAll(keepingCapacity: true)
            }
            try reader.visit(.init(lower: start, upper: end)) { part in
                if let previous, previous.0 != part.segment.id || previous.1 != part.reference.first { endBlock() }
                previous = (part.segment.id, part.reference.first + UInt64(part.reference.count))
                sampled += UInt64(part.reference.count)
                let first = part.reference.first
                let pieces = RunAnnotations.retained(first..<(first + UInt64(part.reference.count)), excluding: masks[part.segment.id] ?? [])
                excluded += UInt64(part.reference.count - pieces.reduce(0) { $0 + $1.count })
                part.words.withUnsafeBytes { bytes in
                    // Report hardware flags even when that range is excluded.
                    for i in 0..<part.reference.count {
                        let word = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
                        if let group = part.groups?[i] {
                            if group.adcErrors > 0 { errors += 1 }
                            if group.lowRail + group.highRail > 0 { clipped += 1 }
                        } else if word & 0x8000 != 0 { errors += 1 }
                        else if part.segment.board.sampleCode(word) == 0 || part.segment.board.sampleCode(word) == part.segment.board.maxCode { clipped += 1 }
                    }
                    for piece in pieces {
                        for sample in piece {
                            let i = Int(sample - first)
                            let word = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
                            let code = Int(part.segment.board.sampleCode(word))
                            if word & 0x8000 != 0 || code == 0 || code == Int(part.segment.board.maxCode) { continue }
                            histogram[code] += 1
                            good += 1
                            if sample.isMultiple(of: 32) { block.append(part.groups?[i].mean ?? Double(code)) }
                            if block.count >= max(64, StreamWire.samples(1562, at: part.configuredRate)) { endBlock() }
                        }
                    }
                }
            }
            endBlock()
            let median = histogramMedian(histogram, count: good)
            var noise: Double?
            if let median {
                var deviations = Array(repeating: UInt64(0), count: 2 * histogram.count - 1)
                for (code, n) in histogram.enumerated() where n > 0 { deviations[Int(abs(Double(code) - median) * 2)] += n }
                noise = histogramMedian(deviations, count: good).map { $0 * 0.7413 }
            }
            let drift = centers.min().flatMap { low in centers.max().map { $0 - low } }
            minutes.append(.init(index: index + 1, elapsed: end - start, sampled: Double(sampled) / rate,
                                 validADC: Double(good) / rate, baseline: median, noise: noise, drift: drift,
                                 clipped: clipped, adcErrors: errors, matches: profile == nil ? nil : 0,
                                 profileUsable: profile == nil ? nil : 0, excluded: Double(excluded) / rate))
        }
        if let profile, duration > 0 {
            let segments = Dictionary(uniqueKeysWithValues: reader.run.segments.map { ($0.id, $0.timelineStart) })
            try ContinuousPulseScan.scan(reader, selection: .init(lower: 0, upper: duration), profile: profile,
                                         rules: profile.rules, excluding: masks) { block in
                guard block.result.complete, !block.result.outsideEnvelope, let start = segments[block.segment] else { return }
                for candidate in block.result.candidates where candidate.decision == "match" {
                    let time = start + Double(block.contextFirst + UInt64(candidate.start)) / rate
                    let index = Int(time / 60)
                    if minutes.indices.contains(index) { minutes[index].matches? += 1 }
                }
                for range in block.usableRanges {
                    let first = start + Double(range.lowerBound) / rate
                    let end = start + Double(range.upperBound) / rate
                    let lo = Int(first / 60)
                    let hi = min(minutes.count - 1, Int(end / 60))
                    if lo > hi { continue }
                    for index in lo...hi {
                        minutes[index].profileUsable? += max(0, min(end, Double(index + 1) * 60) - max(first, Double(index) * 60))
                    }
                }
            }
        }
        return minutes
    }

    private static func histogramMedian(_ bins: [UInt64], count: UInt64) -> Double? {
        guard count > 0 else { return nil }
        var cumulative: UInt64 = 0
        var lower: Int?
        for (i, value) in bins.enumerated() {
            cumulative += value
            if lower == nil, cumulative > (count - 1) / 2 { lower = i }
            if cumulative > count / 2 { return Double(i + (lower ?? i)) / 2 }
        }
        return nil
    }
}
