import SwiftUI

struct MainPulseControls: View {
    @Binding var options: MainObservationOptions
    @State private var showCriteria = false
    @State private var showNoiseProcedure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Detector setup", selection: $options.condition) {
                Text(MainDetectorCondition.unspecified.label).tag(MainDetectorCondition.unspecified)
                Text(MainDetectorCondition.disconnected.label).tag(MainDetectorCondition.disconnected)
                Text(MainDetectorCondition.connectedDark.label).tag(MainDetectorCondition.connectedDark)
            }
            .frame(maxWidth: 355, alignment: .leading)
            DisclosureGroup("Pulse criteria", isExpanded: $showCriteria) {
                MainPulseCriteriaEditor(criteria: $options.criteria).padding(.top, 8)
            }
            DisclosureGroup("Compare noise with and without the detector", isExpanded: $showNoiseProcedure) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("1. Unplug USB, disconnect the detector at J1 and leave the three Pico wires in place. After reconnecting USB and letting the signal settle, choose Detector disconnected.")
                    Text("2. Save a 5 minute Background run. Keep the gain, cable and probe setup the same for both runs.")
                    Text("3. Unplug USB before reconnecting the detector. Cover it from light, reconnect USB, let it settle, then choose Detector connected in darkness and save another Background run.")
                    Text("4. Open Review Noise Runs. Compare noise and baseline drift first, then apply the same pulse criteria to both runs. If the baseline changes over time, repeat the disconnected run.")
                }
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MainPulseCriteriaEditor: View {
    @Binding var criteria: MainPulseCriteria

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Picker("Threshold", selection: $criteria.thresholdMode) {
                Text("Adaptive").tag(MainPulseCriteria.ThresholdMode.adaptive)
                Text("Fixed").tag(MainPulseCriteria.ThresholdMode.fixed)
            }.pickerStyle(.segmented).frame(maxWidth: 330)
            HStack {
                Text(criteria.thresholdMode == .adaptive ? "Minimum threshold" : "Fixed threshold")
                Spacer(minLength: 8)
                TextField("ADC codes", value: $criteria.minimumCodes, format: .number.grouping(.never))
                    .labelsHidden().accessibilityLabel("Threshold in ADC codes").multilineTextAlignment(.trailing).frame(width: 60)
                Text("ADC codes").foregroundStyle(.secondary)
            }
            if criteria.thresholdMode == .adaptive {
                HStack {
                    Text("Noise multiplier")
                    Spacer(minLength: 8)
                    TextField("Noise multiplier", value: $criteria.sigmaMultiplier,
                              format: .number.precision(.fractionLength(0...2)))
                        .labelsHidden().multilineTextAlignment(.trailing).frame(width: 60)
                    Text("× noise").foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("Minimum time above threshold")
                Spacer(minLength: 8)
                TextField("Samples", value: $criteria.minimumSamples, format: .number.grouping(.never))
                    .labelsHidden().accessibilityLabel("Minimum samples above threshold").multilineTextAlignment(.trailing).frame(width: 60)
                Text("samples").foregroundStyle(.secondary)
            }
            if criteria.isValid {
                Text(criteria.thresholdMode == .adaptive
                     ? "Uses the higher of the minimum threshold and the measured window noise multiplied by your setting. Each sample is nominally 10 µs."
                     : "Uses the same threshold in every window. Noise can create matches. Each sample is nominally 10 µs.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Enter 1 to 4,095 ADC codes, a noise multiplier of 3 to 30, and 1 to 1,000 samples.")
                    .foregroundStyle(.orange)
            }
            Button("Restore Default Criteria") { criteria = MainPulseCriteria() }
        }
        .font(.callout)
        .frame(maxWidth: 405, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
