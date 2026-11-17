import SwiftUI

struct ManualBenchView: View {
    @EnvironmentObject private var model: BenchModel
    @State private var requestedPin: Int?
    @State private var requestedAction = ""
    @State private var recordMonitor = false
    @State private var monitorUntilStopped = true
    @State private var monitorCustomSeconds = "300"
    // Raspberry Pi Pico W pinout: physical 40-pin header numbering.
    private let physicalPins = [0: 1, 1: 2, 2: 4, 3: 5, 4: 6, 5: 7, 6: 9, 7: 10, 8: 11, 9: 12, 10: 14, 11: 15, 12: 16, 13: 17, 14: 19, 16: 21, 17: 22, 18: 24, 19: 25, 20: 26, 21: 27, 22: 29, 27: 32, 28: 34]

    private var shouldRecordMonitor: Bool { recordMonitor && model.currentSession != nil }
    private var monitorDuration: Double? {
        if monitorUntilStopped { return ManualCSVRecording.durationRange.upperBound }
        guard let seconds = Double(monitorCustomSeconds), ManualCSVRecording.durationRange.contains(seconds) else { return nil }
        return seconds
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Manual").font(.title2.weight(.semibold))
                        Text("Inspect GP26 and control available Pico pins.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.manualActive {
                        Button(model.manualStopping ? "Stopping" : "Release Outputs and Stop", action: model.exitManual)
                            .disabled(model.manualStopping)
                    } else {
                        Button("Start Manual Mode") {
                            if shouldRecordMonitor {
                                if let monitorDuration { model.enterManual(recordCSV: true, durationSeconds: monitorDuration) }
                            } else { model.enterManual() }
                        }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.connected || !model.manualSupported || model.busy || model.pendingUnsaved ||
                                      model.sequenceRunning || model.stageActive || model.manualCSVBusy ||
                                      (shouldRecordMonitor && monitorDuration == nil))
                    }
                }
                if !model.connected {
                    Label("Connect a Pico W to begin.", systemImage: "cable.connector")
                        .foregroundStyle(.secondary)
                } else if !model.manualSupported {
                    Label("This firmware does not support Manual mode.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                } else if model.pendingUnsaved {
                    Label("Save the pending capture before starting Manual mode.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                } else if !model.manualActive {
                    Text("Starting Manual mode clears the current calibration. Available pins begin as inputs without pulls.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                monitorRecording
                rateControls
                monitor
                BurstCaptureControls(workspace: "Manual")
                pinSection
                Text("GP26 is reserved for the Devboard input. GP27 and GP28 are reserved inputs for optional J3 diagnostics and cannot be driven in Manual mode. GP15 and Pico W internal pins are unavailable. Remove power before rewiring or changing the gain jumper.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Drive GP\(requestedPin ?? 0) \(requestedAction.lowercased())?", isPresented: Binding(
            get: { requestedPin != nil }, set: { if !$0 { requestedPin = nil } }
        )) {
            Button("Drive \(requestedAction.capitalized)") {
                if let pin = requestedPin { model.setManualPin(pin, action: requestedAction) }
                requestedPin = nil
            }
            Button("Cancel", role: .cancel) { requestedPin = nil }
        } message: {
            Text("Check the connected circuit first. The Pico uses 3.3 V logic. An output can damage a circuit or Pico if connected incorrectly.")
        }
        .task(id: model.currentSession?.id) { model.refreshManualCSVReports() }
        .onChange(of: model.currentSession?.id) { _, _ in recordMonitor = false }
        .onDisappear { model.exitManual() }
    }

    private var monitorRecording: some View {
        VStack(alignment: .leading, spacing: 7) {
            if model.manualCSVActive {
                Label("Recording Monitor CSV", systemImage: "record.circle")
                    .foregroundStyle(.red)
                if let deadline = model.manualCSVDeadline {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let remaining = max(.zero, ContinuousClock.now.duration(to: deadline))
                        Text("\(remaining.formatted(.time(pattern: .hourMinuteSecond))) until automatic stop")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            } else {
                Toggle("Record Live Readings", isOn: $recordMonitor)
                    .disabled(model.manualActive || model.busy || model.manualCSVBusy || model.currentSession == nil)
                if shouldRecordMonitor {
                    ManualMonitorDurationControls(untilStopped: $monitorUntilStopped, customSeconds: $monitorCustomSeconds)
                        .disabled(model.manualActive || model.busy || model.manualCSVBusy)
                }
            }
            if model.currentSession == nil {
                Text("Open a project to record and export monitor readings. Live monitoring is available without a project.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !shouldRecordMonitor && !model.manualCSVActive {
                Text("Enable recording before starting Manual mode.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.manualCSVReports.isEmpty {
                Menu("Export Monitor CSV…") {
                    ForEach(model.manualCSVReports) { report in
                        Button(report.title) { model.exportManualCSV(report.id) }
                    }
                }
                .disabled(model.manualCSVBusy || !model.canExportFiles)
                .help("Save a monitor CSV to the current project’s Exports folder.")
            }
            if model.manualCSVExporting {
                Button("Cancel Monitor Export", action: model.cancelManualCSVExport)
            }
            if let status = model.manualCSVStatus, model.currentSession != nil {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var rateControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Manual sampling rate").font(.headline)
                Spacer()
                Text(model.selectedManualRate.title).font(.callout.monospacedDigit().weight(.medium))
            }
            Slider(value: Binding(get: { Double(model.manualRateIndex) }, set: { value in
                guard value.isFinite else { return }
                model.setManualRateIndex(Int(value.rounded()))
            }), in: 0...Double(ManualRateOption.choices.count - 1), step: 1)
                .disabled(model.manualActive || model.busy)
                .accessibilityLabel("Requested manual reading rate")
                .accessibilityValue(model.selectedManualRate.title)
                .help("Choose before starting. Fastest requests the next reading after each reply.")
            HStack {
                Text("1 reading/s")
                Spacer()
                Text("Fastest")
            }.font(.caption).foregroundStyle(.secondary)
            Text(model.manualActive ? "Stop Manual mode to change the rate." : "Choose a rate before Start. Fastest follows the available USB response rate.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Requested rates are targets. Each request asks for one ADC reading; this is not continuous waveform capture.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var monitor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("GP26 voltage monitor").font(.headline)
                Spacer()
                if model.manualActive { Text("Live").font(.caption.weight(.medium)).foregroundStyle(.green) }
            }
            if let sample = model.manualSnapshot, let adc = sample.adc, !sample.adcError {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(adc)").font(.system(.largeTitle, design: .rounded, weight: .semibold)).monospacedDigit()
                    Text("ADC codes").foregroundStyle(.secondary)
                    Spacer()
                    Text("≈ \(Int((Double(adc) * 3300 / 4096).rounded())) mV")
                        .font(.title3.monospacedDigit())
                }
                Text("Voltage estimate assumes a 3.3 V reference and is not calibrated.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(model.manualSnapshot?.adcError == true ? "ADC reading unavailable" : "No reading")
                    .font(.title3).foregroundStyle(.secondary)
            }
            ManualHistoryGraph(samples: model.manualHistory)
                .frame(height: 125)
                .accessibilityLabel("Recent individually requested ADC readings")
            if let first = model.manualHistory.first, let last = model.manualHistory.last {
                Text("\(model.manualHistory.count) readings · device time \(Double(first.timeUS) / 1_000_000, specifier: "%.1f") to \(Double(last.timeUS) / 1_000_000, specifier: "%.1f") seconds")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Received \(model.manualTotalReadings.formatted())")
                Spacer()
                Text("ADC errors \(model.manualADCErrorReadings.formatted())")
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if let rate = model.manualObservedRateHz {
                Text("Recent device response rate ≈ \(rate, specifier: "%.1f") readings/s")
                    .font(.callout.monospacedDigit())
                Text("Estimated from device response timestamps, not exact ADC sample timing.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Received rate unavailable until timestamps advance.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("The graph shows up to 60 seconds and \(BenchModel.manualHistoryLimit.formatted()) recent readings. An enabled recording keeps all received readings on disk until you stop.")
                .font(.caption).foregroundStyle(.secondary)
            Text("An unconnected GP26 can float. Gaps between readings can miss short pulses, even at Fastest.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var pinSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("GPIO").font(.headline)
                Spacer()
                Text(model.manualActive ? "Inputs have no pulls" : "Unavailable").font(.caption).foregroundStyle(.secondary)
            }
            Text("Observed level is a sampled digital input. Unconnected inputs can float and change state. Output shows the requested latch value, not a voltage measurement.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(BenchModel.manualPins, id: \.self) { pin in
                pinRow(pin)
                if pin != BenchModel.manualPins.last { Divider() }
            }
        }
    }

    private func pinRow(_ pin: Int) -> some View {
        let bit = UInt32(1) << pin
        let snapshot = model.manualSnapshot
        let output = snapshot.map { $0.directions & bit != 0 } ?? false
        let level = snapshot.map { $0.levels & bit != 0 }
        let latch = snapshot.map { $0.outputs & bit != 0 }
        return HStack(spacing: 8) {
            Text("GP\(pin)").font(.body.monospaced().weight(.medium)).frame(width: 45, alignment: .leading)
            Text("Pin \(physicalPins[pin] ?? 0)").font(.callout).frame(width: 44, alignment: .leading).foregroundStyle(.secondary)
            Text(snapshot == nil ? "Unknown" : output ? "Output" : "Input")
                .frame(width: 54, alignment: .leading).foregroundStyle(.secondary)
            Text(level.map { $0 ? "High" : "Low" } ?? "Unknown")
                .font(.callout.monospacedDigit()).frame(width: 54, alignment: .leading)
                .accessibilityLabel("Observed level \(level.map { $0 ? "high" : "low" } ?? "unknown")")
            Text(output ? (latch == true ? "Latch high" : "Latch low") : "No output")
                .font(.callout).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Spacer(minLength: 0)
            Button("Input") { model.setManualPin(pin, action: "INPUT") }
            Button("Low") { requestedAction = "LOW"; requestedPin = pin }
            Button("High") { requestedAction = "HIGH"; requestedPin = pin }
        }
        .controlSize(.small)
        .disabled(!model.manualActive || model.manualSnapshot == nil || model.busy || model.manualPinPending || model.manualStopping)
    }
}

struct ManualMonitorDurationControls: View {
    @Binding var untilStopped: Bool
    @Binding var customSeconds: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Recording duration").font(.callout.weight(.medium))
            Picker("Recording duration", selection: $untilStopped) {
                Text("Until Stopped").tag(true)
                Text("Custom").tag(false)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
            if untilStopped {
                Text("Release outputs to stop. Recording stops automatically after 2 hours.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    TextField("Seconds", text: $customSeconds)
                        .frame(width: 78)
                        .accessibilityLabel("Monitor recording duration in seconds")
                    Text("seconds").font(.callout).foregroundStyle(.secondary)
                }
                Text("Enter 1 to 7,200 seconds. Signal Bench requests output release at the time limit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ManualHistoryGraph: View {
    let samples: [ManualSnapshot]

    var body: some View {
        Canvas { context, size in
            let left: CGFloat = 42
            let width = max(size.width - left - 3, 1)
            let height = max(size.height - 12, 1)
            func y(_ code: Int) -> CGFloat { 6 + height * (1 - CGFloat(code) / 4095) }
            for code in [0, 2048, 4095] {
                var line = Path()
                line.move(to: CGPoint(x: left, y: y(code)))
                line.addLine(to: CGPoint(x: left + width, y: y(code)))
                context.stroke(line, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
                context.draw(Text("\(code)").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: left - 6, y: y(code)), anchor: .trailing)
            }
            guard let first = samples.first, let last = samples.last, last.timeUS >= first.timeUS else { return }
            let span = max(last.timeUS - first.timeUS, 1)
            let columns = max(1, min(2048, Int(width.rounded(.down))))
            var lows = Array(repeating: 4096, count: columns)
            var highs = Array(repeating: -1, count: columns)
            for sample in samples {
                guard let adc = sample.adc, !sample.adcError, sample.timeUS >= first.timeUS else { continue }
                let fraction = min(1, Double(sample.timeUS - first.timeUS) / Double(span))
                let column = min(columns - 1, Int(fraction * Double(columns - 1)))
                lows[column] = min(lows[column], adc)
                highs[column] = max(highs[column], adc)
            }
            // Preserve extrema per screen column without thousands of SwiftUI
            // child views or lines falsely joining gaps between readings.
            var ranges = Path()
            for column in 0..<columns where highs[column] >= 0 {
                let x = left + width * CGFloat(column) / CGFloat(max(1, columns - 1))
                if lows[column] == highs[column] {
                    ranges.addEllipse(in: CGRect(x: x - 1.7, y: y(lows[column]) - 1.7, width: 3.4, height: 3.4))
                } else {
                    ranges.move(to: CGPoint(x: x, y: y(lows[column])))
                    ranges.addLine(to: CGPoint(x: x, y: y(highs[column])))
                }
            }
            context.stroke(ranges, with: .color(.accentColor), lineWidth: 1.5)
        }
    }
}
