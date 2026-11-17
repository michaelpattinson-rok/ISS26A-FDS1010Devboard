import Foundation

/// Run progress is an additive session document. Individual ACK receipts remain
/// independent so a long recording never grows one unbounded manifest.
nonisolated struct RunArchive: Codable, Identifiable, Sendable {
    var schema = 1
    var id = UUID()
    var sessionID: UUID
    var tag: String
    var workspace = "measurements"
    var targetCount: Int? = nil
    var durationSeconds: Double? = nil
    var elapsedActiveSeconds = 0.0
    var phase = "interrupted"
    var calibrationRecordIDs: [String] = []
    var startedAt = Date()
    var updatedAt = Date()
    var completed = 0
    var candidates = 0
    var qualifiedPulses = 0
    var rejectedWindows = 0
    var sampledSeconds = 0.0
    var gapSeconds = 0.0
    var observationOnly: Bool? = nil
    var processingProfile: String? = nil
    // Configured gain retained for schema compatibility. A false confirmation
    // means the actual physical gain is unknown.
    var physicalGain: String? = nil
    var gainConfirmed: Bool? = nil
    var observationWindows: Int? = nil
    var mainObservationOptions: MainObservationOptions? = nil
    var profileAcquisition: ProfileAcquisition? = nil
    var profileSegments: [ProfileRunSegment]? = nil
    var profilePauseReason: String? = nil
}

nonisolated struct RunRecordReceipt: Codable, Identifiable, Sendable {
    var schema = 1
    var id: String
    var runID: UUID
    var sessionID: UUID
    var sampleSHA256: String
    var acknowledgedAt = Date()
    var candidates: Int
    var qualifiedPulses: Int
    var rejectedWindows: Int
    var sampledSeconds: Double
    var gapSeconds: Double
    var observationWindows: Int? = nil
}

nonisolated struct RunRecordTotals: Sendable {
    var observationWindows = 0
    var completed = 0
    var candidates = 0
    var qualifiedPulses = 0
    var rejectedWindows = 0
    var sampledSeconds = 0.0
    var gapSeconds = 0.0
}
