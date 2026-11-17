import Foundation

/// Maps the documented v1 firmware masks. Unknown bits are retained for diagnosis.
enum RecordDiagnostics {
    static let acquisition: [(UInt32, String)] = [
        (1, "Acquisition timed out"), (2, "ADC FIFO overflow"),
        (4, "ADC FIFO underflow"), (8, "ADC conversion error"),
        (16, "Invalid sample count"), (32, "Fixture timing error")
    ]
    static let quality: [(UInt32, String)] = [
        (1, "Invalid analysis input"), (2, "ADC sample error"),
        (4, "ADC clipping"), (8, "Baseline outside range"),
        (16, "Baseline too noisy"), (32, "Baseline contains outliers"),
        (64, "Baseline drift"), (128, "Too many candidates"),
        (256, "Possible pulse overlap"), (512, "Pulse too short"),
        (1024, "Pulse too long"), (2048, "Pulse at capture boundary"),
        (4096, "Threshold below noise"), (8192, "Local baseline unsuitable")
    ]

    static func describe(_ raw: String?, flags: [(UInt32, String)]) -> [String]? {
        guard let raw, let value = UInt32(raw) else { return nil }
        if value == 0 { return [] }
        var remaining = value
        var names: [String] = []
        for (mask, name) in flags where value & mask != 0 {
            names.append(name)
            remaining &= ~mask
        }
        if remaining != 0 { names.append(String(format: "Unrecognized flags: 0x%X", remaining)) }
        return names
    }
}

struct CalibrationDiagnosis {
    let title: String
    let summary: String
    var reasons: [String] = []
    var checks: [String] = []

    static func forRecord(_ record: CaptureRecord) -> Self? {
        let metadata = record.metadata
        guard metadata["tag"] == "CAL" else { return nil }
        guard record.complete else {
            return .init(title: "Calibration transfer incomplete", summary: "Recover the pending record to inspect the full result. If it is no longer on the Pico, run a fresh quiet calibration.")
        }
        if metadata["cal_window_accepted"] == "1", let remaining = metadata["calibration_remaining"].flatMap(Int.init), (1...7).contains(remaining) {
            return .init(title: "Quiet window accepted", summary: "This saved attempt passed its quiet checks. \(remaining) more windows are needed before the calibration can be used.")
        }
        switch metadata["calibrated"] {
        case "1":
            return .init(title: "Calibration accepted when recorded", summary: "The Pico accepted the quiet threshold for this capture.")
        case "0":
            break
        default:
            return .init(title: "Calibration result unavailable", summary: "This saved record lacks a recognizable calibration result.")
        }

        var reasons = RecordDiagnostics.describe(metadata["acq_flags"], flags: RecordDiagnostics.acquisition) ?? []
        reasons += RecordDiagnostics.describe(metadata["quality_flags"], flags: RecordDiagnostics.quality) ?? []
        let acquisition = metadata["acq_flags"].flatMap(UInt32.init) ?? 0
        let quality = metadata["quality_flags"].flatMap(UInt32.init) ?? 0
        let candidates = metadata["candidates"].flatMap(UInt64.init) ?? 0
        if candidates > 0 { reasons.append("Pulse candidates in the quiet window (\(candidates))") }
        let retainedCount = record.metadata["host_sample_count"].flatMap(Int.init) ?? record.samples.count
        if retainedCount == 0 { reasons.append("No samples retained") }

        // Firmware also rejects excursions in either direction across the full record.
        // Published baseline and threshold are rounded to three decimal places.
        if acquisition == 0, quality == 0, candidates == 0,
           let baseline = metadata["baseline"].flatMap(Double.init), (0...4095).contains(baseline),
           let threshold = metadata["threshold"].flatMap(Double.init), (0...4095).contains(threshold), threshold > 0,
           record.samples.contains(where: { $0 & 0x8000 == 0 && abs(Double($0 & 0x0fff) - baseline) > threshold + 0.002 }) {
            reasons.append("A sample exceeded the quiet limit above or below baseline")
        }

        var checks: [String] = []
        if acquisition != 0 || quality & 3 != 0 || retainedCount == 0 {
            checks.append("Check that the Pico stays connected and powered. Verify J2 ground, 3V3 and GP26. Remove USB power before moving any wires.")
        }
        if quality & 12 != 0 {
            checks.append("With the detector covered, measure 3V3 and VMID at J3. Check CSA and GAIN for clipping or a stuck output.")
        }
        if quality & 0x3ff0 != 0 || candidates > 0 || checks.isEmpty {
            checks.append("Keep the detector covered, let the signal settle and keep leads still. Check the waveform for spikes or drift before retrying.")
        }
        return .init(title: "Calibration rejected",
                     summary: reasons.isEmpty ? "The Pico rejected this quiet window. Open its full waveform for inspection; the available metadata does not identify a specific reason." : "The Pico did not accept a quiet threshold for this capture. Raw observation remains available on compatible firmware.",
                     reasons: reasons, checks: checks)
    }
}
