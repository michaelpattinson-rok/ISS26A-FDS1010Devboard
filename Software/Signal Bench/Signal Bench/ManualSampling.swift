import Foundation

struct ManualRateOption {
    let hz: Int?
    var title: String { hz.map { $0 == 1 ? "1 reading/s" : "\($0) readings/s" } ?? "Fastest" }
    var intervalNS: UInt64 { hz.map { 1_000_000_000 / UInt64($0) } ?? 0 }
    static let choices = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000].map { ManualRateOption(hz: $0) } + [ManualRateOption(hz: nil)]
}

/// Fixed capacity RAM history. It never writes files or grows with run duration.
struct ManualSampleBuffer {
    private var storage: [ManualSnapshot?]
    private var head = 0
    private(set) var count = 0
    private(set) var totalReadings: UInt64 = 0
    private(set) var errorReadings: UInt64 = 0
    let capacity: Int
    let windowUS: UInt64

    init(capacity: Int = 4096, windowUS: UInt64 = 60_000_000) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.windowUS = windowUS
        storage = Array(repeating: nil, count: capacity)
    }

    var latest: ManualSnapshot? {
        count == 0 ? nil : storage[(head + count - 1) % capacity]
    }

    mutating func append(_ sample: ManualSnapshot) {
        if count == capacity {
            storage[head] = sample
            head = (head + 1) % capacity
        } else {
            storage[(head + count) % capacity] = sample
            count += 1
        }
        if totalReadings < .max { totalReadings += 1 }
        if sample.adcError, errorReadings < .max { errorReadings += 1 }
        while count > 1, let first = storage[head], sample.timeUS >= first.timeUS,
              sample.timeUS - first.timeUS > windowUS {
            storage[head] = nil
            head = (head + 1) % capacity
            count -= 1
        }
    }

    func orderedSamples() -> [ManualSnapshot] {
        (0..<count).compactMap { storage[(head + $0) % capacity] }
    }

    /// Average received-reading cadence from device response timestamps, not ADC aperture timing.
    var observedRateHz: Double? {
        guard let last = latest, count > 1 else { return nil }
        var intervals = 0
        var first = last
        for offset in 1..<count {
            guard let sample = storage[(head + count - 1 - offset) % capacity], last.timeUS >= sample.timeUS else { break }
            if last.timeUS - sample.timeUS > 5_000_000, intervals > 0 { break }
            first = sample
            intervals += 1
        }
        guard last.timeUS > first.timeUS else { return nil }
        return Double(intervals) * 1_000_000 / Double(last.timeUS - first.timeUS)
    }

    mutating func reset() {
        storage = Array(repeating: nil, count: capacity)
        head = 0; count = 0; totalReadings = 0; errorReadings = 0
    }
}
