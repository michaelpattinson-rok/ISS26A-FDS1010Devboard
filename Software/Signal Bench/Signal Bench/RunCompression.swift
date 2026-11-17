import Compression
import Darwin
import Foundation

/// A chunk is either its original words or a smaller, versioned LZFSE envelope.
/// The chunk index always describes the uncompressed words.
nonisolated enum RunCompression {
    private static let signature = Data([0x53, 0x42, 0x43, 1]) // SBC, format 1 (LZFSE)

    struct Inventory: Sendable {
        var original = 0
        var stored = 0
        var compressed = 0
        var chunks = 0
    }

    static func read(_ url: URL, summary: StreamChunkSummary) throws -> Data {
        let payload = try StreamFiles.read(url, limit: StreamProjectStore.chunkLimit)
        let words: Data
        if payload.count == summary.bytes {
            words = payload
        } else {
            guard payload.count > signature.count, payload.count < summary.bytes,
                  payload.starts(with: signature) else { throw invalidChunk() }
            // Extra capacity detects a stream that expands past the expected length.
            var decoded = Data(count: summary.bytes + 1)
            let count = decoded.withUnsafeMutableBytes { target in
                payload.withUnsafeBytes { input in
                    compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, target.count,
                                              input.bindMemory(to: UInt8.self).baseAddress!.advanced(by: signature.count),
                                              input.count - signature.count, nil, COMPRESSION_LZFSE)
                }
            }
            guard count == summary.bytes else { throw invalidChunk() }
            decoded.removeLast()
            words = decoded
        }
        guard StreamFiles.sha(words) == summary.sha256 else { throw invalidChunk() }
        return words
    }

    private static func invalidChunk() -> StreamFailure {
        .storage("A raw chunk failed SHA-256 or lossless decoding verification.")
    }

    private static func encode(_ words: Data) -> Data? {
        let capacity = words.count - signature.count - 1
        guard capacity > 0 else { return nil }
        var compressed = Data(count: capacity)
        let count = compressed.withUnsafeMutableBytes { target in
            words.withUnsafeBytes { source in
                compression_encode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard count > 0, count <= capacity else { return nil }
        compressed.count = count
        return signature + compressed
    }

    private static func size(_ url: URL, summary: StreamChunkSummary) throws -> Int {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw StreamFiles.posix() }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), (2...Int64(summary.bytes)).contains(info.st_size) else {
            throw invalidChunk()
        }
        return Int(info.st_size)
    }

    static func inventory(_ input: StreamRangeReader) throws -> Inventory {
        let reader = try input.prepared()
        guard let summaries = reader.index, !summaries.isEmpty else { return .init() }
        let folder = try StreamFiles.directory("chunks", in: reader.store.runDirectory(reader.run.id), create: false)
        var result = Inventory()
        for summary in summaries {
            try Task.checkCancellation()
            let file = folder.appendingPathComponent(summary.id.uuidString + ".bin")
            let stored = try size(file, summary: summary)
            result.original += summary.bytes
            result.stored += stored
            result.compressed += stored < summary.bytes ? 1 : 0
            result.chunks += 1
        }
        return result
    }

    static func rewrite(_ input: StreamRangeReader, compress: Bool, progress: (Int, Int) -> Void = { _, _ in }) throws -> Inventory {
        try input.store.verify()
        let directory = try input.store.runDirectory(input.run.id)
        let lock = try StreamRunLock(directory)
        defer { withExtendedLifetime(lock) {} }
        let run = try input.store.openRun(input.run.id)
        guard try StreamFiles.encoder.encode(run) == StreamFiles.encoder.encode(input.run), !run.isManualDraft else {
            throw StreamFailure.storage("Reopen the saved run before changing its storage.")
        }
        let reader = try StreamRangeReader(store: input.store, run: run).prepared()
        guard let summaries = reader.index, !summaries.isEmpty else {
            throw StreamFailure.storage("This run has no saved samples to archive.")
        }
        let folder = try StreamFiles.directory("chunks", in: directory, create: false)
        for (index, summary) in summaries.enumerated() {
            try Task.checkCancellation()
            if index.isMultiple(of: 32) { try reader.store.verify() }
            try autoreleasepool {
                _ = try reader.store.chunk(summary, run: run)
                let target = folder.appendingPathComponent(summary.id.uuidString + ".bin")
                let stored = try size(target, summary: summary)
                let original = try read(target, summary: summary)
                let replacement = compress ? (stored == summary.bytes ? encode(original) : nil)
                                           : (stored < summary.bytes ? original : nil)
                guard let replacement else { return }
                try swapVerified(replacement, with: target, summary: summary)
            }
            progress(index + 1, summaries.count)
        }
        try clearVerifiedRecovery(in: folder, summaries: summaries)
        return try inventory(reader)
    }

    private static func clearVerifiedRecovery(in folder: URL, summaries: [StreamChunkSummary]) throws {
        let byID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        var removed = false
        for name in files where name.hasPrefix(".archive-") && name.count == 82 {
            try Task.checkCancellation()
            let value = name.dropFirst(9)
            guard let id = UUID(uuidString: String(value.prefix(36))),
                  UUID(uuidString: String(value.suffix(36))) != nil,
                  value.dropFirst(36).first == "-", let summary = byID[id] else { continue }
            let current = folder.appendingPathComponent(id.uuidString + ".bin")
            let recovery = folder.appendingPathComponent(name)
            _ = try read(current, summary: summary)
            // Only remove a previous representation after independently verifying it and the current file.
            guard (try? read(recovery, summary: summary)) != nil else { continue }
            if unlink(recovery.path) == 0 { removed = true }
        }
        if removed { try StreamFiles.sync(folder) }
    }

    private static func swapVerified(_ bytes: Data, with target: URL, summary: StreamChunkSummary) throws {
        let folder = target.deletingLastPathComponent()
        let candidate = folder.appendingPathComponent(".archive-\(summary.id)-\(UUID())")
        var keepRecovery = false
        defer { if !keepRecovery { _ = unlink(candidate.path) } }
        try StreamFiles.publish(bytes, at: candidate)
        _ = try read(candidate, summary: summary)
        try Task.checkCancellation()
        guard renamex_np(candidate.path, target.path, UInt32(RENAME_SWAP)) == 0 else { throw StreamFiles.posix() }
        // The previous, verified representation remains available until the replacement is durable.
        keepRecovery = true
        do {
            try StreamFiles.sync(folder)
            _ = try read(target, summary: summary)
            keepRecovery = false
        } catch {
            if renamex_np(candidate.path, target.path, UInt32(RENAME_SWAP)) == 0,
               (try? StreamFiles.sync(folder)) != nil {
                keepRecovery = false
            }
            throw error
        }
    }
}
