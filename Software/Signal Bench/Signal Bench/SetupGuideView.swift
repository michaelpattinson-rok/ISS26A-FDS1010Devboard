import SwiftUI

/// A guided checklist. The electrical checks are operator confirmations, not
/// measurements made by the app. Nothing in this view changes the board wiring.
struct SetupGuideView: View {
    @EnvironmentObject private var model: BenchModel
    @Environment(\.dismiss) private var dismiss
    @State private var wiringChecked = false
    @State private var voltagesChecked = false
    @State private var detectorReady = false
    @State private var gain = "LOW"
    @State private var showGainConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Set up your Pico W").font(.title2.weight(.semibold))
                    Text("Work through these checks before your first capture.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", action: { dismiss() }).keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let error = model.error {
                        HStack(alignment: .top) {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange).textSelection(.enabled)
                            Spacer()
                            Button("Dismiss") { model.error = nil }
                        }
                    }
                    step("1", "Check the wiring", subtitle: "Disconnect USB power before wiring or moving J4.", topic: .wiring) {
                        Text("Use the three J2 connections shown. Pico numbers are physical header pins, not GPIO numbers.")
                        Text("Use only 3.3 V. Inspect connectors and joints, then place the board on an insulating support. Leave the detector and fixture disconnected for the first power check.")
                            .foregroundStyle(.secondary)
                        Toggle("I checked the wiring with power removed", isOn: $wiringChecked)
                    }
                    step("2", "Connect and choose a project", subtitle: "You can test USB with the Pico alone. Captures are saved inside a project.") {
                        VStack(alignment: .leading, spacing: 10) {
                            Label { Text(model.currentSession?.name ?? "No project open").lineLimit(2) } icon: { Image(systemName: model.currentSession == nil ? "folder" : "checkmark.circle.fill") }
                            HStack {
                                Button("New Project", action: model.createSession).disabled(!model.canCreateProject)
                                Button("Open Project", action: model.openSession).disabled(!model.canOpenProject)
                            }
                        }
                        Divider()
                        HStack {
                            if model.connected {
                                Label(model.deviceInfo, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                                Spacer()
                                Button("Disconnect", action: model.disconnect).disabled(model.busy)
                            } else {
                                Picker("Pico port", selection: $model.selectedPort) {
                                    Text("Select a device").tag("")
                                    ForEach(model.ports, id: \.self) { Text($0).tag($0) }
                                }.labelsHidden()
                                Button("Refresh", action: model.refreshPorts)
                                Button("Connect", action: model.connect)
                                    .disabled(model.selectedPort.isEmpty || model.busy)
                            }
                        }
                        Text(model.connectionStatus).font(.caption).foregroundStyle(.secondary)
                        if model.pendingUnsaved {
                            Label("The Pico has a record awaiting recovery. Close this guide and select its original project before retrying.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                    step("3", "Check the voltages", subtitle: "Measure with the detector and fixture still disconnected.", topic: .diagnostics) {
                        Text("Use J3.1 GND as the reference. Expect about 3.3 V at J3.2, half the supply at J3.3 VMID, and normally near VMID at CSA, GAIN and SHP after settling. Probe ground belongs only on GND.")
                        Text("These are expected values. The app cannot verify your meter or scope readings. If the rails collapse, a part heats, or the outputs sit at a rail, unplug and investigate before continuing.")
                            .foregroundStyle(.secondary)
                        Toggle("I checked the rail, midpoint and outputs", isOn: $voltagesChecked)
                            .disabled(!model.connected)
                    }
                    step("4", "Confirm the J4 jumper", subtitle: "Set by hand with USB removed. Confirm again after a Pico restart.", topic: .gain) {
                        HStack {
                            Picker("J4 position", selection: $gain) {
                                Text("Low · open").tag("LOW")
                                Text("High · shunt").tag("HIGH")
                            }.labelsHidden().pickerStyle(.segmented).frame(width: 205)
                                .disabled(model.busy || model.pendingUnsaved || model.manualActive || model.stageActive || model.sequenceRunning)
                            Button("Confirm Gain") { showGainConfirmation = true }
                                .disabled(!wiringChecked || !voltagesChecked || !model.connected || model.busy || model.pendingUnsaved || model.manualActive || model.stageActive || model.sequenceRunning)
                            Spacer()
                        }
                        Text(model.gainConfirmed ? "Recorded gain: \(model.gain.capitalized)" : "Gain not yet confirmed")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("The app records your selection; it cannot sense or move the jumper. After changing gain, reconnect power and calibrate again.")
                            .foregroundStyle(.secondary)
                    }
                    step("5", "Prepare a quiet calibration", subtitle: "Connect the detector with USB removed, then exclude room light.", topic: .detector) {
                        Text("After the electrical checks, unplug USB and attach the detector at J1: anode / red to VMID, cathode to SUM. Neither lead goes to ground. Keep the detector protected, dry and completely dark. Never fit a detector and fixture together. Reconnect USB, connect in step 2 and confirm J4 again.")
                        Toggle("The wiring is ready and any detector is dark", isOn: $detectorReady)
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Capture Quiet Calibration", action: model.calibrate)
                                .buttonStyle(.borderedProminent)
                                .disabled(!wiringChecked || !voltagesChecked || !detectorReady || !model.connected || !model.gainConfirmed || model.gain != gain || model.currentSession == nil || model.busy || model.pendingUnsaved || model.manualActive || model.stageActive || model.sequenceRunning)
                            Text(model.calibrated ? "Quiet calibration accepted" : "Required for Calibrated Run")
                                .font(.callout).foregroundStyle(model.calibrated ? Color.green : Color.secondary)
                            SetupHelpButton(topic: .baseline).font(.callout)
                        }
                        Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("Main on firmware 1.5 can save raw observations without this step. Quiet calibration sets a noise threshold for the chosen pulse profile. Supported firmware provides a negative detector profile and a positive electrical test profile. Inspect the raw waveform and quality flags. Radiation response, energy and a valid count rate require separate validation.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.stageActive {
                        Label("Close this guide and Stop Diagnostics before calibration.", systemImage: "pause.circle").font(.callout)
                    }
                    if model.manualActive {
                        Label("Close this guide and choose Release Outputs and Stop in Manual before returning to setup.", systemImage: "switch.2").font(.callout)
                    }
                }.padding(24)
            }
        }
        .frame(minWidth: 620, idealWidth: 940, minHeight: 560, idealHeight: 760)
        .onAppear { gain = model.gain; model.refreshPorts() }
        .alert("Confirm physical gain?", isPresented: $showGainConfirmation) {
            Button("Confirm \(gain.capitalized)") { model.changeGain(gain) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Confirm J4 was set with power removed. Open is low and a fitted shunt is high. The app cannot move or verify the jumper.")
        }
    }

    private func step<Content: View>(_ number: String, _ title: String, subtitle: String, topic: SetupHelpTopic? = nil,
                                      @ViewBuilder content: @escaping () -> Content) -> some View {
        HStack(alignment: .top, spacing: 15) {
            Text(number).font(.callout.weight(.semibold)).foregroundStyle(.tint)
                .frame(width: 26, height: 26).background(Color.accentColor.opacity(0.1), in: Circle())
            Group {
                if let topic {
                    SetupHelpLayout(topic: topic, gain: gain) {
                        stepContent(title, subtitle: subtitle, content: content)
                    }
                } else {
                    stepContent(title, subtitle: subtitle, content: content)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stepContent<Content: View>(_ title: String, subtitle: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            content()
        }
    }
}
