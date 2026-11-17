import Accelerate
import Foundation

nonisolated struct FixtureFit: Codable, Equatable, Sendable {
    var first: UInt64
    var alignment: UInt64
    var peakIndex: UInt64
    var fractionalOffset = 0.0
    var amplitude: Double
    var score: Double
    var residual: Double
    var offset: Double
    var slope: Double
}

nonisolated struct FixtureFitBank {
    let coarse: FixtureKernel
    private let phases: [(offset: Double, kernel: FixtureKernel)]

    init(_ coarse: FixtureKernel) throws {
        self.coarse = coarse
        phases = try (-4...4).filter { $0 != 0 }.map { step in
            let offset = Double(step) / 8
            let shape = coarse.shape.indices.map { i in
                let coordinate = Double(i) - offset
                let left = Int(floor(coordinate))
                let fraction = coordinate - Double(left)
                let a = coarse.shape[min(coarse.shape.count - 1, max(0, left))]
                let b = coarse.shape[min(coarse.shape.count - 1, max(0, left + 1))]
                return a + (b - a) * fraction
            }
            return (offset, try FixtureKernel(shape: shape, before: coarse.before, peak: coarse.peak, ar: coarse.ar))
        }
    }

    func fit(_ raw: [Double], first: UInt64) -> (estimate: FixtureFit, kernel: FixtureKernel) {
        var best = coarse.fit(raw, first: first), kernel = coarse
        for phase in phases {
            var estimate = phase.kernel.fit(raw, first: first)
            if estimate.amplitude > 0, estimate.score > best.score + 1e-12 {
                estimate.fractionalOffset = phase.offset
                best = estimate
                kernel = phase.kernel
            }
        }
        return (best, kernel)
    }
}

nonisolated struct FixtureFitPreview: Codable, Sendable {
    var segment: UUID
    var fit: FixtureFit
    var raw: [Double]
    var fitted: [Double]
    var reason: String?
}

nonisolated struct FixtureFitLimits: Codable, Equatable, Sendable {
    var minimumAmplitude: Double
    var minimumScore: Double
    var maximumRelativeResidual: Double

    func review(_ fit: FixtureFit) -> String? {
        if fit.amplitude + 1e-8 < minimumAmplitude { return "Below the training amplitude floor." }
        if fit.score + 1e-8 < minimumScore { return "The waveform has a low template score." }
        if fit.residual / max(fit.amplitude, 1e-8) > maximumRelativeResidual + 1e-8 {
            return "The fit leaves a large residual."
        }
        return nil
    }

    var valid: Bool {
        (0.01...4095).contains(minimumAmplitude) && (0...1).contains(minimumScore)
        && (0...1).contains(maximumRelativeResidual)
    }
}

nonisolated struct FixtureKernel {
    let shape: [Double]
    let before: Int
    let peak: Int
    let ar: Double?
    private let projected: [Double]
    private let energy: Double

    init(shape: [Double], before: Int, peak: Int, ar: Double?) throws {
        self.shape = shape
        self.before = before
        self.peak = peak
        self.ar = ar
        let transformed = Self.transform(shape, ar)
        self.projected = Self.detrend(transformed).residual
        self.energy = projected.reduce(0) { $0 + $1 * $1 }
        guard energy.isFinite, energy > 1e-10 else {
            throw StreamFailure.storage("The template has no pulse shape after removing offset and slope.")
        }
    }

    static func usable(_ word: UInt16, board: AcquisitionBoard = .picoW) -> Bool {
        word & 0x8000 == 0 && (1..<board.maxCode).contains(board.sampleCode(word))
    }

    static func detrend(_ x: [Double]) -> (offset: Double, slope: Double, residual: [Double]) {
        let n = Double(x.count), middle = (n - 1) / 2
        let offset = x.reduce(0, +) / n
        let timeEnergy = n * (n * n - 1) / 12
        let slope = x.enumerated().reduce(0.0) { $0 + (Double($1.offset) - middle) * $1.element } / timeEnergy
        return (offset, slope, x.enumerated().map { $0.element - offset - (Double($0.offset) - middle) * slope })
    }

    // Training supplies pulse-free samples at both ends. Using them for the
    // template normalization avoids subtracting the pulse's own mean height.
    static func removeSidebandBaseline(_ x: [Double]) -> [Double] {
        let sideCount = max(2, x.count / 8)
        let sides = (0..<sideCount).map { $0 } + (x.count - sideCount..<x.count)
        let middle = Double(x.count - 1) / 2
        let offset = sides.reduce(0.0) { $0 + x[$1] } / Double(sides.count)
        let cross = sides.reduce(0.0) { $0 + (Double($1) - middle) * (x[$1] - offset) }
        let variance = sides.reduce(0.0) { $0 + pow(Double($1) - middle, 2) }
        let slope = cross / variance
        return x.enumerated().map { $0.element - offset - (Double($0.offset) - middle) * slope }
    }

    private static func transform(_ x: [Double], _ ar: Double?) -> [Double] {
        guard let ar else { return x }
        return (1..<x.count).map { x[$0] - ar * x[$0 - 1] }
    }

    // Correlation of every complete fit window. For AR(1), each window drops
    // its first whitened point, so it never depends on data before its start.
    func screen(_ words: [UInt16], means: [Double]? = nil, board: AcquisitionBoard = .picoW) -> (amplitudes: [Double], scores: [Double]) {
        let count = words.count - shape.count + 1
        guard count > 0 else { return ([], []) }
        let values = means ?? words.map { Double(board.sampleCode($0)) }
        let x = Self.transform(values.map { $0 - 2048 }, ar)
        let length = projected.count, n = Double(length), middle = (n - 1) / 2
        let timeEnergy = n * (n * n - 1) / 12
        var dots = [Double](repeating: 0, count: count)
        vDSP_convD(x, 1, projected, 1, &dots, 1, vDSP_Length(count), vDSP_Length(length))
        var invalid = words.prefix(shape.count).reduce(0) { $0 + (Self.usable($1, board: board) ? 0 : 1) }
        var sum = 0.0, square = 0.0, moment = 0.0
        var scores = [Double](repeating: 0, count: count)
        for i in 0..<count {
            if i.isMultiple(of: 1024) {
                sum = 0; square = 0; moment = 0
                for j in 0..<length {
                    let v = x[i + j]
                    sum += v; square += v * v; moment += Double(j) * v
                }
            }
            let centeredMoment = moment - middle * sum
            let variance = max(0, square - sum * sum / n - centeredMoment * centeredMoment / timeEnergy)
            let dot = dots[i]
            dots[i] = invalid == 0 ? dot / energy : -.infinity
            if invalid == 0, variance > 1e-8 { scores[i] = min(1, max(-1, dot / sqrt(energy * variance))) }
            if i + 1 < count {
                let old = x[i], next = x[i + length]
                moment += Double(length - 1) * next - (sum - old)
                sum += next - old; square += next * next - old * old
                if !Self.usable(words[i], board: board) { invalid -= 1 }
                if !Self.usable(words[i + shape.count], board: board) { invalid += 1 }
            }
        }
        return (dots, scores)
    }

    func fit(_ raw: [Double], first: UInt64) -> FixtureFit {
        let t = Self.transform(raw, ar)
        let data = Self.detrend(t).residual
        let cross = zip(projected, data).reduce(0.0) { $0 + $1.0 * $1.1 }
        let power = data.reduce(0) { $0 + $1 * $1 }
        let amplitude = cross / energy
        let withoutPulse = zip(raw, shape).map { $0 - amplitude * $1 }
        let line = Self.detrend(Self.transform(withoutPulse, ar))
        let slope = line.slope / (1 - (ar ?? 0))
        // For centered sample coordinates the AR transform maps the
        // intercept to (1-rho)*offset + (1+rho)*slope/2.
        let offset = (line.offset - (ar.map { (1 + $0) * slope / 2 } ?? 0)) / (1 - (ar ?? 0))
        let center = Double(shape.count - 1) / 2
        let error = withoutPulse.enumerated().reduce(0.0) {
            let d = $1.element - offset - slope * (Double($1.offset) - center)
            return $0 + d * d
        }
        return .init(first: first, alignment: first + UInt64(before), peakIndex: first + UInt64(peak),
                     amplitude: amplitude, score: power > 1e-10 ? min(1, max(-1, cross / sqrt(power * energy))) : 0,
                     residual: sqrt(error / Double(shape.count)), offset: offset, slope: slope)
    }

    var halfHeightWidth: Int {
        let height = abs(shape[peak]) / 2
        var first = peak, end = peak + 1
        while first > 0, abs(shape[first - 1]) >= height { first -= 1 }
        while end < shape.count, abs(shape[end]) >= height { end += 1 }
        return end - first
    }

    func waveform(_ fit: FixtureFit) -> [Double] {
        let center = Double(shape.count - 1) / 2
        return shape.enumerated().map { fit.offset + fit.slope * (Double($0.offset) - center) + fit.amplitude * $0.element }
    }
}

nonisolated enum FixtureTiles {
    // Tiles own half-open center ranges. Halos are read once and reused
    // across USB frames and disk chunks, with a reset only at a real break.
    static func visit(_ reader: StreamRangeReader, selection: StreamSelection, halo: Int, tileSamples: Int = 65_536,
                      aligned: Bool = false, excluding: [UUID: [Range<UInt64>]] = [:], source: (StreamRangeData) throws -> Void = { _ in },
                      _ body: (ReviewSpan, Range<UInt64>) throws -> Void) throws {
        let size = tileSamples
        var segment: StreamRunSegment?, first: UInt64 = 0, owner: UInt64 = 0
        var words: [UInt16] = [], means: [Double] = []
        func emit(final: Bool) throws {
            while owner < first + UInt64(words.count) {
                let end = first + UInt64(words.count)
                if !final && owner + UInt64(size + halo) > end { break }
                try Task.checkCancellation()
                let next = min(end, owner + UInt64(size))
                let limit = min(words.count, Int(next - first) + halo)
                try body(.init(segment: segment!, first: first, words: Array(words.prefix(limit)),
                               means: segment?.picoAveraging == nil ? nil : Array(means.prefix(limit))), owner..<next)
                owner = next
                let retained = max(first, owner >= UInt64(halo) ? owner - UInt64(halo) : 0)
                words.removeFirst(Int(retained - first))
                if !means.isEmpty { means.removeFirst(Int(retained - first)) }
                first = retained
            }
        }
        try reader.visit(selection) { part in
            try source(part)
            let base = part.reference.first
            let range = base..<(base + UInt64(part.reference.count))
            for retained in RunAnnotations.retained(range, excluding: excluding[part.segment.id] ?? []) {
                if segment?.id != part.segment.id || first + UInt64(words.count) != retained.lowerBound {
                    try emit(final: true)
                    words.removeAll(keepingCapacity: true)
                    means.removeAll(keepingCapacity: true)
                    segment = part.segment
                    first = retained.lowerBound
                    owner = first
                }
                let offset = Int(retained.lowerBound - base)
                part.words.withUnsafeBytes { data in
                    for i in offset..<(offset + retained.count) {
                        words.append(UInt16(littleEndian: data.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self)))
                        if let group = part.groups?[i] { means.append(group.mean ?? 0) }
                    }
                }
                try emit(final: false)
            }
        }
        try emit(final: true)
    }
}
