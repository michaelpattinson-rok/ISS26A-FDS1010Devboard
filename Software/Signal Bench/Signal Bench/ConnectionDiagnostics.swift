import SwiftUI

struct ConnectionDiagnosticsView: View {
    @EnvironmentObject private var model: BenchModel
    @Environment(\.dismiss) private var dismiss

    private var selectedRecord: CaptureRecord? { model.selectedRecord }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connection Diagnostics").font(.title2.weight(.semibold))
                    Text("Check the USB connection and the selected record.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    deviceSection
                    captureSection
                    troubleshooting
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 540, idealHeight: 640)
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Device", systemImage: "cable.connector").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                row("USB ports", model.ports.isEmpty ? "None found" : "\(model.ports.count) available")
                row("Selected port", model.selectedPort.isEmpty ? "None selected" : model.selectedPort)
                row("Connection", model.connectionStatus)
                row("Firmware", model.connected ? model.deviceInfo : "Not identified")
                row("Protocol", model.connected ? "SB1" : "Not identified")
                row("Physical gain", model.connected && model.gainConfirmed ? "\(model.gain.capitalized) confirmed by operator" : "Not confirmed")
                row("Quiet calibration", model.connected ? (model.calibrated ? "Accepted by firmware" : "Required for qualified pulses") : "Unknown while disconnected")
                row("Pending record", model.pendingUnsaved ? "Needs recovery or confirmation" : (model.connected ? (model.busy ? "Checking or working" : "None reported") : "Unknown while disconnected"))
            }.font(.callout)
            Text(model.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Refresh Devices", action: model.refreshPorts).disabled(model.busy)
                if !model.connected {
                    Button("Check Selected Device", action: model.connect)
                        .disabled(model.selectedPort.isEmpty || model.busy)
                } else {
                    Button("Check Status", action: model.checkDeviceStatus).disabled(model.busy || model.manualActive || model.stageActive)
                    Button("Disconnect", action: model.disconnect).disabled(model.busy)
                }
            }
            Text("Select a port in the main window before checking it. A port name alone does not identify a Pico.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Selected Record", systemImage: "waveform.path.ecg").font(.headline)
            if let record = selectedRecord {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    row("Transfer", record.complete ? "Complete" : "Incomplete")
                    row("Samples retained", "\(record.samples.count)")
                    row("Analysis", analysisDescription(record))
                    row("Acquisition", flagDescription(record.metadata["acq_flags"], flags: RecordDiagnostics.acquisition))
                    row("Quality", flagDescription(record.metadata["quality_flags"], flags: RecordDiagnostics.quality))
                }.font(.callout)
                if let issue = record.metadata["storage_recovery"] {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
                Text("A complete transfer does not establish a usable measurement or radiation response.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Select a saved record to inspect acquisition and quality flags.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var troubleshooting: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("If a check fails", systemImage: "questionmark.circle").font(.headline)
            Text("No port: check the USB data cable and refresh. Close any other serial monitor before connecting.")
            Text("Unsupported firmware: check the Pico W build and target. A device response has not been verified until it identifies compatible Signal Bench firmware.")
            Text("Pending record: keep the Pico powered, open the original session, and use Retry Pending Record. A reset or power loss can erase the record.")
            Text("Noise or clipping: inspect the saved record and check power and intermediate stages. Power off before rewiring or moving the gain jumper.")
        }.font(.callout).foregroundStyle(.secondary)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
    private func flagDescription(_ value: String?, flags: [(UInt32, String)]) -> String {
        guard let names = RecordDiagnostics.describe(value, flags: flags) else { return "Not available" }
        return names.isEmpty ? "No flags reported" : names.joined(separator: ", ")
    }
    private func analysisDescription(_ record: CaptureRecord) -> String {
        guard record.complete else { return "Not verified" }
        if record.metadata["tag"] == "CAL" {
            guard let calibrated = record.metadata["calibrated"] else { return "Calibration result not available" }
            return calibrated == "1" ? "Quiet calibration accepted" : "Quiet calibration not accepted"
        }
        guard let usable = record.metadata["usable"] else { return "Not available" }
        if usable == "1" { return "Record accepted by firmware" }
        if usable == "0" { return "Not accepted for measurement" }
        return "Not available"
    }
}
