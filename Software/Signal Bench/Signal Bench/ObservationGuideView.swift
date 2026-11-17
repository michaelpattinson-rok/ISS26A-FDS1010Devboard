import SwiftUI

/// Contextual help describes reported values without inferring a physical cause.
struct ObservationGuideView: View {
    let record: CaptureRecord?
    let calibration: CaptureRecord?
    private let calibrationExpanded: Bool
    @State private var interpretationOpen = false
    @State private var calibrationOpen = false

    init(record: CaptureRecord?, calibration: CaptureRecord?, calibrationExpanded: Bool = false) {
        self.record = record
        self.calibration = calibration
        self.calibrationExpanded = calibrationExpanded
        _calibrationOpen = State(initialValue: calibrationExpanded)
    }

    private var observation: Bool { record?.metadata["observation_only"] == "1" }
    private var diagnosis: CalibrationDiagnosis? { calibration.flatMap { CalibrationDiagnosis.forRecord($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DisclosureGroup("What am I seeing?", isExpanded: $interpretationOpen) {
                VStack(alignment: .leading, spacing: 12) {
                    if let record {
                        if observation {
                            Label("Raw observation", systemImage: "waveform.path")
                                .font(.subheadline.weight(.semibold))
                            Text("The waveform was saved without an accepted quiet calibration. The Pico reports candidates using this record's noise estimate. Candidates remain diagnostic, including when the trace looks clean.")
                        } else if record.metadata["usable"] == "1" {
                            Text("The Pico accepted this window under its saved quiet calibration and processing profile. Qualified pulses passed the electrical pulse checks for this record.")
                        } else {
                            Text("The raw data and processing details are available, while this window is unqualified. Read the acquisition and quality flags before comparing its candidate heights.")
                        }
                        if record.metadata["gain_confirmed"] == "0" {
                            Text("Physical gain is unknown. The configured gain value is a software setting and has not been confirmed against J4.")
                                .font(.callout.weight(.medium))
                        }
                        values(record)
                    } else {
                        Text("Use Main to record raw observations or select a saved record to inspect the signal, noise and processing details. Main can collect data while you investigate a rejected calibration. Calibrated Run provides the separately qualified workflow.")
                    }
                    explanation("Baseline", "The signal's estimated resting ADC code. A powered, settled final output is expected near its midpoint. A centered final output can still conceal overload at an earlier amplifier stage.")
                    explanation("Noise and threshold", "RMS describes spread about the estimated baseline. Robust noise uses median absolute deviation and is less influenced by isolated spikes. A candidate crosses the displayed threshold in the selected pulse direction.")
                    explanation("Candidates and qualification", "Candidates are threshold crossings found by the processing rules. Qualified pulses also require matching quiet calibration and clear record and pulse flags. Neither number identifies radiation or calibrated energy.")
                    explanation("Voltage and time", "Nominal millivolts assume a 3.3 V ADC reference. Sample timing is nominal. Waveforms are finite windows with gaps, so their totals do not establish a continuous count rate. With the FDS1010 disconnected, the trace describes electronics and pickup only.")
                    explanation("Clipping, drift and overlap", "A trace near either rail can be overloaded. A moving baseline can indicate settling, light, leakage or interference. Multiple lobes can fail the pulse shape checks. These observations guide checks; they do not establish the physical cause.")
                }.padding(.top, 9)
            }
            DisclosureGroup("Calibration help", isExpanded: $calibrationOpen) {
                VStack(alignment: .leading, spacing: 12) {
                    if let diagnosis {
                        Text(diagnosis.title).font(.subheadline.weight(.semibold))
                        Text(diagnosis.summary)
                        ForEach(diagnosis.reasons, id: \.self) { reason in
                            Label(reason, systemImage: "exclamationmark.circle")
                        }
                        ForEach(diagnosis.checks, id: \.self) { Text($0) }
                    } else {
                        Text("Main records raw observations without quiet calibration. Calibrated Run requires accepted quiet calibration. A rejected attempt is retained so you can inspect its waveform and reported reason.")
                    }
                    explanation("Prepare a quiet setup", "Cover the FDS1010 fully with a dry, opaque, nonconductive enclosure. Let the circuit settle. Keep detector leads short, secure and still, and keep the sensitive input clean and dry.")
                    explanation("Check power and stages", "Use a meter to check approximately 3.3 V at J3.2 against J3.1 GND and approximately 1.65 V at J3.3 VMID. Inspect CSA, GAIN and SHP for overload using the documented diagnostics. Scope ground belongs only on GND.")
                    explanation("Confirm the physical setup", "Remove USB power before moving wires or changing J4. Calibrated Run requires confirmation of actual gain after reconnecting and a matching pulse profile. Main can record with unknown physical gain, which stays explicitly unknown. The app cannot sense a jumper or verify the wiring.")
                    explanation("Understand acceptance", "Supported firmware saves three quiet windows and freezes the largest accepted threshold. Every window must pass acquisition, noise, drift, clipping and excursion checks. A failure clears the attempted calibration. Recording observations does not turn that failure into a success.")
                    explanation("If it keeps failing", "Inspect the saved reason and waveform before retrying. Check darkness, gain, supply, stage outputs and cable motion. A noise spectrum may show repeating components, but it cannot by itself identify their source. Stop and unplug for heating, a collapsed rail or persistent dark overload.")
                }.padding(.top, 9)
            }
        }
        .font(.callout)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: calibrationExpanded) { _, expanded in
            if expanded { calibrationOpen = true }
        }
    }

    private func explanation(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            Text(detail).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func values(_ record: CaptureRecord) -> some View {
        let fields: [(String, String?, String)] = [
            ("Baseline", record.metadata["baseline"], "codes"),
            ("RMS", record.metadata["baseline_rms"], "codes"),
            ("Robust noise", record.metadata["sigma"], "codes"),
            ("Threshold", record.metadata["threshold"], "codes"),
            ("Candidates", record.metadata["candidates"], ""),
            ("Qualified pulses", String(record.events.filter { $0["qualified"] == "1" }.count), "")
        ]
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 10) {
            ForEach(fields.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 3) {
                    Text(fields[index].0).font(.caption)
                    Text(fields[index].1.map { "\($0) \(fields[index].2)" } ?? "Unavailable")
                        .font(.callout.monospacedDigit()).foregroundStyle(.primary)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
