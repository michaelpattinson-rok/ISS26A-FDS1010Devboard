import Foundation

nonisolated struct ReviewSpectralComparison: Codable, Sendable {
    let sampleRate: Double
    let transformSize: Int
    let windows: Int
    let raw: [PostRunAnalysis.Spectrum.Point]
    let processed: [PostRunAnalysis.Spectrum.Point]
    let reference: [PostRunAnalysis.Spectrum.Point]?

    var analyzedSeconds: Double { Double(windows * transformSize) / sampleRate }

    func bandPower(_ values: [PostRunAnalysis.Spectrum.Point], around hz: Double) -> Double? {
        guard windows > 0, hz > 0, hz < sampleRate / 2 else { return nil }
        let spacing = sampleRate / Double(transformSize)
        return values.filter { abs($0.hz - hz) <= spacing * 1.5 }.reduce(0) { $0 + $1.density * spacing }
    }
}

/// Collect only complete windows where every compared trace is eligible.
/// Original segment indices anchor the quarter second grid independently of disk chunks.
nonisolated final class ReviewSpectrumCollector {
    private struct Bank {
        let raw: ADCSpectrumAverage
        let processed: ADCSpectrumAverage
        let reference: ADCSpectrumAverage?
        let stride: UInt64
    }
    private let comparing: Bool
    private var banks: [Double: Bank] = [:]
    private var segment: UUID?
    private var next: UInt64?
    private var raw: [Double] = []
    private var processed: [Double] = []
    private var reference: [Double] = []

    init(comparing: Bool) { self.comparing = comparing }

    func register(rate: Double) throws {
        guard banks[rate] == nil else { return }
        guard banks.count < 16 else { throw StreamFailure.storage("Select fewer sample rates for this spectrum comparison.") }
        var size = 128
        while size * 2 <= min(32_768, Int(16_384 * rate / Double(StreamWire.rate))) { size *= 2 }
        guard let original = ADCSpectrumAverage(size: size, rate: rate),
              let filtered = ADCSpectrumAverage(size: size, rate: rate) else {
            throw StreamFailure.storage("Could not prepare the spectrum comparison.")
        }
        let reference = comparing ? ADCSpectrumAverage(size: size, rate: rate) : nil
        guard !comparing || reference != nil else { throw StreamFailure.storage("Could not prepare the reference spectrum.") }
        banks[rate] = Bank(raw: original, processed: filtered, reference: reference,
                           stride: UInt64(max(size, Int((rate / 4).rounded()))))
    }

    func append(segment id: UUID, index: UInt64, rate: Double, code: Double, filtered: Double?, peer: Double?) {
        guard let bank = banks[rate] else { return }
        if segment != id || next != index {
            reset()
            segment = id
        }
        guard let filtered, !comparing || peer != nil else { reset(); return }
        guard next != nil || index.isMultiple(of: bank.stride) else { return }
        raw.append(code)
        processed.append(filtered)
        if let peer { reference.append(peer) }
        next = index + 1
        if raw.count == bank.raw.size {
            bank.raw.append(raw)
            bank.processed.append(processed)
            bank.reference?.append(reference)
            reset()
        }
    }

    private func reset() {
        next = nil
        raw.removeAll(keepingCapacity: true)
        processed.removeAll(keepingCapacity: true)
        reference.removeAll(keepingCapacity: true)
    }

    func results() -> [ReviewSpectralComparison] {
        func points(_ average: ADCSpectrumAverage) -> [PostRunAnalysis.Spectrum.Point] {
            average.points.map { .init(hz: $0.x, density: $0.y) }
        }
        return banks.keys.sorted().compactMap { rate in
            guard let bank = banks[rate] else { return nil }
            return .init(sampleRate: rate, transformSize: bank.raw.size, windows: bank.raw.windows,
                         raw: points(bank.raw), processed: points(bank.processed), reference: bank.reference.map(points))
        }
    }
}
