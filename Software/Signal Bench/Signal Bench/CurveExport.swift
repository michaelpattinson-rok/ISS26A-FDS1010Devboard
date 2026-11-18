import Darwin
import Foundation

extension CurveDelivery {
    nonisolated static func export(_ reader: CurveReader, store: StreamProjectStore, root: URL, name: String,
                       range: StreamSelection, csv: Bool, checkpoint: () throws -> Void,
                       progress: (Double) -> Void, validate: () throws -> Void) throws -> URL {
        try StreamFiles.directory(root)
        let base = try SessionStore.projectName(name)
        let suffix = csv ? ".csv" : ".zip"
        let target = root.appendingPathComponent(base.lowercased().hasSuffix(suffix) ? base : base + suffix)
        guard try !StreamFiles.isPresent(target) else { throw POSIXError(.EEXIST) }
        let stage = try StreamFiles.directory(".curve-export-" + UUID().uuidString, in: root, create: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        let file = stage.appendingPathComponent("export" + suffix)
        if csv {
            let writer = try StreamOutput(file)
            try writer.line("segment,reading_index,first_conversion,end_conversion_exclusive,nominal_seconds,adc_codes,representation,source_adc_errors,source_low_rails,source_high_rails,frame_sequence,device_frame_end_us")
            var count: UInt64 = 0
            let expected = max(1, (range.upper - range.lower) * reader.run.settings.recordedRate)
            try reader.visit(range, checkpoint: checkpoint) { segment, index, reading, anchor in
                let rate = segment.configuredRate(reader.run.settings.nominalRate)
                let time = segment.timelineStart + Double(index) / rate
                let value = reading.value.map { String($0) } ?? ""
                let representation = reading.exact ? "exact" : "modeled"
                try writer.line("\(segment.id),\(index),\(index * segment.factor),\((index + 1) * segment.factor),\(time),\(value),\(representation),\(reading.adcErrors),\(reading.low),\(reading.high),\(anchor.sequence),\(anchor.deviceFrameEndUS)")
                count += 1
                if count.isMultiple(of: 16_384) { progress(min(0.99, Double(count) / expected)) }
            }
            guard count > 0 else { throw StreamFailure.storage("This range has no saved curve readings.") }
            _ = try writer.finish(file: target.lastPathComponent, type: "signalbench.curve-csv")
        } else {
            let archive = try RunExportZIP(file, date: reader.run.created)
            func add(_ data: Data, as name: String) throws {
                let member = try archive.entry(name)
                try member.write(data)
                try member.finish()
            }
            try add(Data("""
                # \(reader.run.name)

                Curve \(reader.manifest.name)
                Source run \(reader.manifest.source.uuidString)
                Maximum allowed error \(reader.manifest.settings.tolerance) ADC codes

                curve.json and index.json describe the measured grid, exact and modeled ranges, quality, and hashes.
                The .curve entries contain coefficients or exact ADC data. The .frames entries preserve device timing.
                Modeled values are for diagnostic review. Exposure remains invalid for count rates.
                """.utf8), as: "Main.md")
            try add(StreamFiles.encoder.encode(reader.run), as: "run.json")
            for (name, limit) in [("index.json", 32 * 1024 * 1024), ("curve.json", 1_048_576)] {
                try checkpoint()
                try add(StreamFiles.read(reader.folder.appendingPathComponent(name), limit: limit), as: name)
            }
            for (i, block) in reader.blocks.enumerated() {
                try checkpoint()
                try autoreleasepool {
                    let name = block.source.id.uuidString
                    try add(reader.storedBlock(block), as: "waveform/" + name + ".curve")
                    try add(reader.frameData(block), as: "waveform/" + name + ".frames")
                }
                if i.isMultiple(of: 16) { progress(Double(i + 1) / Double(reader.blocks.count) * 0.95) }
            }
            let source = StreamRangeReader(store: store, run: reader.run)
            let timeline = try RunTimeline.entries(source, finished: true)
            if !timeline.isEmpty { try add(StreamFiles.encoder.encode(timeline), as: "timeline.json") }
            if let annotations = try RunAnnotations.read(source) {
                try add(StreamFiles.encoder.encode(annotations), as: "annotations.json")
            }
            let runFolder = try store.runDirectory(reader.run.id)
            let sourceRun = runFolder.appendingPathComponent("source-run.json")
            if try StreamFiles.isPresent(sourceRun) { try add(StreamFiles.read(sourceRun, limit: 1_048_576), as: "source-run.json") }
            let reportsFolder = runFolder.appendingPathComponent(reader.run.curveSource == nil ? "analyses" : "source-analyses")
            let reports = try StreamStudio.analyses(in: reportsFolder, sourceRun: reader.run.curveSource ?? reader.run.id)
            for report in reports {
                try checkpoint()
                let folder = try StreamFiles.directory(report.id.uuidString, in: reportsFolder, create: false)
                let prefix = "source-analyses/" + report.id.uuidString + "/"
                for output in report.outputs {
                    try checkpoint()
                    let fd = Darwin.open(folder.appendingPathComponent(output.file).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard fd >= 0 else { throw StreamFiles.posix() }
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    defer { try? handle.close() }
                    var info = stat()
                    guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                          info.st_size >= 0, UInt64(info.st_size) == output.bytes else { throw CurveCodec.fault }
                    let member = try StreamOutput(member: archive.entry(prefix + output.file))
                    while let bytes = try handle.read(upToCount: 262_144), !bytes.isEmpty {
                        try checkpoint()
                        try member.write(bytes)
                    }
                    let actual = try member.finish(file: output.file, type: output.type)
                    guard actual.sha256 == output.sha256, actual.bytes == output.bytes else { throw CurveCodec.fault }
                }
                try add(StreamFiles.encoder.encode(report), as: prefix + "analysis.json")
            }
            try checkpoint()
            try archive.finish()
            try archive.verify(checkpoint: checkpoint)
        }
        try validate()
        try checkpoint()
        try StreamFiles.sync(stage)
        guard renamex_np(file.path, target.path, UInt32(RENAME_EXCL)) == 0 else { throw StreamFiles.posix() }
        try StreamFiles.sync(root)
        progress(1)
        return target
    }
}
