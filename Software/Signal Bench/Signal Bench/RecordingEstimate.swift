import Darwin
import Foundation

nonisolated struct RecordingEstimate: Sendable {
    let conversions: Int64
    let readings: Int64
    let payload: Int64
    let projectBytes: Int64
    let requiredBytes: Int64
    let availableBytes: Int64?

    init?(rate: Int, averaging: ADCAveraging?, seconds: Double, gpio: Bool, location: URL?, board: AcquisitionBoard = .picoW) {
        guard StreamWire.customRates.contains(rate), (0...StreamWire.maxDuration).contains(seconds) else { return nil }
        let configured = board.rate(rate)
        let n = Int64(averaging?.count ?? 1)
        let bytes = Int64(PicoAverage.stride(averaging))
        let frameSize = board == .unoR4 ? Int64(1024) : Int64(StreamWire.maxSamples)
        conversions = Int64((configured * seconds).rounded())
        readings = conversions / n
        payload = readings * bytes

        var filesystem = statfs()
        let hasVolume = location.map { statfs($0.path, &filesystem) == 0 } ?? false
        let blockSize = hasVolume ? max(4096, Int64(filesystem.f_bsize)) : 4096
        availableBytes = hasVolume ? Int64(min(Double(Int64.max / 2), Double(filesystem.f_bavail) * Double(filesystem.f_bsize))) : nil

        func allocated(_ length: Int64) -> Int64 { ((length + blockSize - 1) / blockSize) * blockSize }
        func projected(_ duration: Double) -> Int64 {
            let frames = Int64((configured * duration / Double(frameSize)).rounded(.up))
            let framePayload = frameSize / n * bytes
            let frameLimit = min(256, Int64(StreamProjectStore.chunkLimit) / framePayload)
            let perChunk = averaging == nil ? frameLimit :
                min(frameLimit, max(1, Int64((configured / Double(frameSize)).rounded(.up))))
            let chunks = (frames + perChunk - 1) / perChunk
            // Raw file, frame anchors, compact index, and filesystem metadata.
            let chunksOnDisk = chunks * (allocated(perChunk * framePayload) +
                allocated(perChunk * 160 + 320) + 3 * blockSize)
            // Firmware periodically records GPIO state and also records changes.
            let gpioBudget = gpio ? Int64(duration.rounded(.up)) * 4 * (2 * blockSize) : 0
            return chunksOnDisk + gpioBudget + 8 * 1024 * 1024
        }
        projectBytes = projected(seconds)
        requiredBytes = projected(seconds + StreamWire.stopReserveSeconds) + 32 * 1024 * 1024
    }

    static func requireSpace(for settings: StreamRunSettings, seconds: Double, in folder: URL,
                             additionalSeconds: Double? = nil) throws {
        var required: Int64 = 0
        var available: Int64?
        for phase in [seconds] + [additionalSeconds].compactMap({ $0 }) {
            guard let estimate = Self(rate: settings.nominalRate, averaging: settings.picoAveraging, seconds: phase,
                                      gpio: settings.mode == .manual, location: folder, board: settings.board),
                  let free = estimate.availableBytes else {
                throw StreamFailure.storage("Free space on the Project volume is unavailable.")
            }
            required += estimate.requiredBytes
            available = min(available ?? free, free)
        }
        guard let available, available >= required else {
            throw StreamFailure.storage("The Project volume does not have enough free space. Allow \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)) before recording.")
        }
    }
}
