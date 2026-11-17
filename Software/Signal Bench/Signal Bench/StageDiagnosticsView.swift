import SwiftUI

struct StageDiagnosticsView: View {
    @EnvironmentObject private var model: BenchModel
    @State private var confirmWiring = false
    @State private var confirmStart = false
    @State private var setup = "Standard"
    @State private var showStandardWiring = false
    @State private var showDebugWiring = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                availability
                setupControls
                wiring
                BurstCaptureControls(workspace: "Stage Diagnostics")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let stale = model.stageReadingIsStale(at: context.date)
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Stage readings").font(.headline)
                            Spacer()
                            Text(model.stageHistory.isEmpty ? "No readings" : stale ? "Stale" : "Live")
                                .font(.callout.weight(.medium)).foregroundStyle(stale ? Color.secondary : Color.green)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14, alignment: .top)], spacing: 14) {
                            channelCard(0, label: "Final ADC", stale: stale)
                            channelCard(1, label: model.stageDisplayedLabels[0].rawValue, stale: stale)
                            channelCard(2, label: model.stageDisplayedLabels[1].rawValue, stale: stale)
                        }
                    }
                }
                Text("Each sweep reads ADC0, ADC1 and ADC2 in sequence, with settling conversions discarded. Sweeps are requested about twice per second after replies. These are slow trends, not simultaneous waveforms or pulse detection.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Nominal millivolts assume a 3.3 V ADC reference and are uncalibrated. The supply and VMID are not measured unless you actually observe them with a suitable probe or instrument. Floating values cannot establish a connection.")
                    .font(.caption).foregroundStyle(.secondary)
                GroupBox("If a stage is overloaded") {
                    Text("Cover the detector completely and let it settle. Check 3V3 and VMID with a meter, then CSA, GAIN and SHP in order. A final ADC near midpoint does not prove CSA is healthy. Stop and unplug if a rail collapses, a part heats or a dark stage stays near a rail. LOW gain does not prevent the first amplifier overloading in light.")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("History and measurement limits").font(.headline)
                    Text("Only the latest 120 sweeps spanning up to 60 seconds stay in memory. Older sweeps roll off. Stop or disconnect retains the displayed window for an explicit report export; a new Start replaces it. No recording is created automatically.")
                    Text("Stop diagnostics and run a fresh quiet calibration before measurement captures. The selected processing profile is recorded with each waveform. Finite captures have blind gaps and exposure is not a valid count rate denominator. These readings establish neither radiation response nor calibrated energy.")
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Confirm the optional probe wiring?", isPresented: $confirmWiring) {
            Button("Confirm Wiring") { model.confirmStageWiring() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Verify the wires with USB power removed: GP27 pin 32 is \(model.stageLabels[0].rawValue); GP28 pin 34 is \(model.stageLabels[1].rawValue). Disconnected means the wire is physically absent. Keep normal J2 wiring. Reconnect USB only after checking. The app cannot detect wiring.")
        }
        .alert("Start stage diagnostics?", isPresented: $confirmStart) {
            Button("Start Diagnostics", action: model.enterStageDiagnostics)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This clears quiet calibration and replaces the previous live diagnostic window. Export that window first if needed. GP27 and GP28 remain reserved inputs after Stop; no output state is restored.")
        }
        .sheet(isPresented: $showStandardWiring) { DiagnosisWiringHelp(labels: [.disconnected, .disconnected], includeOptional: false) }
        .sheet(isPresented: $showDebugWiring) { DiagnosisWiringHelp(labels: model.stageLabels, includeOptional: true) }
        .onAppear {
            if model.stageLabels == [.disconnected, .disconnected] { setup = "Standard" }
            else if model.stageLabels == [.csa, .gain] { setup = "CSA and GAIN" }
            else if model.stageLabels == [.vmid, .shp] { setup = "VMID and SHP" }
            else { setup = "Custom" }
        }
        .onDisappear { model.exitStageDiagnostics() }
    }

    private var setupControls: some View {
        GroupBox("Wiring setup") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Setup", selection: $setup) {
                    Text("Standard · normal three wires").tag("Standard")
                    Text("CSA and GAIN probes").tag("CSA and GAIN")
                    Text("VMID and SHP probes").tag("VMID and SHP")
                    Text("Custom probes").tag("Custom")
                }.disabled(model.stageActive || model.manualActive || model.busy || model.pendingUnsaved)
                Text(setup == "Standard" ? "Standard uses J2 ground, 3.3 V and final ADC only. Leave GP27 and GP28 disconnected. Confirm the declaration below before Start Diagnostics." : "Choose the probes actually connected. Remove USB before changing wires, then confirm the declaration below. Presets describe wiring and cannot detect it.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Show Standard Wiring") { showStandardWiring = true }
                    Button("Show Selected Debug Wiring") { showDebugWiring = true }
                }
                Text("Normal harness: J2.1 GND → Pico physical 33 AGND; J2.2 3V3 → physical 36 3V3 OUT; J2.3 ADC → physical 31 GP26/ADC0.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: setup) { _, value in
            let labels: [StageProbeLabel]
            switch value {
            case "Standard": labels = [.disconnected, .disconnected]
            case "CSA and GAIN": labels = [.csa, .gain]
            case "VMID and SHP": labels = [.vmid, .shp]
            default: return
            }
            _ = model.setStageLabel(0, label: labels[0]); _ = model.setStageLabel(1, label: labels[1])
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Diagnosis").font(.title2.weight(.semibold))
                    Text("Optional J3 probes · read only").foregroundStyle(.secondary)
                }
                Spacer()
                SetupHelpButton(topic: .stageWiring)
            }
            HStack {
                if model.stageActive {
                    Button(model.stageStopping ? "Stopping" : "Stop Diagnostics", action: model.exitStageDiagnostics)
                        .disabled(model.stageStopping)
                } else {
                    Button("Start Diagnostics") { confirmStart = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.connected || !model.stageSupported || !model.stageWiringConfirmed || model.busy || model.pendingUnsaved || model.manualActive || model.sequenceRunning)
                }
                Button("Export Session Data…") { model.requestExport(.session) }.disabled(!model.canExportFiles || model.currentSession == nil)
                Button("Export Report", systemImage: "square.and.arrow.up", action: model.exportStageReport)
                    .disabled(!model.canExportFiles || model.stageReport == nil || (model.sessionURL == nil && model.appRootURL == nil))
                    .help("Stop first. Export the retained readings and declared wiring to the session or Signal Bench folder.")
            }
        }
    }

    @ViewBuilder private var availability: some View {
        if !model.connected {
            Label("Connect a Pico W. Retained readings are stale.", systemImage: "cable.connector").foregroundStyle(.secondary)
        } else if !model.stageSupported {
            Label("This firmware does not support protected stage diagnostics. Update the paired firmware before attaching optional wires.", systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
        } else if model.pendingUnsaved {
            Label("Save the Pico's pending record before diagnostics.", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
        } else if model.manualActive || model.sequenceRunning {
            Label("Stop Manual mode or the capture sequence first.", systemImage: "pause.circle").foregroundStyle(.secondary)
        } else if model.stageActive {
            Label("Diagnostics owns the ADC. Measurement captures are unavailable until Stop and a new quiet calibration.", systemImage: "info.circle").foregroundStyle(.secondary)
        }
    }

    private var wiring: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Text("Optional probe wiring").font(.headline)
                Text("Normally leave these wires disconnected. Remove USB power before attaching, moving or removing a wire. GP27 and GP28 are reserved inputs in every mode.")
                    .font(.callout).foregroundStyle(.secondary)
                probePicker(0, pin: "GP27 · physical 32", suggestion: "Default: J3.4 CSA")
                probePicker(1, pin: "GP28 · physical 34", suggestion: "Default: J3.5 GAIN")
                Text("Keep J2.1 → 33 AGND, J2.2 → 36 3V3 OUT and J2.3 → 31 GP26. Ground is shared. Other J3 pins remain meter or scope points. Only two optional analog probes are available.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Confirm Wiring") { confirmWiring = true }
                        .disabled(!model.connected || !model.stageSupported || model.stageActive || model.manualActive || model.busy || model.pendingUnsaved)
                    Text(model.stageWiringConfirmed ? "Wiring confirmed by you" : "Wiring confirmation required")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.stageHistory.isEmpty && model.stageDisplayedLabels != model.stageLabels {
                    Text("The retained readings still use the previous run's labels. New selections apply on the next Start.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func probePicker(_ index: Int, pin: String, suggestion: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(pin).font(.callout.weight(.medium))
                Text(suggestion).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Picker("Probe at \(pin)", selection: Binding(get: { model.stageLabels[index] }, set: { model.setStageLabel(index, label: $0) })) {
                ForEach(StageProbeLabel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.labelsHidden().frame(width: 145)
                .disabled(model.stageActive || model.busy)
        }
    }
    private func channelCard(_ channel: Int, label: String, stale: Bool) -> some View {
        let reading = model.stageHistory.last?.channels[channel]
        let disconnected = channel > 0 && label == StageProbeLabel.disconnected.rawValue
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label).font(.headline)
                Spacer()
                Text("GP\(26 + channel) / ADC\(channel)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if disconnected {
                Text("Declared disconnected").font(.callout).foregroundStyle(.secondary)
                Text("No physical connection is inferred from a floating ADC value.").font(.caption).foregroundStyle(.secondary)
            } else if let reading {
                if reading.adcError {
                    Label("ADC error", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if let code = reading.adc {
                    HStack(alignment: .firstTextBaseline) {
                        Text(code.formatted()).font(.system(.title, design: .rounded, weight: .semibold)).monospacedDigit()
                        Text("codes").foregroundStyle(.secondary)
                        Spacer()
                    }
                    Text("Nominal ≈ \(Double(code) * 3300 / 4096, specifier: "%.1f") mV").font(.callout.monospacedDigit())
                    if code <= 50 || code >= 4045 { Text("Near an ADC rail. Check the stage and supply.").font(.caption).foregroundStyle(.orange) }
                }
                Text("Device \(Double(reading.timeUS) / 1_000_000, specifier: "%.3f") s\(stale ? " · stale" : "")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                StageTrend(history: model.stageHistory, channel: channel).frame(height: 110)
            } else {
                Text("No reading").font(.title3).foregroundStyle(.secondary)
                Text("Confirm wiring and Start to request readings.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).frame(maxWidth: .infinity, minHeight: 145, alignment: .topLeading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct StageTrend: View {
    let history: [StageSnapshot]
    let channel: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { context, size in
                let left: CGFloat = 36, width = max(1, size.width - left - 3), height = max(1, size.height - 8)
                func y(_ code: Int) -> CGFloat { 4 + height * (1 - CGFloat(code) / 4095) }
                for code in [0, 2048, 4095] {
                    var path = Path(); path.move(to: .init(x: left, y: y(code))); path.addLine(to: .init(x: left + width, y: y(code)))
                    context.stroke(path, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
                    context.draw(Text("\(code)").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary), at: .init(x: left - 4, y: y(code)), anchor: .trailing)
                }
                guard let first = history.first?.channels[channel], let last = history.last?.channels[channel], last.timeUS >= first.timeUS else { return }
                let span = max(1, last.timeUS - first.timeUS)
                var dots = Path()
                for snapshot in history {
                    let value = snapshot.channels[channel]
                    guard let code = value.adc, !value.adcError, value.timeUS >= first.timeUS else { continue }
                    let x = left + width * CGFloat(Double(value.timeUS - first.timeUS) / Double(span))
                    dots.addEllipse(in: .init(x: x - 1.8, y: y(code) - 1.8, width: 3.6, height: 3.6))
                }
                context.fill(dots, with: .color(.accentColor))
            }.accessibilityLabel("Raw ADC codes over device time. Individually requested readings.")
            if let first = history.first?.channels[channel], let last = history.last?.channels[channel] {
                Text("\(Double(first.timeUS) / 1_000_000, specifier: "%.1f") to \(Double(last.timeUS) / 1_000_000, specifier: "%.1f") s · device time")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}
