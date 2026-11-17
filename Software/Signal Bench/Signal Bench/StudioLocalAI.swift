import SwiftUI

struct StudioLocalAI: View {
    @ObservedObject var settings: LocalAISettings
    @ObservedObject var bench: StreamingBench
    let reader: StreamRangeReader
    let selection: StreamSelection
    let openSample: (StreamMatchLocation) -> Void
    let didStage: () -> Void
    @Environment(\.openSettings) private var openSettings
    @State private var prompt = ""
    @State private var fullRun = false
    @State private var analyzedRanges: [StreamSelection] = []
    @State private var answer: Answer?
    @State private var proposals: [ReviewProposal] = []
    @State private var jobDrafts: [ReviewJobDraft] = []
    @State private var locations: [StreamMatchLocation] = []
    @State private var reviewRunning = false
    @State private var staged: Set<UUID> = []
    @State private var reviewDraft: [ProjectJob] = []
    @State private var showJobApproval = false
    @State private var queuedDrafts = Set<UUID>()

    nonisolated private struct Answer: Decodable, Sendable {
        let model: String
        let text: String
        let toolCalls: Int
        let scope: StreamSelection
    }
    nonisolated private struct Outcome: Sendable {
        var answer: Answer?
        var analyzedRanges: [StreamSelection] = []
        var proposals: [ReviewProposal] = []
        var jobDrafts: [ReviewJobDraft] = []
        var locations: [StreamMatchLocation] = []
    }
    nonisolated private struct ToolResult: Decodable {
        struct Result: Decodable {
            struct Finding: Decodable { let location: StreamMatchLocation?; let pulse: ReviewPulse? }
            struct FixtureDecision: Decodable { let segment: UUID; let peakIndex: UInt64 }
            let decisions: [FixtureDecision]?
            let findings: [Finding]?
            let selection: StreamSelection?
        }
        let request: ReviewRequest
        let result: Result
    }

    var body: some View {
        DisclosureGroup("Ask Local AI") {
            VStack(alignment: .leading, spacing: 9) {
                if settings.ready {
                    Text(settings.model).font(.caption).foregroundStyle(.secondary)
                    Picker("Review scope", selection: $fullRun) {
                        Text("Selected Range").tag(false)
                        Text("Whole Run").tag(true)
                    }.fixedSize().disabled(bench.busy)
                    TextField("Question about this run or range", text: $prompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...5)
                        .disabled(bench.busy)
                    HStack {
                        Button("Review") { start() }.buttonStyle(.borderedProminent)
                            .disabled(bench.busy || (!fullRun && !selection.valid) || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.utf8.count > 16_384)
                        if reviewRunning { Button("Cancel Review") { bench.cancelWork() } }
                        Button("Local AI Settings") { openSettings() }
                    }
                } else {
                    Text(settings.enabled ? "Check the connection and select a model in Settings." : "Enable Local AI in Settings to review this run.")
                        .foregroundStyle(.secondary)
                    Button("Open Settings") { openSettings() }
                }
                if let answer {
                    Text("Review scope · \(rangeLabel(answer.scope))").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(analyzedRanges.enumerated()), id: \.offset) { _, range in
                        Text("Analyzed · \(rangeLabel(range))").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(answer.text).textSelection(.enabled)
                    Text(answer.model).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(locations.enumerated()), id: \.offset) { _, location in
                    Button("Inspect sample \(location.sample.formatted()) · \(location.segment.uuidString.prefix(8))") {
                        openSample(location)
                    }.buttonStyle(.link)
                }
                ForEach(jobDrafts) { draft in
                    if let first = draft.jobs.first {
                        Button(queuedDrafts.contains(first.id) ? "Jobs Queued" : "Review Proposed Job…") {
                            reviewDraft = draft.jobs
                            showJobApproval = true
                        }.disabled(bench.busy || queuedDrafts.contains(first.id))
                    }
                }
                ForEach(proposals) { proposal in
                    HStack {
                        Text(proposal.request.operation == .compare ? "Filter comparison" : "Filter preview")
                        Spacer()
                        Button(staged.contains(proposal.id) ? "Staged" : "Stage Proposed Review") { stage(proposal) }
                            .disabled(bench.busy || staged.contains(proposal.id))
                    }
                }
            }.font(.callout).padding(.top, 7)
        }
        .sheet(isPresented: $showJobApproval) {
            ApproveProjectJobsView(jobs: reviewDraft, runName: { _ in reader.run.name }) {
                queuedDrafts.formUnion(bench.approveJobs(reviewDraft))
            }
        }
        .onChange(of: bench.operation) { _, operation in if operation == nil { reviewRunning = false } }
        .onChange(of: settings.enabled) { _, enabled in if !enabled && reviewRunning { bench.cancelWork() } }
    }

    private func rangeLabel(_ range: StreamSelection) -> String {
        let precision = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...7))
        return "\(range.lower.formatted(precision)) to \(range.upper.formatted(precision)) s"
    }

    private func start() {
        let endpoint = settings.endpoint, model = settings.model, question = prompt
        let input = reader, range = selection, whole = fullRun
        answer = nil
        analyzedRanges = []
        proposals = []
        jobDrafts = []
        locations = []
        reviewRunning = true
        bench.performWithProgress("Reviewing with LM Studio…", projectReview: true) { _ in
            let client = try LMStudioClient(endpoint)
            defer { client.session.invalidateAndCancel() }
            var outcome = Outcome()
            try await client.review(worker: .init(store: input.store), model: model, prompt: question,
                                    run: input.run.id, selection: range, fullRun: whole) { kind, item in
                let data = try StreamFiles.encoder.encode(item)
                switch kind {
                case "agent_answer":
                    outcome.answer = try StreamFiles.decoder.decode(Answer.self, from: data)
                case "job_draft":
                    if let draft = item as? ReviewJobDraft { outcome.jobDrafts.append(draft) }
                case "proposal":
                    let proposal = try StreamFiles.decoder.decode(ReviewProposal.self, from: data)
                    if proposal.run == input.run.id { outcome.proposals.append(proposal) }
                case "tool_result":
                    if let result = try? StreamFiles.decoder.decode(ToolResult.self, from: data), result.request.run == input.run.id {
                        if let selection = result.result.selection, !outcome.analyzedRanges.contains(selection) {
                            outcome.analyzedRanges.append(selection)
                        }
                        let findings = (result.result.findings ?? []).compactMap { item in
                            item.location ?? item.pulse.map { StreamMatchLocation(segment: $0.range.segment, sample: $0.peakIndex) }
                        }
                        let fixture = (result.result.decisions ?? []).map { StreamMatchLocation(segment: $0.segment, sample: $0.peakIndex) }
                        for location in findings + fixture where outcome.locations.count < 24 {
                            if !outcome.locations.contains(where: { $0.segment == location.segment && $0.sample == location.sample }) {
                                outcome.locations.append(location)
                            }
                        }
                    }
                default: break
                }
            }
            return outcome
        } completion: { outcome in
            answer = outcome.answer
            analyzedRanges = outcome.analyzedRanges
            proposals = outcome.proposals
            jobDrafts = outcome.jobDrafts
            locations = outcome.locations
        }
    }

    private func stage(_ proposal: ReviewProposal) {
        let input = reader
        bench.perform("Staging proposed review") {
            try proposal.stage(input)
            return proposal.id
        } completion: { id in
            staged.insert(id)
            didStage()
        }
    }
}
