import Foundation

nonisolated struct ProjectCSVRequest: Sendable {
    let filename: String
    let description: String

    init?(filename: String, description: String) {
        var name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".csv") { name.removeLast(4) }
        guard !name.isEmpty, !name.hasPrefix("."), !name.hasSuffix("."),
              name.utf8.count <= 120, description.utf8.count <= 4096,
              name.rangeOfCharacter(from: CharacterSet.controlCharacters.union(.init(charactersIn: "/\\:"))) == nil,
              !description.contains("\0") else { return nil }
        self.filename = name + ".csv"
        self.description = description
    }
}

nonisolated enum ProjectCSVSource: Identifiable, Sendable {
    case waveformRun(UUID)
    case record(String)

    var id: String {
        switch self {
        case .waveformRun(let id): "run-\(id)"
        case .record(let id): "window-\(id)"
        }
    }

    var defaultName: String {
        let label = switch self {
        case .waveformRun: "Waveforms"
        case .record: "Waveform"
        }
        return "\(label) \(id.split(separator: "-").dropFirst().first?.prefix(8) ?? "")"
    }
}

