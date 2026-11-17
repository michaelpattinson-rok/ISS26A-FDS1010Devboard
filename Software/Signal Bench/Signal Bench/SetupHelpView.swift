import SwiftUI

enum SetupHelpTopic: String, CaseIterable, Identifiable {
    case wiring, diagnostics, gain, detector, baseline, stageWiring
    var id: String { rawValue }

    var title: String {
        switch self {
        case .wiring: "Connect the Pico W"
        case .diagnostics: "Measure at J3"
        case .gain: "Set the J4 jumper"
        case .detector: "Connect and cover the sensor"
        case .baseline: "Prepare a quiet baseline"
        case .stageWiring: "Connect optional J3 probes"
        }
    }
    var buttonTitle: String {
        switch self {
        case .wiring: "Wiring images"
        case .diagnostics: "J3 probe guide"
        case .gain: "J4 gain images"
        case .detector: "Sensor images"
        case .baseline: "Calibration guide"
        case .stageWiring: "Wiring images"
        }
    }
    var summary: String {
        switch self {
        case .wiring: "Three wires connect the Devboard to the original Pico W. Numbers below are physical header pins."
        case .diagnostics: "J3 exposes the supply, midpoint and amplifier outputs for a meter or scope. Optional stage diagnostics can read two selected points with the protected paired firmware."
        case .gain: "LOW leaves J4 open. HIGH fits a shunt across both pins. The app records your confirmation and cannot move or sense the jumper."
        case .detector: "Fit the FDS1010 at J1 after the electrical checks. Keep its surface protected and exclude room light."
        case .baseline: "A quiet capture sets a noise threshold. It does not calibrate charge, energy or radiation response."
        case .stageWiring: "Keep the normal J2 harness. Two optional wires let protected stage diagnostics read selected J3 points sequentially. They are normally disconnected."
        }
    }
    var instructions: [(String, String)] {
        switch self {
        case .stageWiring:
            [("Check the firmware first", "Stage Diagnostics must report support from the paired firmware before attaching optional probes. Older Manual firmware could drive GP27 and GP28. Updated firmware reserves both as inputs in all modes."),
             ("Remove USB power", "Leave J2.1 GND → Pico 33 AGND, J2.2 3V3 → 36 3V3 OUT and J2.3 ADC → 31 GP26 unchanged. The existing ground is shared."),
             ("Default optional wires", "J3.4 CSA → physical 32 GP27/ADC1. J3.5 GAIN → physical 34 GP28/ADC2. Each probe may instead connect to VMID, CSA, GAIN or SHP, with the matching source label. Do not connect the 3V3 supply to these optional probes."),
             ("Declare what is wired", "Disconnected means no wire. After checking with power removed, reconnect USB, select each actual source and choose Confirm Wiring. The app cannot sense wiring. Only two additional analog points can be read at once; the remaining J3 points stay available for meter or scope use."),
             ("Read and finish", "Start Diagnostics reads the three ADC channels in sequence. Stop retains the latest window for explicit report export. Remove USB before moving probes. A fresh quiet calibration is required before measurement captures; no previous GPIO outputs are restored.")]
        case .wiring:
            [("Remove power", "Unplug USB before connecting wires or moving J4. Support the PCB on an insulating base so solder joints cannot touch metal or a shielding bag."),
             ("Match all three wires", "J2.1 GND → Pico 33 AGND. J2.2 3V3 → Pico 36 3V3 OUT. J2.3 ADC → Pico 31 GP26 / ADC0. Use the regulated 3.3 V output; never VBUS, VSYS or 5 V."),
             ("First power check", "Leave the detector and fixture disconnected until supply, midpoint and stage outputs have been checked. A USB connection alone does not verify the board wiring.")]
        case .diagnostics:
            [("Find the reference", "Component side toward you and title upright: J3 runs left to right, GND, 3V3, VMID, CSA, GAIN, SHP. Attach clips with USB unplugged."),
             ("Use DC voltage", "Meter black lead in COM, red lead in V. Keep black on J3.1 GND and probe one pin at a time. Never use current mode across these pins or bridge adjacent pins."),
             ("Check in order", "Expect about 3.3 V at pin 2, half the supply at pin 3, and normally near VMID at pins 4, 5 and 6 after settling in darkness. These are starting expectations, not measured acceptance limits."),
             ("If using a scope", "Use a compensated 10× probe, matching channel setting, DC coupling and 1 MΩ input. Ground only to GND, never VMID or SUM. Keep protective earth connected. Do not probe SUM with an ordinary probe."),
             ("Stop if abnormal", "Unplug if the supply collapses, a part heats noticeably or a dark stage stays at a rail. The final ADC can return to midpoint while the first amplifier remains overloaded.")]
        case .gain:
            [("Unplug USB first", "Set J4 by hand while power is removed. Open selects LOW. A fitted shunt across both pins selects HIGH. A socket housing alone is not a shunt."),
             ("Reconnect and confirm", "Reconnect USB, connect the Pico, select the matching position and choose Confirm Gain. Confirm again after a Pico restart."),
             ("Calibrate again", "Changing the confirmed gain invalidates calibration. Run a new quiet calibration before capturing. LOW changes a later stage and does not prevent the first amplifier overloading in room light.")]
        case .detector:
            [("Power off to connect", "J1.1 VMID → FDS1010 anode, manufacturer pin 1 / red lead. J1.2 SUM → cathode, pin 2. Neither lead goes to ground. Never connect the detector and electrical fixture together."),
             ("Protect the detector", "Use the manufacturer specified ESD wrist strap and static controlled workstation. Support the ceramic package without pressing on its active surface. Do not pull its leads or put adhesive on the surface."),
             ("Make it dark", "Use an opaque enclosure with an insulating interior and strain relief. Block seams and cable holes. Keep foil, metal and shielding bags clear of exposed contacts. Room light can overload the sensitive input."),
             ("Match your actual connector", "These renders show the ordered male header. An earlier marked guide says Use Female at J1. Check the fitted connector, labels and mating harness before connecting; the drawing does not establish your assembled connector.")]
        case .baseline:
            [("Check hardware first", "With the detector dark, check supply, VMID and each J3 output. Exit Manual mode. Open a session so the calibration record can be saved, then confirm the actual J4 position."),
             ("Capture quiet calibration", "Exit Stage Diagnostics as well as Manual mode. Keep light, cable position and gain stable. Choose Calibrate. If rejected, inspect the record and flags before retrying; a rejected attempt must not be treated as accepted."),
             ("Save a background record", "After accepted calibration, capture Background. Wait for transfer and saving to finish. Inspect the raw waveform and flags. Keep the Pico powered if a record is still awaiting saving."),
             ("Pulse profile", "With supported firmware, choose the negative detector profile for the expected Devboard main pulse or the positive electrical test profile for the matching test signal. Raw samples preserve their original orientation. Recalibrate after changing the profile. Older firmware selects positive excursions only."),
             ("Measurement limits", "Captures are finite and have blind gaps. Their exposure is not an unbiased count rate denominator. A qualified pulse or optical response does not establish radiation, dose, energy or efficiency.")]
        }
    }
    var figures: [SetupHelpFigure] {
        switch self {
        case .stageWiring: [.init(asset: "StageJ3Numbered", caption: "J3 component side with all six physical pin numbers. Documentation render."), .init(asset: "StagePicoWiring", caption: "Original Pico W photograph with normal and optional physical pin numbers. Verify orientation before wiring.")]
        case .wiring: [.init(asset: "SetupWiringBoard", caption: "Devboard J2 location and connector order. Documentation render."), .init(asset: "SetupPicoPhoto", caption: "Original Pico W photograph. Physical pins 33, 36 and 31; USB orientation is shown.")]
        case .diagnostics: [.init(asset: "StageJ3Numbered", caption: "J3 diagnostics on the component side with numbered pins. Documentation render.")]
        case .gain: [.init(asset: "SetupGainLow", caption: "LOW: J4 open, with no shunt bridging its two pins. Documentation render."), .init(asset: "SetupGainHigh", caption: "HIGH: removable shunt bridges both J4 pins. Documentation render.")]
        case .detector: [.init(asset: "SetupDetectorBoard", caption: "J1 detector connection. Ordered header shown; verify your fitted connector. Documentation render.")]
        case .baseline: [.init(asset: "SetupDetectorBoard", caption: "Connect and cover the detector before a quiet baseline. Documentation render."), .init(asset: "SetupDiagnosticBoard", caption: "Check the first amplifier at CSA as well as the final output. Documentation render.")]
        }
    }
}

struct SetupHelpFigure: Identifiable {
    let asset: String
    let caption: String
    var id: String { asset }
}

/// This is the only setup surface that loads detailed rendered board images.
/// Opening help does not communicate with the device or change configuration.
struct SetupHelpContent: View {
    let topic: SetupHelpTopic
    var onClose: () -> Void = { }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(topic.title).font(.title2.weight(.semibold))
                    Text("Original Pico W · Devboard E.1").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(topic.summary).font(.body).fixedSize(horizontal: false, vertical: true)
                    Label("Remove USB power before rewiring or moving J4.", systemImage: "powerplug")
                        .font(.callout.weight(.medium))
                    ForEach(topic.figures) { figure in
                        VStack(alignment: .leading, spacing: 8) {
                            Image(figure.asset).resizable().scaledToFit()
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel(figure.caption)
                            Text(figure.caption).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(topic.instructions, id: \.0) { heading, body in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(heading).font(.headline)
                            Text(body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                    Text("Renders explain the intended hardware. They do not verify your assembly, voltages or detector response.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct SetupHelpButton: View {
    let topic: SetupHelpTopic
    @State private var showingHelp = false

    var body: some View {
        Button { showingHelp = true } label: {
            Label(topic.buttonTitle, systemImage: "info.circle")
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.borderless)
        .help("Show \(topic.title.lowercased()) instructions and rendered images")
        .accessibilityLabel(topic.buttonTitle)
        .accessibilityHint("Opens illustrated instructions. Does not change the board or device settings.")
        .popover(isPresented: $showingHelp, arrowEdge: .trailing) {
            SetupHelpContent(topic: topic, onClose: { showingHelp = false })
                .frame(width: 560, height: 620)
        }
    }
}
