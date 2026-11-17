import Foundation

nonisolated enum ExportScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case record, run, session
    var id: String { rawValue }
    var title: String {
        switch self {
        case .record: return "Selected record"
        case .run: return "Current run"
        case .session: return "Entire session"
        }
    }
}

nonisolated enum ExportDestination: String, Codable, Sendable {
    case session, project
}

nonisolated struct ExportOptions: Codable, Sendable {
    var scope: ExportScope
    var destination: ExportDestination = .session
    var metadataJSON = true
    var candidatesCSV = true
    var qualityCSV = true
    var calibrationsJSON = true
    var savedAnalyses = true
    var rawCSV = false
    var rawBinary = false
    var includeIncomplete = true

    var includesDetailedData: Bool {
        metadataJSON || candidatesCSV || qualityCSV || calibrationsJSON || savedAnalyses || rawCSV || rawBinary
    }
}
