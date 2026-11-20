import SwiftUI

struct MainsHumTestView: View {
    @ObservedObject var bench: StreamingBench
    let project: StreamProjectStore
    @Binding var selectedTest: UUID?
    @State private var selectedStep: MainsHumCapture.Step?
    @State private var confirmed = false
    @State private var showWiring = false
    @State private var compareSaved = false
    @State private var results: [UUID: MainsHumCapture.Reading] = [:]
    @State private var failures: [UUID: String] = [:]

    private typealias Step = MainsHumCapture.Step

    private var captures: [StreamRun] { bench.runs.compactMap(\.run).filter { $0.settings.mainsHum != nil && $0.curveSource == nil } }
    private var tests: [StreamRun] {
        var seen = Set<UUID>()
        return captures.filter { run in
            run.settings.mainsHum.map { seen.insert($0.test).inserted } ?? false
        }
    }
    private var testID: UUID? { selectedTest ?? tests.first?.settings.mainsHum?.test }
    private var latest: [Step: StreamRun] {
        var runs: [Step: StreamRun] = [:]
        for run in captures {
            if let capture = run.settings.mainsHum, capture.test == testID, runs[capture.step] == nil {
                runs[capture.step] = run
            }
        }
        return runs
    }
    private var step: Step {
        selectedStep ?? Step.allCases.first { latest[$0] == nil } ?? .battery100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("60 Hz workflow", selection: $compareSaved) {
                Text("Guided Pico Test").tag(false)
                Text("Compare Saved Runs").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            if compareSaved {
                MainsHumComparisonView(bench: bench)
            } else {
                guidedTest
            }
        }
    }

    private var guidedTest: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack { heading; Spacer(minLength: 18); history.fixedSize() }
                VStack(alignment: .leading, spacing: 8) { heading; history }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("1. Check the wiring").font(.headline)
                    Spacer()
                    Button("Show Wiring…", systemImage: "info.circle") { showWiring = true }
                }
                Text("Unplug USB before changing wires or J4. Connect the three J2 wires to the Pico W, leave J1 and the optional J3 probes disconnected, and leave J4 open (LOW). Reconnect USB and select Connect.")
                Text("Keep the same Pico, board, cable, USB port, and physical layout for all four captures. Connect the Pico directly to the Mac.")
                    .foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Text("2. Record each condition").font(.headline)
                Picker("Test condition", selection: Binding(get: { step }, set: { selectedStep = $0; confirmed = false })) {
                    ForEach(Step.allCases) { Text($0.title).tag($0) }
                }.fixedSize()
                Text(step.battery
                     ? "Unplug the Mac’s charger and disconnect powered docks or displays. Keep the Pico connected by USB."
                     : "Reconnect the Mac’s charger to wall power. Leave the Pico, USB cable and other connections in place.")
                Toggle("I checked the wiring and set the Mac’s power as shown", isOn: $confirmed)
                HStack(spacing: 12) {
                    Button(latest[step] == nil ? "Record 20 Seconds" : "Repeat for 20 Seconds", systemImage: "record.circle") {
                        guard confirmed, bench.canStart, bench.board == .picoW, bench.rateAvailable(step.rate) else { return }
                        let capture = MainsHumCapture(test: testID ?? UUID(), step: step)
                        selectedTest = capture.test
                        confirmed = false
                        bench.start(name: capture.runName,
                                    description: "Operator confirmed \(step.power.lowercased()). Standard J2, J1 empty, J4 LOW, optional probes disconnected. Raw ADC0 at 1×.",
                                    settings: capture.settings)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!confirmed || !bench.canStart || bench.board != .picoW || !bench.rateAvailable(step.rate))
                    if !bench.streaming || bench.board != .picoW {
                        Text("Connect a Pico W with streaming firmware.").font(.caption).foregroundStyle(.secondary)
                    } else if !bench.rateAvailable(step.rate) {
                        Text("This rate is unavailable on the connected firmware.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("3. Compare the results").font(.headline)
                ForEach(Step.allCases) { condition in resultRow(condition) }
                comparisons
                Text("A higher level with the charger suggests a charger or USB ground path. A similar level in both power states leaves wiring and nearby electric fields as possibilities. A change with rate is a cue to compare J2.3 on a scope.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("60 Hz readings are in ADC codes RMS. The app fits the tone to intact one second windows, then reports the median. It excludes windows with rails or ADC errors and omits failed captures from comparisons. Power state is confirmed by you.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showWiring) {
            DiagnosisWiringHelp(labels: [.disconnected, .disconnected], includeOptional: false)
        }
        .onChange(of: bench.connectionEpoch) { _, _ in confirmed = false }
        .task(id: latest) { await analyze(latest.values.sorted { $0.created < $1.created }) }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("60 Hz Test").font(.title2.weight(.semibold))
            Text("Compare charger and sample rate effects with four short ADC0 recordings.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var history: some View {
        HStack {
            if !tests.isEmpty {
                Picker("Test", selection: Binding(get: { testID }, set: { selectedTest = $0; selectedStep = nil; confirmed = false })) {
                    ForEach(tests) { run in
                        Text(run.created.formatted(date: .abbreviated, time: .standard))
                            .tag(run.settings.mainsHum?.test)
                    }
                    if let testID, !tests.contains(where: { $0.settings.mainsHum?.test == testID }) {
                        Text("New test").tag(Optional(testID))
                    }
                }.labelsHidden().accessibilityLabel("Saved 60 Hz test")
                Button("New Test") { selectedTest = UUID(); selectedStep = nil; confirmed = false }
            }
        }.disabled(bench.busy)
    }

    private func resultRow(_ condition: Step) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(condition.title).font(.callout.weight(.medium))
                Spacer()
                if let run = latest[condition] {
                    Button("Open Run") { bench.selection = run.id; bench.page = .library }
                        .buttonStyle(.borderless).accessibilityLabel("Open run for \(condition.title)")
                }
            }
            if let run = latest[condition] {
                if let reading = results[run.id] {
                    let level = reading.humRMS.map { "\(amount($0)) ADC codes RMS" } ?? "60 Hz level unavailable"
                    Text("\(level) · \(amount(reading.usableSeconds)) s usable")
                        .font(.callout.monospacedDigit())
                    if let issue = reading.comparisonIssue {
                        Text(issue).font(.caption).foregroundStyle(.secondary)
                    }
                    if reading.samples > 0 {
                        let fraction = Double(reading.railed) / Double(reading.samples)
                        let rail = fraction > 0 && fraction < 0.0001 ? "<0.01%" :
                            fraction.formatted(.percent.precision(.fractionLength(0...2)))
                        Text("Rails \(rail) · \(reading.low.formatted()) low · \(reading.high.formatted()) high · \(reading.errors.formatted()) ADC errors")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                } else if let failure = failures[run.id] {
                    Text(failure).font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Checking saved samples…", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Ready to record").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var comparisons: some View {
        let pairs: [(String, Step, Step)] = [
            ("Charger effect at 100,000", .battery100, .plugged100),
            ("Charger effect at 500,000", .battery500, .plugged500),
            ("500,000 vs 100,000 on battery", .battery100, .battery500),
            ("500,000 vs 100,000 with charger", .plugged100, .plugged500)
        ]
        let deltas = pairs.compactMap { label, first, second -> (String, Double)? in
            guard let a = latest[first], let b = latest[second], let firmware = a.segments.first?.firmware,
                  b.segments.first?.firmware == firmware, let x = results[a.id], let y = results[b.id],
                  x.comparisonIssue == nil, y.comparisonIssue == nil, let left = x.humRMS, let right = y.humRMS
            else { return nil }
            return (label, right - left)
        }
        if !deltas.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Change in 60 Hz level").font(.callout.weight(.semibold))
                ForEach(deltas, id: \.0) { label, difference in
                    let change = abs(difference) < 0.01 ? "less than 0.01" :
                        (difference > 0 ? "+" : "−") + amount(abs(difference))
                    Text("\(label) · \(change) ADC codes RMS")
                        .font(.callout.monospacedDigit())
                }
            }
        }
        if Set(latest.values.compactMap { $0.segments.first?.firmware }).count > 1 {
            Text("Repeat under the same firmware for a direct comparison.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func amount(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func analyze(_ runs: [StreamRun]) async {
        let pending = runs.filter { results[$0.id] == nil }
        for run in pending {
            guard !Task.isCancelled else { return }
            let store = project
            let task = Task.detached(priority: .utility) {
                try MainsHumCapture.analyze(.init(store: store, run: run))
            }
            let result = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let reading): results[run.id] = reading; failures[run.id] = nil
            case .failure(let error): failures[run.id] = error.localizedDescription
            }
        }
    }
}
