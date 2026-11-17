import Foundation

nonisolated struct FixtureSelectionResult: Codable, Sendable {
    var type = "signalbench.fixture-fit-selection"
    var version = 1
    var template: FixtureStudyTemplate
    var templateSHA256: String
    var weighted: Bool
    var operatorConfirmed: Bool
    var sources: [StreamRangeReference]
    var preview: FixtureFitPreview
}

nonisolated enum FixtureSelection {
    static let analyzer = "signalbench.fixture-fit-selection"

    static func save(_ original: StreamRangeReader, selection: StreamSelection, template: FixtureStudyTemplate,
                     weighted: Bool, operatorConfirmed: Bool = false) throws -> (StreamAnalysisManifest, FixtureSelectionResult) {
        try original.store.verify()
        let reader = try original.prepared()
        let before = try ReviewInput.load(reader, selection: selection, context: 0.03).refs
        guard let preview = try FixtureTemplateStudy.inspect(reader, selection: selection, template: template,
                                                             weighted: weighted, operatorConfirmed: operatorConfirmed) else {
            throw StreamFailure.storage("The selection has no clean fitted waveform.")
        }
        let current = try ReviewInput.load(reader, selection: selection, context: 0.03).refs
        guard before == current else { throw StreamFailure.storage("The waveform changed while fitting.") }
        let hash = StreamFiles.sha(try StreamFiles.encoder.encode(template))
        let result = FixtureSelectionResult(template: template, templateSHA256: hash, weighted: weighted, operatorConfirmed: operatorConfirmed,
                                            sources: current, preview: preview)
        let parent = try StreamFiles.directory("analyses", in: reader.store.runDirectory(reader.run.id), create: true)
        var manifest = StreamAnalysisManifest(run: reader.run.id, selection: selection,
            streams: Array(Set(current.map(\.stream))).sorted(), analyzer: analyzer, analyzerVersion: 1,
            profileRevision: reader.run.settings.profile?.id, outputs: [])
        _ = try ReviewFiles.publish(in: parent, name: manifest.id.uuidString) { stage in
            let file = try StreamOutput(stage.appendingPathComponent("fit.json"))
            try file.write(StreamFiles.encoder.encode(result))
            manifest.outputs = [try file.finish(file: "fit.json", type: analyzer)]
            try reader.store.verify()
            try StreamFiles.publish(manifest, at: stage.appendingPathComponent("analysis.json"))
        }
        return (manifest, result)
    }

    static func load(_ reader: StreamRangeReader, manifest: StreamAnalysisManifest) throws -> FixtureSelectionResult {
        guard manifest.run == reader.run.id, manifest.analyzer == analyzer, manifest.analyzerVersion == 1,
              let file = manifest.outputs.first, file.file == "fit.json", file.type == analyzer, file.version == 1 else {
            throw StreamFailure.storage("Choose a saved waveform fit.")
        }
        let parent = try StreamFiles.directory("analyses", in: reader.store.runDirectory(reader.run.id), create: false)
        let folder = try StreamFiles.directory(manifest.id.uuidString, in: parent, create: false)
        let bytes = try StreamFiles.read(folder.appendingPathComponent(file.file), limit: 16_777_216)
        guard bytes.count == file.bytes, StreamFiles.sha(bytes) == file.sha256 else {
            throw StreamFailure.storage("The saved fit failed its integrity check.")
        }
        let fit = try StreamFiles.decoder.decode(FixtureSelectionResult.self, from: bytes)
        let input = try ReviewInput.load(reader, selection: manifest.selection, context: 0.03)
        let estimate = fit.preview.fit
        guard fit.version == 1, fit.type == analyzer, fit.template.compatible(reader, operatorConfirmed: fit.operatorConfirmed), fit.template.valid,
              fit.templateSHA256 == StreamFiles.sha(try StreamFiles.encoder.encode(fit.template)),
              fit.sources == input.refs, fit.preview.raw.count == fit.template.shape.count,
              fit.preview.fitted.count == fit.preview.raw.count,
              estimate.first <= 3_600_000_000,
              estimate.alignment == estimate.first + UInt64(fit.template.before),
              estimate.peakIndex == estimate.first + UInt64(fit.template.peak),
              (-0.5...0.5).contains(estimate.fractionalOffset),
              [estimate.amplitude, estimate.score, estimate.residual, estimate.offset, estimate.slope].allSatisfy(\.isFinite),
              fit.preview.raw.allSatisfy(\.isFinite), fit.preview.fitted.allSatisfy(\.isFinite) else {
            throw StreamFailure.storage("The waveform source or template differs from the saved fit.")
        }
        return fit
    }
}
