import Foundation

nonisolated enum NoisePolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case review = "Review Only", conservative = "Conservative", standard = "Standard", custom = "Custom"
    var id: Self { self }
}

nonisolated struct ProjectDefaults: Codable, Equatable, Sendable {
    var minutes = 5
    var noise = NoisePolicy.review
    var afterRecording: PostRunOption? = nil
    var startupDelaySeconds: Int? = nil
    var startupDelay: Int { startupDelaySeconds ?? StreamStartupDelay.defaultSeconds }
    var valid: Bool { (1...120).contains(minutes) && StreamStartupDelay.supported.contains(startupDelay) }
}

nonisolated struct OpticalPreset: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var lighting: String
    var valid: Bool { ["Dim Light", "Room Light"].contains(lighting) && (try? SessionStore.projectName(name)) == name }

    func save(_ project: StreamProjectStore) throws {
        try project.verify()
        guard valid else { throw StreamFailure.project("Check the optical preset.") }
        let folder = try StreamFiles.directory("optical-presets", in: project.folder, create: true)
        try StreamFiles.publish(self, at: folder.appendingPathComponent(id.uuidString + ".json"))
    }

    static func list(_ project: StreamProjectStore) throws -> [Self] {
        let folder = project.folder.appendingPathComponent("optical-presets")
        guard try StreamFiles.isPresent(folder) else { return [] }
        try StreamFiles.directory(folder)
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map {
                let preset = try StreamFiles.read(Self.self, $0)
                guard preset.valid, $0.lastPathComponent == preset.id.uuidString + ".json" else {
                    throw StreamFailure.project("An optical preset could not be read.")
                }
                return preset
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
