import Foundation

nonisolated enum CalibrationPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case quick = "Quick", standard = "Standard", deep = "Deep"
    var id: String { rawValue }
    var seconds: Int { switch self { case .quick: 180; case .standard: 600; case .deep: 1800 } }
    var phases: [CalibrationPhase] { self == .deep ? [.empty, .dark, .repeatEmpty] : [.empty, .dark] }
}

nonisolated enum CalibrationPhase: String, Codable, CaseIterable, Identifiable, Sendable {
    case empty, dark, repeatEmpty
    var id: String { rawValue }
    var title: String {
        switch self { case .empty: "Electronics Only"; case .dark: "Dark Detector"; case .repeatEmpty: "Repeat Electronics Only" }
    }
    var instructions: String {
        switch self {
        case .empty: "Leave J1 empty. Keep the board powered at 3.3 V through J2. Disconnect optional J3 probes."
        case .dark: "Remove USB and any external power. Connect the red anode to J1.1 VMID and the cathode to J1.2 SUM. Cover the detector, restore power and let the signal settle."
        case .repeatEmpty: "Remove USB and any external power, then remove the detector from J1. Restore power and verify a new device boot before recording the empty board again."
        }
    }
}

nonisolated struct CalibrationSetup: Codable, Equatable, Sendable {
    var board = ""
    var detector = ""
    var gain = "LOW"
    var cable = ""
    var enclosure = ""
    var conditions = ""
    var notes = ""
    var firmware = "Pico W · firmware 1.5"
    var nominalHz = 100_000
    var picoAveraging: ADCAveraging? = nil
    var acquisitionBoard: AcquisitionBoard? = nil
    var acquisitionDevice: AcquisitionBoard { acquisitionBoard ?? .picoW }
    var adcMax: Double { Double(acquisitionDevice.maxCode) }
    var requiresLocalFixture: Bool { picoAveraging != nil || acquisitionDevice == .unoR4 }
    var recordedHz: Double { acquisitionDevice.rate(nominalHz) / Double(picoAveraging?.count ?? 1) }
    var channel = "ADC0"
    var standardWiring = true

    static let multiRateVersions = ["1.8", "1.8.1", "1.8.2", "1.8.3"]
    static let streamingVersions = ["1.6", "1.6.1", "1.7"] + multiRateVersions + ["1.9", "1.10", "1.11"]
    static func firmwareLabel(_ version: String, board: AcquisitionBoard = .picoW) -> String { board.title + " · firmware " + version }
    func matchesFirmware(_ observed: String, board: AcquisitionBoard) -> Bool { acquisitionDevice == board && firmware == Self.firmwareLabel(observed, board: board) }
    func matchesFirmware(_ observed: String) -> Bool { matchesFirmware(observed, board: acquisitionDevice) }

    var valid: Bool {
        [board, detector, cable, enclosure, conditions].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 250
        } && notes.utf8.count <= 2048 && ["LOW", "HIGH"].contains(gain)
        && (picoAveraging == nil || (acquisitionDevice == .unoR4 ? (["1.1", "1.2", "1.3"].contains(where: matchesFirmware)) : matchesFirmware("1.10") || matchesFirmware("1.11")))
        && (acquisitionDevice == .unoR4 ? (matchesFirmware("1.0") && picoAveraging == nil && [100_000, 250_000, 500_000].contains(nominalHz)) || ((["1.1", "1.2", "1.3"].contains(where: matchesFirmware)) && acquisitionDevice.liveRange.contains(nominalHz)) :
            (["1.5"] + Self.streamingVersions).map { Self.firmwareLabel($0) }.contains(firmware) && (nominalHz == StreamWire.rate || ((matchesFirmware("1.9") || matchesFirmware("1.10") || matchesFirmware("1.11")) && StreamWire.customRates.contains(nominalHz)) || (Self.multiRateVersions.contains(where: matchesFirmware) && [250_000, 500_000].contains(nominalHz)))) && channel == "ADC0" && standardWiring
    }

    func matchesAcquisition(_ other: Self) -> Bool {
        board == other.board && detector == other.detector && gain == other.gain &&
            cable == other.cable && enclosure == other.enclosure && firmware == other.firmware &&
            nominalHz == other.nominalHz && channel == other.channel && standardWiring && other.standardWiring &&
            picoAveraging == other.picoAveraging && acquisitionDevice == other.acquisitionDevice
    }

    // The descriptions travel with the portable setup. Device and boot
    // identifiers belong to local runs and are deliberately absent here.
}

nonisolated struct ProfilePulseRules: Codable, Equatable, Sendable {
    enum Polarity: String, Codable, CaseIterable, Identifiable, Sendable {
        case negative = "Negative", positive = "Positive"
        var id: String { rawValue }
        var sign: Double { self == .positive ? 1 : -1 }
    }
    enum Threshold: String, Codable, CaseIterable, Identifiable, Sendable {
        case adaptive = "Adaptive", fixed = "Fixed"
        var id: String { rawValue }
    }
    enum ArtifactMode: String, Codable, CaseIterable, Identifiable, Sendable {
        case review = "Review Only", standard = "Standard", strict = "Strict", custom = "Custom"
        var id: String { rawValue }
    }

    var polarity = Polarity.negative
    var threshold = Threshold.adaptive
    var height = 24.0
    var sigmaMultiplier = 6.0
    var minimumSamples = 4
    var maximumSamples = 500
    var separationSamples = 100
    var artifactMode = ArtifactMode.review
    var reviewHeight = 1000.0
    var spikeMaximumSamples = 2
    var spikeMinimumSlope = 300.0
    var noisyBlockSigma = 80.0
    var paddingBefore = 10
    var paddingAfter = 20
    var approvedArtifactLimits = false

    mutating func rescaleTiming(from: Int, to: Int) {
        rescaleTiming(from: Double(from), to: Double(to))
    }

    mutating func rescaleTiming(from: Double, to: Double) {
        guard (156...500_000).contains(from), (156...500_000).contains(to), from != to else { return }
        func scale(_ samples: Int, limit: Int) -> Int { min(limit, Int((Double(samples) * to / from).rounded())) }
        minimumSamples = max(1, scale(minimumSamples, limit: 16_384))
        maximumSamples = max(minimumSamples, scale(maximumSamples, limit: 16_384))
        separationSamples = scale(separationSamples, limit: 16_384)
        spikeMaximumSamples = max(1, scale(spikeMaximumSamples, limit: 160))
        spikeMinimumSlope = max(1, min(4095, spikeMinimumSlope * Double(from) / Double(to)))
        paddingBefore = scale(paddingBefore, limit: 10_240)
        paddingAfter = scale(paddingAfter, limit: 10_240)
    }

    var valid: Bool {
        (1...4095).contains(height) && (1...50).contains(sigmaMultiplier)
        && (1...16_384).contains(minimumSamples) && (minimumSamples...16_384).contains(maximumSamples)
        && (0...16_384).contains(separationSamples) && (1...4095).contains(reviewHeight)
        && (1...160).contains(spikeMaximumSamples) && (1...4095).contains(spikeMinimumSlope)
        && (1...4095).contains(noisyBlockSigma) && (0...10_240).contains(paddingBefore)
        && (0...10_240).contains(paddingAfter) && (artifactMode == .review || approvedArtifactLimits)
    }
}

nonisolated struct ProfileLimits: Codable, Equatable, Sendable {
    // Zero values deliberately require explicit local choices before locking.
    var minimumFitWindows = 0
    var minimumHoldoutWindows = 0
    var minimumUsableSecondsPerMinute = 0.0
    var maximumNoise = 0.0
    var maximumDrift = 0.0
    var minimumHeadroom = 0.0
    var baselineTolerance = 0.0
    var maximumEmptyMatchesPerBlock = 0
    var operatorApproved = false

    var valid: Bool {
        operatorApproved && (1...10_000).contains(minimumFitWindows) && (1...10_000).contains(minimumHoldoutWindows)
        && (0.001...60).contains(minimumUsableSecondsPerMinute) && (0.01...2048).contains(maximumNoise)
        && (0.01...4095).contains(maximumDrift) && (1...2047).contains(minimumHeadroom)
        && (1...4095).contains(baselineTolerance) && (0...10_000).contains(maximumEmptyMatchesPerBlock)
    }
}

nonisolated struct ProfileEnvelope: Codable, Equatable, Sendable {
    var baselineLow: Double
    var baselineHigh: Double
    var valid: Bool { (0...16383).contains(baselineLow) && (baselineLow...16383).contains(baselineHigh) }
}

nonisolated struct ProfileCoverage: Codable, Equatable, Sendable {
    var elapsed = 0.0
    var sampled = 0.0
    var usable = 0.0
    var unknown = 0.0
    var uncertainInterruption = false
    var windows = 0
    var usableWindows = 0
    var matches = 0
    var outside = 0
    var missing = 0

    var valid: Bool {
        [elapsed, sampled, usable, unknown].allSatisfy { $0.isFinite && $0 >= 0 }
        && sampled <= elapsed + 0.34 && unknown <= elapsed + 0.000_001
        && usable <= sampled + 0.000_001 && usableWindows >= 0 && usableWindows <= windows
        && (0...100_000).contains(windows) && (0...100_000).contains(missing)
        && matches >= 0 && outside >= 0 && outside <= windows
    }

    mutating func add(_ result: ProfileWindowResult) {
        windows += 1
        sampled += result.sampledSeconds
        usable += result.usableSeconds
        if result.usableSeconds > 0 { usableWindows += 1 }
        if result.outsideEnvelope { outside += 1 }
        if result.complete { matches += result.matchCount }
    }
}

nonisolated struct ProfilePhaseSummary: Codable, Equatable, Sendable {
    var phase: CalibrationPhase
    var fit: ProfileCoverage
    var holdout: ProfileCoverage
    var fitBaselineMedian: Double?
    var fitNoiseMedian: Double?
    var holdoutBaselineMedian: Double?
    var holdoutNoiseMedian: Double?
    var evidenceSHA256: String
    var issues: [String]
}

nonisolated struct ElectricalPulseCheck: Codable, Equatable, Sendable {
    var evidenceSHA256: String
    var gain: String
    var polarity: ProfilePulseRules.Polarity
    var minimumHeight: Double
    var maximumHeight: Double
    var minimumWidthSamples: Int
    var maximumWidthSamples: Int
    var hits: Int
    var missed: Int
    var inGaps: Int
    var uncertain: Int
    var falseMatches: Int
    var allowedMisses: Int
    var allowedFalseMatches: Int
    var fixtureRun: UUID? = nil
    var passed: Bool { hits > 0 && missed <= allowedMisses && falseMatches <= allowedFalseMatches }
}

nonisolated struct CalibrationProfile: Codable, Equatable, Identifiable, Sendable {
    static let algorithm = 1
    var schema = 1
    var algorithmVersion = Self.algorithm
    var profileID = UUID()
    var id = UUID()
    var revision = 1
    var name: String
    var preset: CalibrationPreset
    var setup: CalibrationSetup
    var rules: ProfilePulseRules
    var limits: ProfileLimits
    var envelope: ProfileEnvelope
    var phases: [ProfilePhaseSummary]
    var electrical: ElectricalPulseCheck? = nil
    var origin = "local"
    var locallyVerifiedElectrical: Bool? = nil
    var sourceDigest: String? = nil

    var measurementReady: Bool {
        ready && (!setup.requiresLocalFixture || (locallyVerifiedElectrical == true && electrical?.passed == true && electrical?.fixtureRun != nil))
    }

    var ready: Bool {
        let required = Set(preset.phases)
        let recorded = Set(phases.map(\.phase))
        return required.isSubset(of: recorded) && phases.allSatisfy {
            $0.issues.isEmpty && $0.fit.usableWindows >= limits.minimumFitWindows
            && $0.holdout.usableWindows >= limits.minimumHoldoutWindows
            && $0.fit.elapsed >= Double(preset.seconds * 2 / 3)
            && $0.holdout.elapsed >= Double(preset.seconds / 3)
            && $0.fit.usable > 0 && $0.holdout.usable > 0
        }
    }

    var valid: Bool {
        guard schema == 1, algorithmVersion == Self.algorithm, (1...1_000_000).contains(revision),
              (try? SessionStore.projectName(name)) == name, setup.valid, rules.valid, limits.valid, envelope.valid, envelope.baselineHigh <= setup.adcMax,
              (1...3).contains(phases.count), Set(phases.map(\.phase)).count == phases.count,
              ["local", "imported"].contains(origin), sourceDigest.map(ProfileDigest.valid) ?? true,
              phases.allSatisfy({ phase in
                  let stats = [phase.fitBaselineMedian, phase.fitNoiseMedian, phase.holdoutBaselineMedian, phase.holdoutNoiseMedian]
                  return phase.fit.valid && phase.holdout.valid && ProfileDigest.valid(phase.evidenceSHA256)
                    && stats.compactMap { $0 }.allSatisfy { (0...setup.adcMax).contains($0) }
                    && phase.issues.count <= 32 && phase.issues.allSatisfy { $0.utf8.count <= 500 }
              }) else { return false }
        guard let check = electrical else { return true }
        return ProfileDigest.valid(check.evidenceSHA256) && check.gain == setup.gain && check.polarity == rules.polarity
            && (1...setup.adcMax).contains(check.minimumHeight) && (check.minimumHeight...setup.adcMax).contains(check.maximumHeight)
            && (1...32768).contains(check.minimumWidthSamples)
            && (check.minimumWidthSamples...32768).contains(check.maximumWidthSamples)
            && [check.hits, check.missed, check.inGaps, check.uncertain, check.falseMatches, check.allowedMisses, check.allowedFalseMatches]
                .allSatisfy { (0...100_000).contains($0) }
    }
}

nonisolated struct CalibrationAttempt: Codable, Equatable, Identifiable, Sendable {
    var schema = 1
    var id = UUID()
    var profileID = UUID()
    var revision = 1
    var name: String
    var preset = CalibrationPreset.standard
    var setup = CalibrationSetup()
    var rules = ProfilePulseRules()
    var limits = ProfileLimits()
    var extraRepeat = false
    var locked = false
    var resultID: UUID? = nil
    var predecessor: UUID? = nil
    var phases: [CalibrationPhase] {
        preset == .deep || extraRepeat ? [.empty, .dark, .repeatEmpty] : preset.phases
    }

    var valid: Bool {
        schema == 1 && (1...1_000_000).contains(revision) && (try? SessionStore.projectName(name)) == name
        && setup.valid && rules.valid && (!locked || limits.valid)
    }
}

nonisolated struct ProfileAcquisition: Codable, Equatable, Sendable {
    enum Purpose: String, Codable, Sendable { case calibrationPhase, setupCheck, fixture, profileRun }
    var purpose: Purpose
    var owner: UUID
    var name: String
    var notes = ""
    var phase: CalibrationPhase?
    var group: UUID? = nil
    var offsetSeconds = 0.0
    var setup: CalibrationSetup
    var snapshot: CalibrationProfile?
    var segment = UUID()
    var boot: String

    var valid: Bool {
        guard (try? SessionStore.projectName(name)) == name, notes.utf8.count <= 2048, (0...86_400).contains(offsetSeconds),
              setup.valid, boot.count == 16, UInt64(boot, radix: 16) != nil else { return false }
        if purpose == .calibrationPhase { return phase != nil && snapshot == nil }
        if purpose == .fixture { return phase == nil && snapshot?.setup == setup && snapshot?.id == owner && snapshot?.valid == true }
        return phase == nil && snapshot?.setup == setup && snapshot?.id == owner && snapshot?.valid == true && snapshot?.ready == true
    }
}

nonisolated struct ProfileRunSegment: Codable, Equatable, Sendable {
    var id: UUID
    var boot: String
    var elapsedAtStart: Double
    var unmeasuredGapBefore: Bool
}

nonisolated struct ProfileCaptureStamp: Codable, Equatable, Sendable {
    var purpose: ProfileAcquisition.Purpose
    var owner: UUID
    var segment: UUID
    var elapsedSeconds: Double
    var valid: Bool { (0...90_000).contains(elapsedSeconds) }
}

nonisolated enum ProfileDigest {
    static func valid(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
