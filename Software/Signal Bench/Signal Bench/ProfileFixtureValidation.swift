import CryptoKit
import Foundation

/// Validates the calibrated detector itself against independent timing. The
/// template replay is a different detector and cannot qualify profile rules.
nonisolated enum ProfileFixtureValidation {
    struct Evidence: Codable, Sendable {
        var version = 1
        let profile: UUID
        let run: UUID
        let setup: CalibrationSetup
        let rules: ProfilePulseRules
        let limits: ProfileLimits
        let envelope: ProfileEnvelope
        let timingSHA256: String
        let annotation: UUID?
        let chunkSHA256: [String: String]
        let analyzer: Int
        let referenceCount: Int
        let check: ElectricalPulseCheck
    }

    static func validate(_ profile: CalibrationProfile, in store: StreamProjectStore, fixture: UUID) throws -> CalibrationProfile {
        guard profile.ready, profile.valid, profile.setup.requiresLocalFixture,
              try StreamingCalibration.profiles(store).contains(profile) else { throw ProfileWorkflowError.incompatibleSetup }
        let run = try store.openRun(fixture)
        guard let bench = run.settings.bench, bench.step == .fixture, run.status == .complete,
              run.segments.count == 1, !run.hasCadenceMismatch, run.settings.board == profile.setup.acquisitionDevice, profile.setup.matchesAcquisition(bench.setup),
              let segment = run.segments.first else { throw ProfileWorkflowError.incompatibleSetup }
        let lease = try ProjectReview.ReadLease(store.runDirectory(fixture))
        defer { withExtendedLifetime(lease) {} }
        let reader = try StreamRangeReader(store: store, run: run).prepared()
        let (reference, timingSHA) = try FixtureEvidence.reference(reader)
        guard reference.stream == segment.stream else { throw ProfileWorkflowError.invalidEvidence }
        let targets = reference.pulsesUS.map(reference.index)
        let uncertainty = reference.uncertaintySamples
        let annotations = try RunAnnotations.read(reader)
        let selection = try FixtureTemplateStudy.fullRange(reader)
        var usable: [Range<UInt64>] = []
        var candidates: [(index: UInt64, height: Double, width: Int)] = []
        try ContinuousPulseScan.scan(reader, selection: selection, profile: profile, rules: profile.rules,
                                     excluding: RunAnnotations.merged(annotations?.masks ?? [])) { window in
            for range in window.usableRanges {
                if let last = usable.last, last.upperBound == range.lowerBound {
                    usable[usable.count - 1] = last.lowerBound..<range.upperBound
                } else {
                    guard usable.count < 100_000 else { throw ReviewWorkerError.limit }
                    usable.append(range)
                }
            }
            guard window.result.complete, !window.result.outsideEnvelope else { return }
            for pulse in window.result.candidates where pulse.decision == "match" {
                guard candidates.count < 100_000 else { throw ReviewWorkerError.limit }
                candidates.append((window.contextFirst + UInt64(pulse.peak), pulse.height, pulse.end - pulse.start))
            }
        }
        var hits = Set<Int>()
        var misses = 0, gaps = 0, ambiguous = 0, span = 0, candidate = 0
        for (i, target) in targets.enumerated() {
            try Task.checkCancellation()
            let low = target - uncertainty, high = target + uncertainty
            if (i > 0 && targets[i - 1] + uncertainty >= low) ||
                (i + 1 < targets.count && targets[i + 1] - uncertainty <= high) {
                ambiguous += 1
                continue
            }
            while span < usable.count && Double(usable[span].upperBound) <= low { span += 1 }
            guard span < usable.count, Double(usable[span].lowerBound) <= low, Double(usable[span].upperBound) > high else {
                gaps += 1
                continue
            }
            while candidate < candidates.count && Double(candidates[candidate].index) < low { candidate += 1 }
            guard candidate < candidates.count, Double(candidates[candidate].index) <= high else { misses += 1; continue }
            if candidate + 1 < candidates.count, Double(candidates[candidate + 1].index) <= high {
                ambiguous += 1
            } else {
                hits.insert(candidate)
            }
        }
        // A fixed zero tolerance avoids publishing an undocumented release threshold.
        // Require three independently timed pulses and complete timing coverage.
        let observed = hits.map { candidates[$0] }
        let extra = candidates.count - hits.count
        guard hits.count >= 3, misses == 0, gaps == 0, ambiguous == 0, extra == 0,
              let minHeight = observed.map(\.height).min(), let maxHeight = observed.map(\.height).max(),
              let minWidth = observed.map(\.width).min(), let maxWidth = observed.map(\.width).max() else {
            throw StreamFailure.storage("Fixture check needs at least three unambiguous matches and no misses or extra matches. Matched \(hits.count), missed \(misses), outside coverage \(gaps), ambiguous \(ambiguous), extra \(extra).")
        }
        let chunks = Dictionary(uniqueKeysWithValues: (reader.index ?? []).map { ($0.id.uuidString, $0.sha256) })
        let check = ElectricalPulseCheck(evidenceSHA256: timingSHA, gain: profile.setup.gain, polarity: profile.rules.polarity,
            minimumHeight: minHeight, maximumHeight: maxHeight, minimumWidthSamples: minWidth, maximumWidthSamples: maxWidth,
            hits: hits.count, missed: misses, inGaps: gaps, uncertain: ambiguous, falseMatches: extra,
            allowedMisses: 0, allowedFalseMatches: 0, fixtureRun: fixture)
        let evidence = Evidence(profile: profile.id, run: fixture, setup: profile.setup, rules: profile.rules, limits: profile.limits,
                                envelope: profile.envelope, timingSHA256: timingSHA,
                                annotation: annotations?.id, chunkSHA256: chunks, analyzer: ContinuousPulseScan.algorithmVersion,
                                referenceCount: targets.count, check: check)
        guard try store.openRun(fixture) == run, try RunAnnotations.read(reader)?.id == annotations?.id,
              try FixtureEvidence.reference(reader).1 == timingSHA else { throw ReviewWorkerError.stale }
        var updated = profile
        updated.id = UUID()
        updated.revision += 1
        updated.locallyVerifiedElectrical = true
        updated.electrical = check
        let data = try StreamFiles.encoder.encode(evidence)
        updated.electrical?.evidenceSHA256 = StreamFiles.sha(data)
        try StreamingCalibration.saveFixtureRevision(updated, evidence: data, in: store)
        return updated
    }

    static func verify(_ profile: CalibrationProfile, in store: StreamProjectStore) throws {
        guard profile.setup.requiresLocalFixture else { return }
        guard profile.measurementReady, let check = profile.electrical, let fixture = check.fixtureRun else {
            throw ProfileWorkflowError.invalidEvidence
        }
        let data = try StreamingCalibration.fixtureEvidence(for: profile.id, in: store)
        guard StreamFiles.sha(data) == check.evidenceSHA256 else { throw ProfileWorkflowError.invalidEvidence }
        let evidence = try StreamFiles.decoder.decode(Evidence.self, from: data)
        guard evidence.version == 1, evidence.run == fixture, evidence.setup == profile.setup,
              evidence.analyzer == ContinuousPulseScan.algorithmVersion, evidence.rules == profile.rules,
              evidence.limits == profile.limits, evidence.envelope == profile.envelope, evidence.check.passed,
              evidence.check.polarity == profile.rules.polarity else { throw ProfileWorkflowError.invalidEvidence }
        let run = try store.openRun(fixture)
        guard run.settings.board == profile.setup.acquisitionDevice,
              let setup = run.settings.bench?.setup, profile.setup.matchesAcquisition(setup) else {
            throw ProfileWorkflowError.invalidEvidence
        }
        let reader = StreamRangeReader(store: store, run: run)
        let chunks = try store.chunkSummaries(run)
        guard try RunAnnotations.read(reader)?.id == evidence.annotation,
              try FixtureEvidence.reference(reader).1 == evidence.timingSHA256,
              Dictionary(uniqueKeysWithValues: chunks.map { ($0.id.uuidString, $0.sha256) }) == evidence.chunkSHA256 else {
            throw ReviewWorkerError.stale
        }
    }
}
