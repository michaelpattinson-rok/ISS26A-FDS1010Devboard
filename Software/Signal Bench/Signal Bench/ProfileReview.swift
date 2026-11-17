import Foundation

nonisolated struct ProfileWindowMetric: Sendable {
    var id: String
    var sha: String
    var boot: String
    var elapsed: Double
    var coverage: ProfileCoverage
    var baseline: Double?
    var noise: Double?
    var drift: Double?
    var headroom: Double?
    var spectralPeakHz: Double?
    var issues: [String]

    init(_ window: ProfileWindowResult) {
        id = window.id
        sha = window.sampleHash
        boot = window.boot
        elapsed = window.elapsed
        coverage = ProfileCoverage()
        coverage.add(window)
        baseline = window.baseline
        noise = window.noise
        drift = window.drift
        headroom = window.headroom
        spectralPeakHz = window.spectralPeakHz
        issues = window.reasons
    }

    static func coverage(_ windows: [Self], elapsed: Double, uncertain: Bool = false, missing: Int = 0) -> ProfileCoverage {
        windows.reduce(into: ProfileCoverage(elapsed: elapsed, unknown: max(0, elapsed - windows.reduce(0) { $0 + $1.coverage.sampled }),
                                             uncertainInterruption: uncertain, missing: missing)) { result, item in
            result.sampled += item.coverage.sampled
            result.usable += item.coverage.usable
            result.windows += 1
            result.usableWindows += item.coverage.usableWindows
            result.matches += item.coverage.matches
            result.outside += item.coverage.outside
        }
    }

    static func blocks(_ windows: [Self]) -> [ProfileBlock] {
        Dictionary(grouping: windows, by: { "\($0.boot):\(Int($0.elapsed / 60))" }).values.compactMap { block in
            guard let first = block.first else { return nil }
            var value = ProfileBlock(boot: first.boot, minute: Int(first.elapsed / 60))
            value.coverage = coverage(block, elapsed: 60)
            value.medianBaseline = ProfileAnalyzer.median(block.compactMap(\.baseline))
            value.medianNoise = ProfileAnalyzer.median(block.compactMap(\.noise))
            value.maximumDrift = block.compactMap(\.drift).max()
            value.minimumHeadroom = block.compactMap(\.headroom).min()
            value.medianSpectralPeakHz = ProfileAnalyzer.median(block.compactMap(\.spectralPeakHz))
            value.burstWindows = block.count { $0.coverage.matches > 1 }
            return value
        }.sorted { ($0.minute, $0.boot) < ($1.minute, $1.boot) }
    }
}

nonisolated struct ProfileEvaluation: Sendable {
    var profile: CalibrationProfile
    var blocks: [CalibrationPhase: [ProfileBlock]]
}

nonisolated struct ProfileRunReview: Sendable {
    var coverage: ProfileCoverage
    var blocks: [ProfileBlock]
    var recordIDs: [String]
}

nonisolated struct ProfileAnalysisRevision: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var algorithmVersion = CalibrationProfile.algorithm
    var createdAt = Date()
    var rules: ProfilePulseRules
    var exclusions: [ProfileManualExclusion] = []
}

nonisolated struct CalibrationSetupDocument: Codable, Sendable {
    static let type = "com.issa26.signal-bench-calibration"
    static let byteLimit = 1_048_576
    var type = Self.type
    var version = 1
    var profile: CalibrationProfile

    func checked() throws -> Self {
        let fields = [profile.name, profile.setup.board, profile.setup.detector, profile.setup.cable,
                      profile.setup.enclosure, profile.setup.conditions] + profile.phases.flatMap(\.issues)
        guard type == Self.type, version == 1, profile.valid, profile.setup.notes.isEmpty,
              profile.locallyVerifiedElectrical == nil, profile.sourceDigest == nil,
              fields.allSatisfy({ text in
                  !["/Users/", "/Volumes/", "/private/", "file://", "~/", "\\"].contains { text.localizedCaseInsensitiveContains($0) }
              }) else { throw ProfileWorkflowError.invalidSetupFile }
        return self
    }
}

nonisolated enum ProfileWorkflowError: LocalizedError {
    case invalidSetupFile, staleProfile, unavailable, moreData, incompatibleSetup, powerCycle, invalidEvidence, validationNotLocked
    var errorDescription: String? {
        switch self {
        case .invalidSetupFile: "The calibration setup is invalid, too large or uses an unsupported version."
        case .staleProfile: "The calibration revision changed. Reopen it before making changes."
        case .unavailable: "Open a Project and connect the Pico W with firmware 1.5."
        case .moreData: "The selected phase needs more verified coverage."
        case .incompatibleSetup: "Confirm the same setup and J4 setting used by this profile."
        case .powerCycle: "Verify a new Pico boot before recording this phase."
        case .invalidEvidence: "The saved evidence is incomplete or cannot be matched to these raw windows."
        case .validationNotLocked: "Lock the rules and local acceptance limits before evaluating the holdout."
        }
    }
}

nonisolated struct ProfileSetupEvaluation: Sendable {
    var coverage: ProfileCoverage
    var issues: [String]
    var passed: Bool { issues.isEmpty }
}

nonisolated struct ProfileResultsOptions: Sendable {
    var cleaned = false
    var pulses = true
    var exclusions = true
    var coverage = true
    var quality = true
}

nonisolated struct FixtureReference: Codable, Sendable {
    struct Alignment: Codable, Sendable {
        var boot: String
        var scopeStartUS: Double
        var scopeEndUS: Double
        var picoStartUS: Double
        var picoEndUS: Double
        var uncertaintyUS: Double
        var independentAnchors: String

        var valid: Bool {
            boot.count == 16 && UInt64(boot, radix: 16) != nil
            && [scopeStartUS, scopeEndUS, picoStartUS, picoEndUS].allSatisfy { (0...1e15).contains($0) }
            && scopeEndUS > scopeStartUS && picoEndUS > picoStartUS && (0.95...1.05).contains(scale)
            && (0.01...1000).contains(uncertaintyUS)
            && !independentAnchors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && independentAnchors.utf8.count <= 1000
        }
        var scale: Double { (picoEndUS - picoStartUS) / (scopeEndUS - scopeStartUS) }
        func picoTime(_ scopeTime: Double) -> Double? {
            guard (scopeStartUS...scopeEndUS).contains(scopeTime) else { return nil }
            return picoStartUS + (scopeTime - scopeStartUS) * scale
        }
    }

    struct Pulse: Codable, Sendable {
        var boot: String
        var scopePeakUS: Double
        var heightCodes: Double
        var widthSamples: Int
        var expectedMatch: Bool
    }

    var version: Int
    var gain: String
    var polarity: ProfilePulseRules.Polarity
    var allowedMisses: Int
    var allowedFalseMatches: Int
    var alignments: [Alignment]
    var pulses: [Pulse]

    var valid: Bool {
        version == 1 && ["LOW", "HIGH"].contains(gain) && (0...10000).contains(allowedMisses)
        && (0...10000).contains(allowedFalseMatches) && (1...64).contains(alignments.count)
        && Set(alignments.map(\.boot)).count == alignments.count && alignments.allSatisfy(\.valid)
        && (2...10_000).contains(pulses.count) && pulses.contains(where: \.expectedMatch)
        && pulses.contains(where: { !$0.expectedMatch })
        && pulses.allSatisfy({ pulse in
            (0...1e15).contains(pulse.scopePeakUS) && (1...4095).contains(pulse.heightCodes)
                && (1...32768).contains(pulse.widthSamples) && alignments.contains { $0.boot == pulse.boot }
        })
    }
}
