import SwiftUI

struct DiagnosisWiringHelp: View {
    let labels: [StageProbeLabel]
    let includeOptional: Bool
    var acquisitionBoard: AcquisitionBoard = .picoW
    @Environment(\.dismiss) private var dismiss
    private func boardPin(_ label: StageProbeLabel) -> String {
        switch label {
        case .disconnected: return "Leave this input unwired"
        case .vmid: return "J3.3 VMID"
        case .csa: return "J3.4 CSA"
        case .gain: return "J3.5 GAIN"
        case .shp: return "J3.6 SHP"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(includeOptional ? "Selected debug wiring" : "Standard wiring").font(.title2.weight(.semibold))
                Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Remove USB and external power before changing any wire.")
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                        GridRow { Text("Devboard").bold(); Text(acquisitionBoard.title).bold() }
                        GridRow { Text("J2.1 GND"); Text(acquisitionBoard == .picoW ? "Physical 33 AGND" : "GND and 3.3 V supply return") }
                        GridRow { Text("J2.2 3V3"); Text(acquisitionBoard == .picoW ? "Physical 36 3V3 OUT" : "Regulated 3.3 V supply") }
                        GridRow { Text("J2.3 ADC"); Text(acquisitionBoard == .picoW ? "Physical 31 GP26 / ADC0" : "A0") }
                        if includeOptional {
                            GridRow { Text(boardPin(labels[0])); Text(acquisitionBoard == .picoW ? "Physical 32 GP27 / ADC1" : "A1") }
                            GridRow { Text(boardPin(labels[1])); Text(acquisitionBoard == .picoW ? "Physical 34 GP28 / ADC2" : "A2") }
                        }
                    }.font(.callout).textSelection(.enabled)
                    Text(includeOptional ? "The selected sources above describe the declared setup. Ground is shared through J2.1. Other J3 pins remain meter or scope points. Confirm the actual wires before starting." : "Standard uses only the three J2 wires. The optional inputs stay disconnected. The FDS1010 can remain disconnected for an electronics and USB check.")
                        .font(.callout).foregroundStyle(.secondary)
                    Image(includeOptional ? "StageJ3Numbered" : "SetupWiringBoard").resizable().scaledToFit()
                    Text(includeOptional ? "Numbered J3 diagnostics header on the documented board render. Match the selected J3 pin numbers listed above." : "Documented Devboard render identifying the normal J2 connection.").font(.caption).foregroundStyle(.secondary)
                    if includeOptional && acquisitionBoard == .picoW {
                        Text("The annotated Pico photograph shows the default CSA and GAIN probe labels. GP27 and GP28 keep the same physical positions for VMID or SHP. Use the selected source table above for the chosen J3 pins.")
                            .font(.callout)
                    }
                    Image(acquisitionBoard == .unoR4 ? "UnoWiring" : includeOptional ? "StagePicoWiring" : "SetupPicoPhoto").resizable().scaledToFit()
                    Text("Use 3.3 V only. Keep oscilloscope ground on GND. Analog probe pins remain inputs. Labels and floating ADC values cannot establish that a wire is connected.")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(20)
            }
        }.frame(minWidth: 500, idealWidth: 640, minHeight: 520, idealHeight: 740)
    }
}
