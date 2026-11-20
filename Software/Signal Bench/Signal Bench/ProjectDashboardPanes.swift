import AppKit
import SwiftUI

struct ProjectOverviewPane: View {
    @ObservedObject var bench: StreamingBench

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(bench.project?.identity.name ?? "Overview").font(.largeTitle.weight(.semibold))
                }
                Divider()
                HStack {
                    Text("Standard Rev E.1 wiring").font(.title2.weight(.semibold))
                    StudioHelp(title: "Standard wiring", detail: "Remove USB power before wiring or changing J4.",
                               assets: bench.board == .unoR4 ? ["UnoWiring", "SetupWiringBoard"] : ["SetupWiringBoard", "SetupPicoPhoto"], illustration: false)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        setupPhotos.frame(width: 315)
                        pins.fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: 14) { setupPhotos; pins }
                }
                Divider()
                if let last = bench.runs.compactMap(\.run).first {
                    Button("Open Latest Recording", systemImage: "arrow.up.right.square") {
                        bench.selection = last.id
                        bench.page = .library
                    }
                    Text(last.name).font(.callout).foregroundStyle(.secondary)
                }
            }.padding(24).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private var setupPhotos: some View {
        HStack(alignment: .top, spacing: 12) {
            setupPhoto("SetupWiringBoard", label: "Rev E.1 J2")
            setupPhoto(bench.board == .unoR4 ? "UnoWiring" : "SetupPicoPhoto", label: bench.board.title)
        }
    }

    private func setupPhoto(_ asset: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(asset).resizable().scaledToFit().frame(maxHeight: 128)
                .frame(maxWidth: .infinity).clipShape(.rect(cornerRadius: 6)).accessibilityHidden(true)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var pins: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Devboard").font(.caption.weight(.medium))
                    Color.clear.frame(width: 14, height: 1)
                    Text(bench.board.title).font(.caption.weight(.medium))
                }.foregroundStyle(.secondary)
                wire("J2.1 GND", bench.board == .picoW ? "33 AGND" : "GND with supply return")
                wire("J2.2 3V3", bench.board == .picoW ? "36 3V3 OUT" : "Regulated 3.3 V supply")
                wire("J2.3 ADC", bench.board == .picoW ? "31 GP26 / ADC0" : "A0")
            }
            Text("Remove USB and external power before changing wiring or J4.")
                .font(.caption).foregroundStyle(.secondary)
        }.font(.callout)
    }

    private func wire(_ from: String, _ to: String) -> some View {
        GridRow {
            Text(from)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
            Text(to)
        }
        .accessibilityElement(children: .combine)
    }

}

struct ProjectSettingsPane: View {
    @ObservedObject var bench: StreamingBench
    let project: StreamProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var value = ProjectDefaults()
    @State private var typedName = ""
    @State private var confirmTrash = false

    private var savedRaw: String {
        let bytes = bench.runs.compactMap(\.run).reduce(UInt64(0)) { total, run in
            let readings = run.segments.reduce(UInt64(0)) { $0 + $1.savedSamples }
            return total + readings * UInt64(PicoAverage.stride(run.settings.picoAveraging, board: run.settings.board))
        }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private var free: String {
        guard let bytes = try? project.folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity else {
            return "Unavailable"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Project Settings").font(.title2.weight(.semibold))
            Text(project.folder.path).font(.caption).textSelection(.enabled)
            LabeledContent("Available on this volume", value: free)
            LabeledContent("Uncompressed reading data", value: savedRaw)

            Divider()
            Stepper("Main duration  \(value.minutes) min", value: $value.minutes, in: 1...120)
            Stepper("Startup Delay  \(value.startupDelay) s", value: Binding(
                get: { value.startupDelay },
                set: { value.startupDelaySeconds = $0 }
            ), in: StreamStartupDelay.supported)
            Text("The device samples during this delay. The recording timer starts when Signal Bench begins saving waveform data.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Default exclusions", selection: $value.noise) {
                ForEach(NoisePolicy.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("After recording", selection: Binding(
                get: { value.afterRecording ?? .quality },
                set: { value.afterRecording = $0 }
            )) {
                ForEach(PostRunOption.allCases) { Text($0.rawValue).tag($0) }
            }
            Text("The quality summary uses the saved samples. Noise Review proposes exclusions for approval. Profile Analysis uses the run’s saved profile when available.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let notice = bench.notice { Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Divider()
            HStack {
                Button("Move Project to Trash…", role: .destructive) { confirmTrash = true }
                    .disabled(bench.busy || bench.projectJobsUnfinished || bench.needsProjectAccess || bench.draftDecision != nil)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { bench.saveDefaults(value); if bench.defaults == value { dismiss() } }
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 490)
        .onAppear { value = bench.defaults }
        .sheet(isPresented: $confirmTrash) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Move Project to Trash").font(.title2.weight(.semibold))
                Text(project.folder.path).textSelection(.enabled)
                Text("This moves the Project, recordings, analyses and exports to Trash.")
                TextField("Type \(project.identity.name)", text: $typedName).textFieldStyle(.roundedBorder)
                if let notice = bench.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Spacer()
                    Button("Cancel") { confirmTrash = false; typedName = "" }.keyboardShortcut(.cancelAction)
                    Button("Move to Trash", role: .destructive) {
                        bench.trashProject(typed: typedName)
                        if bench.project == nil { dismiss() }
                    }.disabled(typedName != project.identity.name || bench.busy || bench.projectJobsUnfinished)
                }
            }.padding(24).frame(width: 470)
        }
    }
}

struct ProjectCalibrationPane: View {
    @ObservedObject var bench: StreamingBench
    @State private var optical = "Dim Light"
    @State private var presetName = ""
    @State private var saved: [OpticalPreset] = []
    @State private var selected: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Calibration").font(.largeTitle.weight(.semibold))
                CalibrationPanel(bench: bench)
                Divider()
                Text("Optical presets").font(.title2.weight(.semibold))
                Text("Compare relative ADC readings, noise and saturation at the same setup.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Lighting", selection: $optical) {
                    Text("Dim Light").tag("Dim Light")
                    Text("Room Light").tag("Room Light")
                }
                TextField("Preset name", text: $presetName).textFieldStyle(.roundedBorder)
                Button("Save Preset") { save() }
                    .disabled(bench.busy || (try? SessionStore.projectName(presetName)) == nil)
                Picker("Saved preset", selection: $selected) {
                    Text("Choose a preset").tag(UUID?.none)
                    ForEach(saved) { Text($0.name + " · " + $0.lighting).tag(Optional($0.id)) }
                }
                SamplingRatePicker(bench: bench, selection: $bench.sampleRate, seconds: 60)
                Button("Record One Minute") {
                    guard let item = saved.first(where: { $0.id == selected }) else { return }
                    bench.start(name: item.name, description: item.lighting + " relative optical observation",
                                settings: .init(mode: .diagnosis, nominalRate: bench.sampleRate, duration: 60, wiring: "Standard J2 · optical preset " + item.id.uuidString))
                }.disabled(!bench.canStart || !bench.rateAvailable(bench.sampleRate) || selected == nil)
            }.padding(24).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
        }.task(id: bench.project?.identity.id) { reload() }
    }

    private func reload() {
        guard let project = bench.project else { return }
        do { saved = try OpticalPreset.list(project) }
        catch { bench.notice = error.localizedDescription }
    }

    private func save() {
        guard let project = bench.project else { return }
        do {
            let preset = OpticalPreset(name: try SessionStore.projectName(presetName), lighting: optical)
            try preset.save(project)
            selected = preset.id
            presetName = ""
            reload()
        } catch { bench.notice = error.localizedDescription }
    }
}
