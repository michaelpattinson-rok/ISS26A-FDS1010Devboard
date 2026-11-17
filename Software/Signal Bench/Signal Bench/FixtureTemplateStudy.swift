import Foundation

nonisolated struct FixtureStudySource: Codable, Equatable, Sendable {
    var run: UUID
    var streams: [UInt64]
    var chunks: [String: String]
    var timingSHA256: String?
    var timingSource: String?
    var clockAlignment: String?
    var anchorReferenceUS: Double?
    var anchorSampleIndex: UInt64?
    var referenceRateHz: Double?
    var uncertaintyUS: Double?
    var referencePulseCount: Int?
}

nonisolated struct FixtureTrainingPulse: Codable, Equatable, Sendable {
    var run: UUID
    var segment: UUID
    var referenceUS: Double
    var alignmentIndex: Double
    var first: UInt64
    var end: UInt64
    var height: Double
    var halfHeightWidth: Int
}

nonisolated struct FixtureStudyTemplate: Codable, Equatable, Identifiable, Sendable {
    static let version = 1
    var type = "signalbench.fixture-fit-template"
    var version = Self.version
    var id = UUID()
    var created = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    var name: String
    var project: UUID
    var boardRevision = "Rev E.1"
    var setup: CalibrationSetup
    var polarity: ProfilePulseRules.Polarity
    var sampleRate: Int
    var before: Int
    var peak: Int
    var shape: [Double]
    var training: [FixtureStudySource]
    var reservedValidationRuns: [UUID] = []
    var pulses: [FixtureTrainingPulse]
    var limits: FixtureFitLimits
    var baseline: ReviewSettings
    var noise: FixtureStudySource?
    var ar: Double?
    var weightedLimits: FixtureFitLimits?

    var valid: Bool {
        type == "signalbench.fixture-fit-template" && version == Self.version && boardRevision == "Rev E.1"
        && (try? SessionStore.projectName(name)) == name && setup.valid && sampleRate == setup.nominalHz
        && (16...1024).contains(shape.count) && (2..<(shape.count - 2)).contains(before)
        && shape.indices.contains(peak) && shape.allSatisfy { $0.isFinite && abs($0) <= 1.01 }
        && abs(shape[peak] * polarity.sign - 1) < 1e-8
        && (1...16).contains(training.count) && Set(training.map(\.run)).count == training.count
        && reservedValidationRuns.count <= 32 && Set(reservedValidationRuns).count == reservedValidationRuns.count
        && Set(reservedValidationRuns).isDisjoint(with: training.map(\.run) + [noise?.run].compactMap { $0 })
        && (3...2048).contains(pulses.count) && pulses.allSatisfy { pulse in
            training.contains { $0.run == pulse.run } && (0...3_600_000_000).contains(pulse.alignmentIndex)
            && pulse.referenceUS.isFinite && pulse.end > pulse.first && pulse.end - pulse.first <= 1025
            && (0.01...4095).contains(pulse.height) && (1...shape.count).contains(pulse.halfHeightWidth)
        }
        && (training + [noise].compactMap { $0 }).allSatisfy {
            !$0.streams.isEmpty && !$0.chunks.isEmpty && $0.chunks.values.allSatisfy(ProfileDigest.valid)
        }
        && training.allSatisfy { $0.timingSHA256.map(ProfileDigest.valid) == true }
        && baseline.valid && baseline.template == nil && !baseline.notch60 && !baseline.notch120
        && baseline.polarity == polarity && limits.valid
        && ((ar == nil && weightedLimits == nil && noise == nil) ||
            (ar.map { (-0.95...0.95).contains($0) } == true && weightedLimits?.valid == true
             && noise.map { source in !training.contains(where: { $0.run == source.run }) } == true))
    }

    func kernel(weighted: Bool) throws -> FixtureKernel {
        guard valid, !weighted || ar != nil else { throw StreamFailure.storage("The requested template or noise model is unavailable.") }
        return try FixtureKernel(shape: shape, before: before, peak: peak, ar: weighted ? ar : nil)
    }

    func compatible(_ reader: StreamRangeReader, operatorConfirmed: Bool = false) -> Bool {
        let run = reader.run
        let local = run.settings.bench?.setup ?? run.settings.profile?.setup ?? run.settings.calibrationSetup
        guard run.curveSource == nil, run.project == project, run.settings.channel == 0, run.settings.board == setup.acquisitionDevice, run.settings.nominalRate == sampleRate,
              run.settings.picoAveraging == setup.picoAveraging else { return false }
        if setup.requiresLocalFixture { return local.map { setup.matchesAcquisition($0) } == true && run.settings.gain == setup.gain }
        if let local {
            return run.settings.gain == setup.gain && local.board == setup.board && local.standardWiring
        }
        return operatorConfirmed && (run.settings.gain == setup.gain || run.settings.gain == "Unconfirmed")
    }
}

nonisolated enum FixtureTemplateStudy {
    static let folderName = "fixture-fit-templates"

    static func templates(_ store: StreamProjectStore) throws -> [FixtureStudyTemplate] {
        try store.verify()
        let folder = store.folder.appendingPathComponent(folderName)
        guard StreamFiles.exists(folder) else { return [] }
        try StreamFiles.directory(folder)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        guard files.count <= 512 else { throw StreamFailure.storage("Too many fixture template revisions.") }
        return try files.filter { $0.pathExtension == "json" }.map { url in
            let bytes = try StreamFiles.read(url, limit: 8_388_608)
            let item = try StreamFiles.decoder.decode(FixtureStudyTemplate.self, from: bytes)
            guard item.valid, item.project == store.identity.id, url.lastPathComponent == item.id.uuidString + ".json" else {
                throw StreamFailure.storage("A fixture template revision failed validation.")
            }
            return item
        }.sorted { $0.created > $1.created }
    }

    private static func source(_ reader: StreamRangeReader, chunks: [String: String], reference: StreamFixtureReference? = nil,
                               hash: String? = nil) -> FixtureStudySource {
        .init(run: reader.run.id, streams: reader.run.segments.map(\.stream), chunks: chunks,
              timingSHA256: hash, timingSource: reference?.source, clockAlignment: reference?.clockAlignment,
              anchorReferenceUS: reference?.anchorReferenceUS, anchorSampleIndex: reference?.anchorSampleIndex,
              referenceRateHz: reference?.sampleRateHz, uncertaintyUS: reference?.uncertaintyUS,
              referencePulseCount: reference?.pulsesUS.count)
    }

    static func fullRange(_ reader: StreamRangeReader) throws -> StreamSelection {
        let range = StreamSelection(lower: 0, upper: try reader.duration())
        guard reader.run.status != .recording, range.valid else { throw StreamFailure.storage("Choose a saved run with waveform coverage.") }
        return range
    }

    static func build(_ name: String, training: [StreamRangeReader], noise: StreamRangeReader?, before: Int, after: Int,
                      baseline: ReviewSettings, reserve validation: [UUID] = []) throws -> FixtureStudyTemplate {
        let name = try SessionStore.projectName(name)
        guard (1...16).contains(training.count), Set(training.map { $0.run.id }).count == training.count,
              (2...1021).contains(before), (3...1022).contains(after), (16...1024).contains(before + after),
              let first = training.first, let setup = first.run.settings.bench?.setup,
              baseline.valid, baseline.template == nil, !baseline.notch60, !baseline.notch120 else {
            throw StreamFailure.storage("Choose timed fixture training runs and a window of 16 to 1,024 samples.")
        }
        guard validation.count <= 32, Set(validation).count == validation.count,
              Set(validation).isDisjoint(with: training.map { $0.run.id } + [noise?.run.id].compactMap { $0 }) else {
            throw StreamFailure.storage("Use separate runs for training, noise fitting and held aside replay.")
        }
        // Reserve metadata only. The holdout samples and timing reference
        // have no path into the trained template or its thresholds.
        for id in validation {
            let run = try first.store.openRun(id)
            guard run.status != .recording, let context = run.settings.bench,
                  [.fixture, .empty, .repeatEmpty].contains(context.step), context.setup.board == setup.board,
                  run.settings.board == setup.acquisitionDevice, run.settings.gain == setup.gain, run.settings.nominalRate == setup.nominalHz,
                  run.settings.picoAveraging == setup.picoAveraging,
                  !setup.requiresLocalFixture || setup.matchesAcquisition(context.setup) else {
                throw StreamFailure.storage("Reserve saved fixture or empty-board runs with matching board, gain and sample rate.")
            }
        }
        let sign = baseline.polarity.sign
        var sources: [FixtureStudySource] = [], pulseRows: [FixtureTrainingPulse] = [], waves: [[Double]] = []
        var shapeSum = [Double](repeating: 0, count: before + after)
        let referenceCountLimit = 2048
        for original in training {
            let reader = try original.prepared()
            guard reader.store.identity.id == first.store.identity.id, reader.run.status == .complete,
                  reader.run.settings.bench?.step == .fixture, reader.run.settings.bench?.setup.board == setup.board,
                  reader.run.settings.board == setup.acquisitionDevice, reader.run.settings.gain == setup.gain, reader.run.settings.nominalRate == setup.nominalHz,
                  reader.run.settings.picoAveraging == setup.picoAveraging,
                  !setup.requiresLocalFixture || reader.run.settings.bench.map({ setup.matchesAcquisition($0.setup) }) == true else {
                throw StreamFailure.storage("Training needs completed fixture runs from the same board, gain and sample rate.")
            }
            let (reference, hash) = try FixtureEvidence.reference(reader)
            let anchors = reference.pulsesUS.map(reference.index)
            guard anchors.count <= referenceCountLimit, anchors.allSatisfy({ $0.isFinite }),
                  reader.run.segments.filter({ $0.stream == reference.stream }).count == 1 else {
                throw StreamFailure.storage("Use at most 2,048 timed events per training run.")
            }
            var cursor = 0, chunks: [String: String] = [:]
            let alignmentMargin = Int(ceil(reference.uncertaintySamples))
            try FixtureTiles.visit(reader, selection: fullRange(reader), halo: before + after + 2 + alignmentMargin, source: {
                chunks[$0.reference.chunk.uuidString] = $0.reference.sha256
            }) { span, owned in
                guard span.segment.stream == reference.stream else { return }
                while cursor < anchors.count && anchors[cursor] < Double(owned.upperBound) {
                    let i = cursor
                    cursor += 1
                    let anchor = anchors[i]
                    let start = floor(anchor) - Double(before)
                    let end = start + Double(shapeSum.count) + 1
                    let guardSamples = ceil(reference.uncertaintySamples)
                    guard anchor >= Double(owned.lowerBound), start - guardSamples >= Double(span.first),
                          end + guardSamples <= Double(span.end),
                          (i == 0 || anchors[i - 1] + Double(after) + 2 * guardSamples < anchor - Double(before)),
                          (i + 1 == anchors.count || anchor + Double(after) + 2 * guardSamples < anchors[i + 1] - Double(before))
                    else { continue }
                    let offset = Int(start) - Int(span.first), frac = anchor - floor(anchor)
                    let padding = Int(guardSamples)
                    guard span.words[(offset - padding)..<(offset + shapeSum.count + 1 + padding)].allSatisfy({ FixtureKernel.usable($0, board: span.segment.board) })
                    else { continue }
                    let raw = (0..<shapeSum.count).map { j in
                        let a = span.value(offset + j)
                        let b = span.value(offset + j + 1)
                        return a + (b - a) * frac
                    }
                    let trace = FixtureKernel.removeSidebandBaseline(raw)
                    guard let peak = trace.indices.max(by: { trace[$0] * sign < trace[$1] * sign }),
                          (2..<(trace.count - 2)).contains(peak), trace[peak] * sign > 0,
                          trace[peak] * sign > trace.map({ abs($0) }).max()! * 0.8 else { continue }
                    let height = trace[peak] * sign
                    guard height >= 0.01, height <= Double(span.segment.board.maxCode),
                          trace.first! * sign < height / 2, trace.last! * sign < height / 2 else { continue }
                    var left = peak, right = peak + 1
                    while left > 0 && trace[left - 1] * sign >= height / 2 { left -= 1 }
                    while right < trace.count && trace[right] * sign >= height / 2 { right += 1 }
                    guard waves.count < referenceCountLimit else {
                        throw StreamFailure.storage("Use at most 2,048 usable pulses across the training runs.")
                    }
                    let integerStart = offset + Int(frac.rounded())
                    waves.append((integerStart..<(integerStart + shapeSum.count)).map(span.value))
                    pulseRows.append(.init(run: reader.run.id, segment: span.segment.id, referenceUS: reference.pulsesUS[i],
                                           alignmentIndex: anchor, first: UInt64(start), end: UInt64(end),
                                           height: height, halfHeightWidth: right - left))
                    for j in shapeSum.indices { shapeSum[j] += trace[j] / height }
                }
            }
            guard pulseRows.contains(where: { $0.run == reader.run.id }) else {
                throw StreamFailure.storage("A training run has no isolated, clean pulse inside the declared timing and window.")
            }
            let streams = reader.run.segments.map(\.stream)
            guard sources.allSatisfy({ Set($0.streams).isDisjoint(with: streams) &&
                Set($0.chunks.values).isDisjoint(with: chunks.values) }) else {
                throw StreamFailure.storage("Training runs contain duplicate streams or raw chunks.")
            }
            sources.append(source(reader, chunks: chunks, reference: reference, hash: hash))
        }
        guard waves.count >= 3, let peak = shapeSum.indices.max(by: { shapeSum[$0] * sign < shapeSum[$1] * sign }),
              (2..<(shapeSum.count - 2)).contains(peak), shapeSum[peak] * sign > 0 else {
            throw StreamFailure.storage("At least three isolated, correctly aligned fixture pulses are required.")
        }
        let scale = shapeSum[peak] * sign
        let shape = shapeSum.map { $0 / scale }
        func thresholds(_ ar: Double?) throws -> FixtureFitLimits {
            let bank = try FixtureFitBank(FixtureKernel(shape: shape, before: before, peak: peak, ar: ar))
            let fits = waves.map { bank.fit($0, first: 0).estimate }
            func quantile(_ values: [Double], _ q: Double) -> Double {
                let sorted = values.sorted()
                return sorted[Int((Double(sorted.count - 1) * q).rounded())]
            }
            let scores = fits.map(\.score)
            let residuals = fits.map { $0.residual / max(0.01, $0.amplitude) }
            let scoreLow = quantile(scores, 0.1), scoreHigh = quantile(scores, 0.9)
            let residualLow = quantile(residuals, 0.1), residualHigh = quantile(residuals, 0.9)
            let settings = FixtureFitLimits(minimumAmplitude: quantile(fits.map(\.amplitude), 0.1),
                                            minimumScore: max(0, scoreLow - (scoreHigh - scoreLow)),
                                            maximumRelativeResidual: residualHigh + (residualHigh - residualLow))
            guard settings.valid else { throw StreamFailure.storage("Training pulses do not support a consistent signed shape.") }
            return settings
        }
        let measured = try noise.map { try fitNoise($0, first: first, setup: setup) }
        if let measured {
            guard sources.allSatisfy({ Set($0.streams).isDisjoint(with: measured.0.streams) &&
                Set($0.chunks.values).isDisjoint(with: measured.0.chunks.values) }) else {
                throw StreamFailure.storage("The noise fit overlaps the fixture training data.")
            }
        }
        var template = try FixtureStudyTemplate(name: name, project: first.store.identity.id, setup: setup, polarity: baseline.polarity,
                                                sampleRate: setup.nominalHz, before: before, peak: peak, shape: shape,
                                                training: sources, reservedValidationRuns: validation.sorted { $0.uuidString < $1.uuidString },
                                                pulses: pulseRows, limits: thresholds(nil), baseline: baseline)
        if let measured {
            template.noise = measured.0
            template.ar = measured.1
            template.weightedLimits = try thresholds(measured.1)
        }
        guard template.valid else { throw StreamFailure.storage("The fitted template or its evidence is incomplete.") }
        try first.store.verify()
        let folder = try StreamFiles.directory(folderName, in: first.store.folder, create: true)
        try Task.checkCancellation()
        let bytes = try StreamFiles.encoder.encode(template)
        guard bytes.count <= 8_388_608 else { throw StreamFailure.storage("The template evidence exceeds 8 MiB. Use shorter training runs.") }
        try StreamFiles.publish(bytes, at: folder.appendingPathComponent(template.id.uuidString + ".json"))
        return template
    }

    private static func fitNoise(_ original: StreamRangeReader, first: StreamRangeReader, setup: CalibrationSetup) throws -> (FixtureStudySource, Double) {
        let reader = try original.prepared()
        guard reader.run.project == first.run.project, reader.run.status == .complete,
              let bench = reader.run.settings.bench, bench.step == .empty || bench.step == .repeatEmpty,
              bench.setup.board == setup.board, reader.run.settings.gain == setup.gain,
              reader.run.settings.board == setup.acquisitionDevice, reader.run.settings.nominalRate == setup.nominalHz, reader.run.settings.picoAveraging == setup.picoAveraging,
              !setup.requiresLocalFixture || reader.run.settings.bench.map({ setup.matchesAcquisition($0.setup) }) == true else {
            throw StreamFailure.storage("Noise weighting needs a separate completed Empty Board run with matching setup.")
        }
        var variance = 0.0, lag = 0.0, pairs = 0, chunks: [String: String] = [:]
        try FixtureTiles.visit(reader, selection: fullRange(reader), halo: 0, source: {
            chunks[$0.reference.chunk.uuidString] = $0.reference.sha256
        }) { span, _ in
            for start in stride(from: 0, to: span.words.count, by: 1024) {
                let end = min(span.words.count, start + 1024)
                let block = span.words[start..<end]
                guard block.count >= 128, block.allSatisfy({ FixtureKernel.usable($0, board: span.segment.board) }) else { continue }
                let y = FixtureKernel.detrend((start..<end).map(span.value)).residual
                guard let mad = ProfileAnalyzer.median(y.map(abs)), mad > 0 else { continue }
                let limit = 6 * 1.4826 * mad
                for (a, b) in zip(y, y.dropFirst()) where abs(a) <= limit && abs(b) <= limit {
                    lag += a * b; variance += a * a; pairs += 1
                }
            }
        }
        guard pairs >= 1024, variance > 0, (-0.95...0.95).contains(lag / variance) else {
            throw StreamFailure.storage("The empty-board run does not support a stable first-order noise fit.")
        }
        return (source(reader, chunks: chunks), lag / variance)
    }

    static func inspect(_ reader: StreamRangeReader, selection: StreamSelection, template: FixtureStudyTemplate,
                        weighted: Bool, operatorConfirmed: Bool = false) throws -> FixtureFitPreview? {
        guard template.compatible(reader, operatorConfirmed: operatorConfirmed) else {
            throw StreamFailure.storage("Use a run with the template’s board label, ADC0, gain and sample rate.")
        }
        let kernel = try template.kernel(weighted: weighted)
        let bank = try FixtureFitBank(kernel)
        let limits = weighted ? template.weightedLimits! : template.limits
        let input = try ReviewInput.load(reader, selection: selection, context: 0.03)
        var best: FixtureFitPreview?
        var bestScreen = 0.01
        for span in input.spans {
            var available = span.words
            var cursor = 0, markedEnd = 0
            while cursor < span.words.count {
                guard !FixtureKernel.usable(span.words[cursor], board: span.segment.board) else { cursor += 1; continue }
                let start = cursor
                repeat { cursor += 1 } while cursor < span.words.count && !FixtureKernel.usable(span.words[cursor], board: span.segment.board)
                let end = min(span.words.count, cursor + template.baseline.padAfter)
                for i in max(markedEnd, start - template.baseline.padBefore)..<end { available[i] |= 0x8000 }
                markedEnd = end
            }
            let stats = kernel.screen(available, means: span.means, board: span.segment.board)
            let owned = ReviewInput.indices(selection, segment: span.segment, rate: template.sampleRate)
            for i in stats.scores.indices {
                if i.isMultiple(of: 4096) { try Task.checkCancellation() }
                guard owned.contains(span.first + UInt64(i + template.before)),
                      stats.amplitudes[i] > bestScreen else { continue }
                bestScreen = stats.amplitudes[i]
                let raw = (i..<(i + template.shape.count)).map(span.value)
                let (fit, matched) = bank.fit(raw, first: span.first + UInt64(i))
                best = .init(segment: span.segment.id, fit: fit, raw: raw, fitted: matched.waveform(fit), reason: limits.review(fit))
            }
        }
        return best
    }
}
