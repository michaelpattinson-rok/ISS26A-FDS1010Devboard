import Foundation

/// ZIP members are serial. While the primary member streams directly to the
/// archive, secondary sample tables spool one part, then are compressed and removed.
nonisolated final class RunExportSamples {
    static let partReadings: UInt64 = 1_048_576
    let root: URL
    let archive: RunExportZIP?
    let format: StreamExporter.Format
    let prefix: String
    let averaged: Bool
    let legacy: ADCAveraging?
    let includesCleaned: Bool
    private var part = 0
    private var readings: UInt64 = 0
    private var primary: StreamOutput?
    private var csv: RunSampleCSV?
    private var cleanedOutput: StreamOutput?
    private var cleaned: RunSampleCSV?
    private var legacyCSV: ADCAveragedCSV?
    private(set) var outputs: [StreamAnalysisOutput] = []

    init(root: URL, archive: RunExportZIP?, format: StreamExporter.Format, settings: StreamRunSettings,
         hasExclusions: Bool, prefix: String = "") throws {
        self.root = root
        self.archive = archive
        self.format = format
        self.prefix = prefix
        averaged = settings.picoAveraging != nil
        legacy = format.writesBinary ? nil : settings.adcAveraging
        includesCleaned = format == .zip && hasExclusions
        try beginPart()
    }

    var hasPrimary: Bool { format != .averaged || averaged }

    private var primaryName: String {
        if format.writesBinary { return averaged ? "groups.avg1" : "raw.bin" }
        if format == .cleaned { return "cleaned.csv" }
        return averaged ? "averaged.csv" : "raw.csv"
    }

    private func name(_ base: String) -> String {
        guard part > 1 else { return base }
        return String(base.dropLast(4)) + "-part-" + String(format: "%05d", part) + ".csv"
    }

    private func beginPart() throws {
        part += 1
        readings = 0
        if hasPrimary {
            let path = name(primaryName)
            let output: StreamOutput
            if let archive { output = try StreamOutput(member: archive.entry(prefix + path)) }
            else { output = try StreamOutput(root.appendingPathComponent(path)) }
            primary = output
            if !format.writesBinary { csv = try RunSampleCSV(output: output, picoAveraged: averaged) }
        }
        if includesCleaned {
            let output = try StreamOutput(root.appendingPathComponent(name("cleaned.csv")))
            cleanedOutput = output
            cleaned = try RunSampleCSV(output: output, picoAveraged: averaged)
        }
        if let legacy {
            let output = try StreamOutput(root.appendingPathComponent(name("averaged.csv")))
            if legacyCSV == nil { legacyCSV = try ADCAveragedCSV(preset: legacy, output: output) }
            else { try legacyCSV?.beginPart(output) }
        }
    }

    func append(_ data: StreamRangeData, range: Range<UInt64>, retained: [Range<UInt64>], prefix: Data,
                checkpoint: () throws -> Void) throws {
        if archive != nil, !format.writesBinary, readings >= Self.partReadings {
            try finishPart(checkpoint: checkpoint)
            try beginPart()
        }
        if format.writesBinary { try primary?.write(data.originalPayload) }
        else { try csv?.append(data, pieces: format == .cleaned ? retained : [range], prefix: prefix) }
        try cleaned?.append(data, pieces: retained, prefix: prefix)
        if legacyCSV != nil {
            for piece in format == .cleaned ? retained : [range] {
                var slice = data
                slice.reference.first = piece.lowerBound
                slice.reference.count = piece.count
                let start = Int(piece.lowerBound - range.lowerBound) * 2
                slice.words = piece == range ? data.words : data.words.subdata(in: start..<(start + piece.count * 2))
                try legacyCSV?.append(slice)
            }
        }
        readings += UInt64(data.reference.count)
    }

    func finish(checkpoint: () throws -> Void) throws -> [StreamAnalysisOutput] {
        if !hasPrimary, legacyCSV?.groups == 0 {
            throw StreamFailure.storage("The selected range contains no complete averaging groups.")
        }
        try finishPart(checkpoint: checkpoint)
        return outputs
    }

    private func finishPart(checkpoint: () throws -> Void) throws {
        try checkpoint()
        try csv?.flush()
        if let primary {
            let type = format.writesBinary ? (averaged ? "signalbench.adc-groups-avg1" : "signalbench.adc-words-le") :
                (averaged ? "signalbench.adc-groups-csv" : "signalbench.adc-csv")
            outputs.append(try primary.finish(file: prefix + name(primaryName), type: type))
        }
        if let cleanedOutput {
            try cleaned?.flush()
            let file = name("cleaned.csv")
            outputs.append(try cleanedOutput.finish(file: prefix + file, type: "signalbench.cleaned-readings"))
            try archiveSpool(file, checkpoint: checkpoint)
        }
        if let legacyCSV {
            let file = name("averaged.csv")
            outputs.append(try legacyCSV.finish(file: prefix + file))
            try archiveSpool(file, checkpoint: checkpoint)
        }
        primary = nil
        csv = nil
        cleanedOutput = nil
        cleaned = nil
    }

    private func archiveSpool(_ file: String, checkpoint: () throws -> Void) throws {
        guard let archive else { return }
        let url = root.appendingPathComponent(file)
        try archive.addFile(url, as: prefix + file, checkpoint: checkpoint)
        try FileManager.default.removeItem(at: url)
    }
}
