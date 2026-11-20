import SwiftUI

struct LibrarySampleJump: Identifiable {
    let id = UUID()
    let run: UUID
    let location: StreamMatchLocation
    var endSample: UInt64? = nil
}

struct ProjectReviewView: View {
    @ObservedObject var bench: StreamingBench
    @ObservedObject var settings: LocalAISettings
    let store: StreamProjectStore
    let runs: [StreamRun]
    let inspect: (LibrarySampleJump) -> Void
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var approvedRanges: [UUID: RangeDraft] = [:]
    @State private var scopeConfirmed = false

    private struct RangeDraft: Equatable {
        var segment: UUID? = nil
        var first = "0"
        var end = ""

        var range: ReviewRange? {
            guard let segment, let first = UInt64(first), let end = UInt64(end),
                  first < end, end <= StreamWire.maxSampleBoundary else { return nil }
            return .init(segment: segment, first: first, end: end)
        }
    }

    private var validScope: Bool {
        approvedRanges.values.allSatisfy { $0.segment == nil || $0.range != nil }
    }
    @State private var outcome: Outcome?
    @State private var staged: Set<UUID> = []
    @State private var reviewDraft: [ProjectJob] = []
    @State private var showJobApproval = false
    @State private var queuedDrafts = Set<UUID>()
    @State private var issue: String?

    nonisolated private struct Answer: Decodable, Sendable {
        let text: String
        let model: String
    }

    nonisolated private struct Outcome: Sendable {
        var answer: Answer?
        var proposals: [ReviewProposal] = []
        var jobDrafts: [ReviewJobDraft] = []
        var findings: [Finding] = []
        var failedTools = 0
        var completedTools = 0
        var evidence: [String] = []
    }

    nonisolated private struct Finding: Identifiable, Sendable {
        let run: UUID
        let location: StreamMatchLocation
        var end: UInt64?
        var id: String { "\(run):\(location.segment):\(location.sample)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Project Review").font(.title2.weight(.semibold))
                Text("\(store.identity.name) · \(runs.count.formatted()) selected \(runs.count == 1 ? "run" : "runs")")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Review Scope").font(.headline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(runs) { run in
                            scopeRow(run)
                        }
                    }
                }.frame(height: min(270, CGFloat(76 * runs.count + 72 * approvedRanges.values.filter { $0.segment != nil }.count)))
                    .padding(.top, 6)
                    .scrollIndicators(.visible)
                Toggle("Review only these runs and ranges", isOn: $scopeConfirmed).disabled(bench.busy)
            }
            if settings.ready {
                Text("\(settings.model) · \(settings.reasoning.title)").font(.caption).foregroundStyle(.secondary)
                TextField("Ask about the approved runs", text: $prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(3...5).disabled(bench.busy)
                Button("Find runs with clipping or gaps") {
                    prompt = "Compare sample coverage, clipping and ADC errors across the approved runs. Identify intervals worth inspecting."
                }.buttonStyle(.link).disabled(bench.busy)
            } else {
                Text("Enable Local AI, choose a model, and test tool calling in Settings.").foregroundStyle(.secondary)
                Button("Local AI Settings") { openSettings() }.disabled(bench.busy)
            }
            if bench.projectReviewRunning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Reviewing approved runs")
                    Spacer()
                    Text("\(bench.projectReviewToolReplies) tool replies")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let issue {
                Text(issue).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let outcome, outcome.answer != nil || !outcome.proposals.isEmpty || !outcome.findings.isEmpty || !outcome.jobDrafts.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        if let answer = outcome.answer {
                            Text(answer.text).textSelection(.enabled)
                            Text(evidenceLabel(outcome, answer: answer)).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(outcome.evidence, id: \.self) { evidence in
                            Text(evidence).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(outcome.findings) { item in
                            Button(findingLabel(item)) {
                                inspect(.init(run: item.run, location: item.location, endSample: item.end))
                            }.buttonStyle(.link)
                        }
                        ForEach(outcome.jobDrafts) { draft in
                            if let first = draft.jobs.first {
                                Button(queuedDrafts.contains(first.id) ? "Jobs Queued" : "Review \(draft.jobs.count) Proposed Jobs…") {
                                    reviewDraft = draft.jobs
                                    showJobApproval = true
                                }.disabled(bench.busy || queuedDrafts.contains(first.id))
                            }
                        }
                        ForEach(outcome.proposals) { proposal in
                            HStack {
                                Text(name(proposal.run)).lineLimit(1)
                                Spacer()
                                Button(staged.contains(proposal.id) ? "Staged" : "Stage Proposed Review") {
                                    stage(proposal)
                                }.disabled(bench.busy || staged.contains(proposal.id))
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 90, maxHeight: 260)
            }
            HStack {
                Button(bench.projectReviewRunning ? "Cancel Review" : "Close") {
                    if bench.projectReviewRunning { bench.cancelWork() }
                    else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Review Runs", action: start).buttonStyle(.borderedProminent)
                    .disabled(!settings.ready || !scopeConfirmed || !validScope || bench.busy || prompt.utf8.count > 15_000 ||
                              prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(minWidth: 440, idealWidth: 540, maxWidth: 760)
        .sheet(isPresented: $showJobApproval) {
            ApproveProjectJobsView(jobs: reviewDraft, runName: name) {
                queuedDrafts.formUnion(bench.approveJobs(reviewDraft))
            }
        }
        .interactiveDismissDisabled(bench.projectReviewRunning)
        .onChange(of: approvedRanges) { _, _ in
            scopeConfirmed = false
            outcome = nil
        }
        .onChange(of: settings.ready) { _, ready in
            if !ready && bench.projectReviewRunning { bench.cancelWork() }
        }
        .onChange(of: bench.project?.identity.id) { _, id in
            if id != store.identity.id { bench.cancelWork(); dismiss() }
        }
        .onChange(of: settings.enabled) { _, enabled in if !enabled && bench.projectReviewRunning { bench.cancelWork() } }
        .onChange(of: settings.allowImages) { _, allowed in if !allowed && bench.projectReviewRunning { bench.cancelWork() } }
        .onDisappear { if bench.projectReviewRunning { bench.cancelWork() } }
    }

    #if STREAM_TESTING
    init(bench: StreamingBench, settings: LocalAISettings, store: StreamProjectStore,
         runs: [StreamRun], inspect: @escaping (LibrarySampleJump) -> Void, example: ReviewRange? = nil) {
        self.bench = bench
        self.settings = settings
        self.store = store
        self.runs = runs
        self.inspect = inspect
        if let example, let run = runs.first {
            _approvedRanges = State(initialValue: [run.id: .init(segment: example.segment, first: String(example.first), end: String(example.end))])
            _outcome = State(initialValue: .init(answer: .init(text: "The selected interval contains a high rail.", model: "loaded-alias"),
                                                findings: [.init(run: run.id,
                                                    location: .init(segment: example.segment, sample: example.first), end: example.end)],
                                                completedTools: 1, evidence: ["Fresh Verified Scan"]))
        }
    }
    #endif

    private func scopeRow(_ run: StreamRun) -> some View {
        let value = approvedRanges[run.id] ?? RangeDraft()
        let segment = run.segments.first { $0.id == value.segment }
        return VStack(alignment: .leading, spacing: 6) {
            Text(run.name).fontWeight(.medium)
            Text("\(run.status == .interrupted ? "Interrupted" : "Saved") · \(run.segments.reduce(UInt64(0)) { $0 + $1.savedSamples }.formatted()) saved readings")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Range", selection: Binding(get: { value.segment }, set: { id in
                let selected = run.segments.first { $0.id == id }
                approvedRanges[run.id] = .init(segment: id, end: selected.map { String($0.accountedSamples) } ?? "")
            })) {
                Text("Whole Saved Run").tag(UUID?.none)
                ForEach(Array(run.segments.enumerated()), id: \.element.id) { index, segment in
                    Text("Segment \(index + 1)").tag(Optional(segment.id))
                }
            }
            if let segment {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("First sample").font(.caption).foregroundStyle(.secondary)
                        TextField("First sample", text: rangeField(run.id, \.first)).labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("End (exclusive)").font(.caption).foregroundStyle(.secondary)
                        TextField("End (exclusive)", text: rangeField(run.id, \.end)).labelsHidden()
                    }
                }
                Text("\(segment.savedSamples.formatted()) saved readings in this segment. Indices are on the original recorded grid.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(bench.busy).padding(.bottom, 6)
    }

    private func rangeField(_ id: UUID, _ field: WritableKeyPath<RangeDraft, String>) -> Binding<String> {
        Binding(get: { (approvedRanges[id] ?? RangeDraft())[keyPath: field] }, set: { text in
            var row = approvedRanges[id] ?? RangeDraft()
            row[keyPath: field] = String(text.prefix(24))
            approvedRanges[id] = row
        })
    }

    private func findingLabel(_ finding: Finding) -> String {
        let first = finding.location.sample.formatted()
        let span = finding.end.map { "\(first) to \(($0 - 1).formatted())" } ?? first
        return "\(name(finding.run)) · sample \(span)"
    }

    private func name(_ id: UUID) -> String { runs.first(where: { $0.id == id })?.name ?? id.uuidString }

    private func evidenceLabel(_ outcome: Outcome, answer: Answer) -> String {
        if outcome.completedTools == 0 { return "The model returned no tool results." }
        return "\(answer.model) · \(outcome.completedTools) tool replies · \(outcome.failedTools) errors"
    }

    private func start() {
        let endpoint = settings.endpoint, model = settings.model, reasoning = settings.reasoning, question = prompt
        let project = store, approved = runs.map(\.id), ranges = approvedRanges.compactMapValues(\.range)
        let images = settings.allowImages
        issue = nil
        outcome = nil
        staged.removeAll()
        bench.performWithProgress("Reviewing Project with LM Studio", projectReview: true) { [weak bench] _ in
            let scope = try ProjectReview(store: project, approved: approved, ranges: ranges)
            let client = try LMStudioClient(endpoint)
            defer { client.session.invalidateAndCancel() }
            var results = Outcome()
            do {
                try await client.reviewProject(scope, model: model, reasoning: reasoning, prompt: question, images: images) { kind, item in
                    switch kind {
                    case "agent_answer":
                        results.answer = try StreamFiles.decoder.decode(Answer.self, from: StreamFiles.encoder.encode(item))
                    case "job_draft":
                        if let draft = item as? ReviewJobDraft { results.jobDrafts.append(draft) }
                    case "proposal":
                        guard let proposal = item as? ReviewProposal else { return }
                        results.proposals.append(proposal)
                    case "tool_result":
                        results.completedTools += 1
                        Self.addFindings(item: item, results: &results)
                        let count = results.completedTools + results.failedTools
                        Task { @MainActor [weak bench] in
                            if bench?.projectReviewRunning == true { bench?.projectReviewToolReplies = count }
                        }
                    case "tool_error":
                        results.failedTools += 1
                    default: break
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                try project.verify()
                return (results, Optional(error.localizedDescription))
            }
            try project.verify()
            return (results, nil as String?)
        } completion: { result in
            guard bench.project?.identity.id == store.identity.id else { return }
            outcome = result.0
            issue = result.1
        }
    }

    nonisolated private static func addFindings(item: any Encodable, results: inout Outcome) {
        struct Tool: Decodable {
            struct Result: Decodable {
                struct Decision: Decodable {
                    let location: StreamMatchLocation?
                    let range: ReviewRange?
                    let pulse: ReviewPulse?
                    let segment: UUID?
                    let peakIndex: UInt64?
                }
                let findings: [Decision]?
                let evidence: String?
                let decisions: [Decision]?
            }
            struct Row: Decodable { let run: UUID; let result: Result? }
            let request: ReviewRequest
            let values: [Row]

            enum Key: String, CodingKey { case request, result }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Key.self)
                request = try container.decode(ReviewRequest.self, forKey: .request)
                if let run = request.run, let result = try? container.decode(Result.self, forKey: .result) {
                    values = [.init(run: run, result: result)]
                } else {
                    values = (try? container.decode([Row].self, forKey: .result)) ?? []
                }
            }
        }
        guard let bytes = try? StreamFiles.encoder.encode(item),
              let response = try? StreamFiles.decoder.decode(Tool.self, from: bytes) else { return }
        for row in response.values {
            if let label = row.result?.evidence, !results.evidence.contains(label), results.evidence.count < 12 {
                results.evidence.append(label)
            }
            for decision in (row.result?.findings ?? []) + (row.result?.decisions ?? []) {
                guard results.findings.count < 30 else { return }
                let location = decision.location
                    ?? decision.pulse.map { StreamMatchLocation(segment: $0.range.segment, sample: $0.peakIndex) }
                    ?? decision.range.map { StreamMatchLocation(segment: $0.segment, sample: $0.first) }
                    ?? decision.segment.flatMap { segment in
                        decision.peakIndex.map { StreamMatchLocation(segment: segment, sample: $0) }
                    }
                guard let location else { continue }
                let finding = Finding(run: row.run, location: location, end: decision.range?.end)
                if !results.findings.contains(where: { $0.id == finding.id }) { results.findings.append(finding) }
            }
        }
    }

    private func stage(_ proposal: ReviewProposal) {
        let project = store
        issue = nil
        bench.perform("Staging proposed review") {
            let input = try ReviewWorker(store: project).reader(proposal.run)
            try proposal.stage(input)
            return proposal.id
        } completion: { id in staged.insert(id) }
    }
}
