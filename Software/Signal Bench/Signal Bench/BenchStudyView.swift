import SwiftUI

struct BenchStudyView: View {
    @ObservedObject var bench: StreamingBench
    let project: StreamProjectStore
    @State private var sequences: [BenchSequence] = []
    @State private var creating = false
    @State private var newName = ""
    @State private var setup = CalibrationSetup(firmware: "Pico W · firmware 1.8")
    @State private var step = BenchStep.empty
    @State private var minutes = 5
    @State private var confirmation = false
    @State private var name = ""
    @State private var description = ""
    @State private var first: UUID?
    @State private var second: UUID?
    @State private var profile: UUID?
    @State private var comparison: [BenchSummary] = []
    @State private var minuteSide = 0

    private var current: BenchSequence? { sequences.first { $0.id == bench.studySelection } }
    private var runs: [StreamRun] { current.map { BenchStudy.runs($0, items: bench.runs) } ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                HStack {
                    Text("Bench Test").font(.largeTitle.weight(.semibold))
                    Spacer()
                    Button("New Sequence…", systemImage: "plus") {
                        if bench.board == .unoR4 || CalibrationSetup.streamingVersions.contains(bench.firmware) {
                            setup.firmware = CalibrationSetup.firmwareLabel(bench.firmware.isEmpty ? "1.0" : bench.firmware, board: bench.board)
                            setup.acquisitionBoard = bench.board
                        }
                        creating = true
                    }.disabled(bench.busy)
                }
                if let sequence = current {
                    Picker("Sequence", selection: $bench.studySelection) {
                        ForEach(sequences) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Text("\(sequence.setup.acquisitionDevice.title) · \(sequence.setup.board) · \(sequence.setup.detector) · J4 \(sequence.setup.gain) · \(sequence.setup.nominalHz.formatted()) samples/s")
                        .font(.callout).foregroundStyle(.secondary)
                    steps
                    Divider()
                    captureForm(sequence)
                    if !runs.isEmpty {
                        Divider()
                        comparisonForm(sequence)
                    }
                } else {
                    ContentUnavailableView("Start a bench sequence", systemImage: "testtube.2",
                                           description: Text("Link empty board, dark detector, repeat empty board and fixture recordings."))
                        .frame(minHeight: 230)
                }
            }.padding(20).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }
        .onAppear { load() }
        .onChange(of: bench.studySelection) { _, _ in reset() }
        .onChange(of: bench.connectionEpoch) { _, _ in confirmation = false }
        .onChange(of: step) { _, value in
            confirmation = false
            minutes = value == .dark ? 30 : 5
            name = ""
            description = ""
        }
        .sheet(isPresented: $creating) { createSequence }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(BenchStep.allCases) { phase in
                let recordings = runs.filter { $0.settings.bench?.step == phase }
                HStack(spacing: 9) {
                    Image(systemName: recordings.contains(where: { $0.status == .complete }) ? "checkmark.circle" : "circle")
                        .foregroundStyle(recordings.isEmpty ? Color.secondary : Color.accentColor)
                    Button(phase.rawValue) { step = phase }
                        .buttonStyle(.plain).fontWeight(step == phase ? .semibold : .regular)
                    StudioHelp(title: phase.rawValue, detail: phase.instructions,
                               assets: phase.helpAssets)
                    Spacer()
                    if !recordings.isEmpty {
                        Menu("\(recordings.count) saved") {
                            ForEach(recordings) { run in
                                Button("\(run.name) · \(run.status.rawValue.capitalized)") { open(run) }
                            }
                        }.fixedSize()
                    }
                }.padding(.horizontal, 8).padding(.vertical, 4)
                    .background(step == phase ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func captureForm(_ sequence: BenchSequence) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(step.rawValue).font(.headline)
            Text(step.instructions).font(.callout).foregroundStyle(.secondary)
            if step == .repeatEmpty, !runs.contains(where: { $0.settings.bench?.step == .empty && $0.status == .complete }) {
                Text("Save an initial empty board run first so the two Pico boots can be compared.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SamplingRatePicker(bench: bench, selection: .constant(sequence.setup.nominalHz),
                               seconds: Double(minutes) * 60, locked: true, averaging: .constant(sequence.setup.picoAveraging))
            Toggle("I confirmed the setup, J4 and power precautions", isOn: $confirmation)
            TextField("Run name", text: $name).textFieldStyle(.roundedBorder)
            TextField("Description and conditions", text: $description).textFieldStyle(.roundedBorder)
            HStack {
                Stepper("Duration, minutes", value: $minutes, in: 1...120)
                TextField("Minutes", value: $minutes, format: .number).frame(width: 55)
                Spacer()
                Button("Record \(step.rawValue)") { start(sequence) }.buttonStyle(.borderedProminent)
                    .disabled(!bench.canStart || !bench.rateAvailable(sequence.setup.nominalHz, averaging: sequence.setup.picoAveraging) || !confirmation || !(1...120).contains(minutes) ||
                              (try? SessionStore.projectName(name)) == nil ||
                              description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              (step == .repeatEmpty && !runs.contains(where: { $0.settings.bench?.step == .empty && $0.status == .complete })))
            }
        }
    }

    private func comparisonForm(_ sequence: BenchSequence) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Compare Recordings").font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack { runPicker("Left", selection: $first); runPicker("Right", selection: $second) }
                VStack(alignment: .leading) { runPicker("Left", selection: $first); runPicker("Right", selection: $second) }
            }
            Picker("Pulse rules", selection: $profile) {
                Text("Coverage and noise only").tag(UUID?.none)
                ForEach(bench.profiles.filter { $0.ready && $0.setup == sequence.setup }, id: \.id) { value in
                    Text(value.name + " · revision " + String(value.revision)).tag(Optional(value.id))
                }
            }
            HStack {
                Button("Compare Runs", action: compare).disabled(first == nil || second == nil || first == second || bench.busy)
                StudioHelp(title: "Bench comparison", detail: "Compares ADC coverage, baseline, clipping, drift and robust noise. A compatible profile adds electronics matches per usable minute. Import fixture timing in the run’s Waveform Review to inspect hits and misses.", assets: ["ReviewNoise", "ReviewTemplate"], illustration: true)
                Spacer()
            }
            if comparison.count == 2 {
                HStack(alignment: .top, spacing: 14) {
                    summaryCard(comparison[0])
                    summaryCard(comparison[1])
                }
                let empty = comparison.first { $0.step == .empty }
                let repeatRun = comparison.first { $0.step == .repeatEmpty }
                if let empty, let repeatRun {
                    if empty.boots.isEmpty || repeatRun.boots.isEmpty || !Set(empty.boots).isDisjoint(with: repeatRun.boots) {
                        Label("A new Pico boot could not be verified for the repeat.", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Label("The repeat uses a different Pico boot.", systemImage: "checkmark.circle").font(.callout)
                    }
                }
                Picker("Minute detail", selection: $minuteSide) {
                    Text(comparison[0].step.rawValue).tag(0)
                    Text(comparison[1].step.rawValue).tag(1)
                }.pickerStyle(.segmented)
                Table(comparison[minuteSide].minutes) {
                    TableColumn("Min") { (item: BenchMinute) in Text(item.index.formatted()) }.width(38)
                    TableColumn("Saved") { (item: BenchMinute) in Text(number(item.sampled) + " s") }.width(min: 56, ideal: 65)
                    TableColumn("Usable") { (item: BenchMinute) in Text(number(item.profileUsable ?? item.validADC) + " s") }.width(min: 56, ideal: 65)
                    TableColumn("Baseline") { (item: BenchMinute) in Text(number(item.baseline)) }.width(min: 55, ideal: 70)
                    TableColumn("Noise") { (item: BenchMinute) in Text(number(item.noise)) }.width(min: 53, ideal: 65)
                    TableColumn("Drift") { (item: BenchMinute) in Text(number(item.drift)) }.width(min: 48, ideal: 60)
                    TableColumn("Clipped") { (item: BenchMinute) in Text(item.clipped.formatted()) }.width(min: 48, ideal: 60)
                    TableColumn("ADC errors") { (item: BenchMinute) in Text(item.adcErrors.formatted()) }.width(min: 58, ideal: 70)
                    TableColumn("Matches") { (item: BenchMinute) in Text(item.matches?.formatted() ?? "—") }.width(min: 48, ideal: 60)
                }.frame(height: 230)
            }
        }
    }

    private func runPicker(_ label: String, selection: Binding<UUID?>) -> some View {
        Picker(label, selection: selection) {
            Text("Choose a recording").tag(UUID?.none)
            ForEach(runs) { item in Text(item.name).tag(Optional(item.id)) }
        }
    }

    private func summaryCard(_ summary: BenchSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.name).font(.subheadline.weight(.semibold)).lineLimit(2)
            Text(summary.step.rawValue).foregroundStyle(.secondary)
            Text("\(number(summary.sampled)) s sampled · \(number(summary.usable)) s usable")
            if let rate = summary.falsePerMinute {
                Text("\(number(rate)) electronics matches per usable minute")
            } else if let count = summary.totalMatches {
                Text("\(count) deterministic matches")
            }
            if summary.unknownInterval { Text("Includes unknown coverage").foregroundStyle(.secondary) }
            Button("Open Run") { if let run = runs.first(where: { $0.id == summary.run }) { open(run) } }.buttonStyle(.link)
        }.font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 7))
    }

    private var createSequence: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                Text("New Bench Sequence").font(.title2.weight(.semibold))
                TextField("Sequence name", text: $newName).textFieldStyle(.roundedBorder)
                HStack {
                    Text("Board, J2 wiring and physical gain").font(.headline)
                    StudioHelp(title: "Bench setup", detail: "Record the actual hardware setup and keep it consistent across the sequence. Unplug USB before changing J1, J2 or J4.", assets: ["SetupWiringBoard", "SetupPicoPhoto", "SetupGainLow", "SetupGainHigh"])
                }
                ProfileSetupEditor(setup: $setup)
                SamplingRatePicker(bench: bench, selection: $setup.nominalHz, averaging: $setup.picoAveraging)
                HStack {
                    Spacer()
                    Button("Cancel") { creating = false }.keyboardShortcut(.cancelAction)
                    Button("Create Sequence") {
                        do {
                            let value = BenchSequence(project: project.identity.id, name: try SessionStore.projectName(newName), setup: setup)
                            try BenchStudy.save(value, in: project)
                            creating = false
                            load()
                            bench.studySelection = value.id
                        } catch { bench.notice = error.localizedDescription }
                    }.keyboardShortcut(.defaultAction).disabled(!setup.valid || (try? SessionStore.projectName(newName)) == nil)
                }
            }.padding(22)
        }.frame(width: 560, height: 500)
    }

    private func load() {
        do {
            sequences = try BenchStudy.sequences(project)
            if current == nil { bench.studySelection = sequences.first?.id }
            if let selected = bench.selectedRun?.settings.bench, selected.sequence == bench.studySelection { step = selected.step }
            selectDefaultRuns()
        } catch { bench.notice = error.localizedDescription }
    }

    private func reset() {
        step = .empty
        confirmation = false
        comparison = []
        profile = nil
        selectDefaultRuns()
    }

    private func selectDefaultRuns() {
        first = runs.first(where: { $0.settings.bench?.step == .empty })?.id
        second = runs.first(where: { $0.settings.bench?.step == .dark })?.id
    }

    private func start(_ sequence: BenchSequence) {
        bench.start(name: name, description: description,
                    settings: .init(mode: .main, nominalRate: sequence.setup.nominalHz, duration: Double(minutes) * 60, wiring: step.instructions,
                                    gain: sequence.setup.gain, bench: .init(sequence: sequence.id, step: step, setup: sequence.setup),
                                    picoAveraging: sequence.setup.picoAveraging))
    }

    private func compare() {
        guard let left = runs.first(where: { $0.id == first }), let right = runs.first(where: { $0.id == second }) else { return }
        let project = project
        let chosen = bench.profiles.first { $0.id == profile }
        bench.perform("Summarizing bench recordings") {
            try [left, right].map { try BenchStudy.summary(.init(store: project, run: $0), profile: chosen) }
        } completion: { comparison = $0; minuteSide = 0 }
    }

    private func open(_ run: StreamRun) {
        bench.selection = run.id
        bench.page = .library
    }

    private func number(_ value: Double?) -> String {
        value?.formatted(.number.precision(.fractionLength(0...2))) ?? "Unavailable"
    }
}
