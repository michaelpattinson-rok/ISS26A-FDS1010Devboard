import SwiftUI

struct ProjectJobsView: View {
    @ObservedObject var bench: StreamingBench
    @State private var retry: ProjectJob?
    @State private var retryName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jobs").font(.title3.weight(.semibold))
            if bench.projectReviewRunning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Local AI review")
                    Spacer()
                    Button("Cancel") { bench.cancelWork() }
                }
            }
            if let active = bench.qualityProgress.first {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Automatic quality summary").fontWeight(.medium)
                        Spacer()
                        Button("Pause") { bench.pausePostRun(active.key) }.disabled(bench.qualityPaused.contains(active.key))
                    }
                    Text(runName(active.key)).lineLimit(2)
                    let progress = active.value
                    Text(bench.qualityPaused.contains(active.key) ? "Pausing" : progress.stage.rawValue)
                        .foregroundStyle(.secondary)
                    if progress.total > 0 {
                        ProgressView(value: progress.stage == .analyzing ? 1 : min(0.999, progress.fraction))
                        Text("\(progress.scanned.formatted()) of \(progress.total.formatted()) readings · \(Int(min(progress.stage == .analyzing ? 100 : 99, progress.fraction * 100)))%")
                            .monospacedDigit().foregroundStyle(.secondary)
                    } else { ProgressView() }
                    if let message = progress.message { Text(message).foregroundStyle(.secondary) }
                }.font(.callout)
            }
            let paused = bench.qualityPaused.subtracting(bench.qualityProgress.keys)
            let failed = bench.qualityIssues.keys.filter { !paused.contains($0) }
            if !paused.isEmpty || !failed.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach((Array(paused) + failed).sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(runName(id)).fontWeight(.medium)
                                Text(bench.qualityIssues[id] ?? "Quality summary paused").foregroundStyle(.secondary)
                                Button(paused.contains(id) ? "Resume" : "Retry") { bench.retryPostRun(id) }
                            }
                        }
                    }
                }.frame(maxHeight: 160)
            }
            if bench.jobs.isEmpty && bench.qualityProgress.isEmpty && paused.isEmpty && failed.isEmpty && !bench.projectReviewRunning {
                Text("Exports and approved review jobs appear here.").foregroundStyle(.secondary)
            } else if !bench.jobs.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(bench.jobs) { job in
                            row(job)
                            Divider()
                        }
                    }
                }.frame(maxHeight: 350)
            }
        }.padding(16).frame(width: 380)
            .sheet(item: $retry) { job in
                VStack(alignment: .leading, spacing: 12) {
                    Text("Retry Export").font(.title2.weight(.semibold))
                    TextField("Export name", text: $retryName).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Cancel") { retry = nil }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Retry") {
                            retry = nil
                            bench.retryJob(job.id, name: retryName)
                        }.keyboardShortcut(.defaultAction).disabled((try? SessionStore.projectName(retryName)) == nil)
                    }
                }.padding(20).frame(width: 330)
            }
    }

    private func runName(_ id: UUID) -> String {
        bench.runs.first { $0.id == id }?.run?.name ?? "Recording"
    }

    private func row(_ job: ProjectJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.title).fontWeight(.medium)
                Spacer()
                Text(job.state.rawValue.capitalized).foregroundStyle(.secondary)
            }
            Text(job.name).lineLimit(2).foregroundStyle(.secondary)
            if job.state == .running || job.state == .paused {
                ProgressView(value: job.progress)
                if job.state == .paused {
                    Text("Recording has priority. The job resumes when recording finishes.").foregroundStyle(.secondary)
                }
            }
            if let message = job.message {
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if job.state.unfinished { Button("Cancel") { bench.cancelJob(job.id) } }
                if job.state.retryable {
                    Button("Retry") {
                        if job.picksDestination && job.state == .failed {
                            retryName = job.name
                            retry = job
                        } else { bench.retryJob(job.id) }
                    }
                }
                if job.kind == .exclusions, job.state == .completed {
                    Button("Review in Studio") { bench.inspectJob(job) }.disabled(bench.busy)
                }
                if job.state == .completed, job.curve?.action == .fit || job.curve?.action == .standalone {
                    Button("Open Run") { bench.openCurveJob(job) }.disabled(bench.busy)
                }
                if bench.jobHasFinderLocation(job) { Button("Show in Finder") { bench.revealJob(job.id) } }
            }
        }.font(.callout)
    }
}

struct ApproveProjectJobsView: View {
    let jobs: [ProjectJob]
    let runName: (UUID) -> String
    let approve: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Approve Proposed Jobs").font(.title2.weight(.semibold))
            Text("These jobs will use the listed inputs and save their output in this Project.")
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(jobs) { job in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(job.title).fontWeight(.semibold).foregroundStyle(.primary)
                            Text(runName(job.input.run)).foregroundStyle(.primary)
                            Text("\(job.input.selection.lower.formatted()) to \(job.input.selection.upper.formatted()) s · \(job.input.recordedReadings.formatted()) estimated readings")
                            Text(job.kind.format == nil ? "Jobs result · \(job.id.uuidString)" : "Exports/\(job.name).zip")
                            Text("Estimated storage \(ByteCountFormatter.string(fromByteCount: job.estimatedBytes, countStyle: .file))")
                            if let model = job.model {
                                if let ranges = job.input.ranges, !ranges.isEmpty {
                                    DisclosureGroup("Sample bounds and input hash") {
                                        ForEach(ranges, id: \.segment) { range in
                                            Text("\(range.segment.uuidString) · \(range.first.formatted()) to \(range.end.formatted()) exclusive")
                                        }
                                        Text(job.input.source).font(.caption.monospaced())
                                    }
                                }
                                Text("\(model.model) · \(model.reasoning.title)")
                                Text("Analyzer \(model.analyzer) · comparison \(model.comparison) · processing \(model.processing)")
                                if job.kind == .zip { Text("Includes selected readings and timing. Linked runs and prior analyses are omitted.") }
                            }
                            if let profile = job.input.profile { Text("Calibration \(profile.uuidString)") }
                            if let annotation = job.input.annotations { Text("Approved exclusions \(annotation.uuidString)") }
                            if let template = job.template {
                                Text("Template \(template.uuidString) · \(job.weighted == true ? "Noise weighted" : "Unweighted")")
                            }
                            if let settings = job.settings {
                                settingsLine("Requested settings", settings: settings)
                            }
                            if let reference = job.reference {
                                settingsLine("Comparison reference", settings: reference)
                            }
                        }.foregroundStyle(.secondary).textSelection(.enabled)
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 100, maxHeight: 310)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Approve and Queue") { approve(); dismiss() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 480)
    }

    private func settingsLine(_ title: String, settings: ReviewWorkerSettings) -> some View {
        var fields: [String] = []
        if let drift = settings.drift { fields.append(drift ? "baseline correction on" : "baseline correction off") }
        if let notch = settings.notch60 { fields.append(notch ? "60 Hz notch on" : "60 Hz notch off") }
        if let notch = settings.notch120 { fields.append(notch ? "120 Hz notch on" : "120 Hz notch off") }
        if let glitch = settings.maskGlitches { fields.append(glitch ? "glitch masking on" : "glitch masking off") }
        if let noise = settings.maskNoise { fields.append(noise ? "noise masking on" : "noise masking off") }
        if let height = settings.height { fields.append("minimum height \(height.formatted()) codes") }
        if fields.isEmpty { fields.append("use the saved profile or default settings") }
        return LabeledContent(title, value: fields.joined(separator: ", ")).font(.caption)
    }
}

struct JobExclusionsReview: View {
    @ObservedObject var bench: StreamingBench
    let reader: StreamRangeReader
    let job: ProjectJob
    let proposal: JobExclusionProposal
    let openSample: (StreamMatchLocation) -> Void
    @State private var selected = Set<String>()
    @State private var page = 0
    @State private var appliedRevision: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Proposed Exclusions").font(.headline)
            Text(appliedRevision != nil ? "Selected intervals were saved to the run’s approved exclusions." :
                "\(proposal.intervals.count.formatted()) proposed intervals. Select only the intervals you want to exclude.")
                .foregroundStyle(.secondary)
            if let appliedRevision {
                Button("Undo Applied Exclusions") {
                    let input = reader
                    bench.perform("Undoing exclusions") { try RunAnnotations.undo(input, revision: appliedRevision) } completion: { _ in
                        self.appliedRevision = nil
                        selected.removeAll()
                    }
                }.disabled(bench.busy)
            }
            if appliedRevision == nil, !proposal.intervals.isEmpty {
                ForEach(proposal.intervals.dropFirst(page * 12).prefix(12)) { interval in
                    HStack {
                        Toggle("Select interval", isOn: Binding(get: { selected.contains(interval.id) }, set: {
                            if $0 { selected.insert(interval.id) } else { selected.remove(interval.id) }
                        })).labelsHidden().accessibilityLabel("Select exclusion at reading \(interval.range.first)")
                        Button("\(interval.reason.rawValue) · \(interval.range.first.formatted()) to \(interval.range.end.formatted())") {
                            openSample(.init(segment: interval.range.segment, sample: interval.evidenceIndex ?? interval.range.first))
                        }.buttonStyle(.link)
                    }
                }
                HStack {
                    Button("Previous") { page -= 1 }.disabled(page == 0)
                    Button("Next") { page += 1 }.disabled((page + 1) * 12 >= proposal.intervals.count)
                    Spacer()
                    Button("Apply Selected (\(selected.count))", action: apply).disabled(selected.isEmpty || bench.busy)
                }
            }
        }.font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func apply() {
        let input = reader, job = job, choices = selected
        bench.perform("Applying selected exclusions") {
            let proposal = try ProjectJobFiles.exclusionProposal(job, reader: input)
            var revision = try RunAnnotations.read(input) ?? .init()
            let previous = Set(revision.masks.map(\.id))
            let changes = proposal.intervals.filter { choices.contains($0.id) && !previous.contains($0.id) }
            guard !changes.isEmpty else { throw StreamFailure.storage("No new intervals are selected.") }
            revision.masks.append(contentsOf: changes)
            return try RunAnnotations.save(revision, reader: input, replacing: proposal.input.annotations)
        } completion: { revision in appliedRevision = revision.id }
    }
}
