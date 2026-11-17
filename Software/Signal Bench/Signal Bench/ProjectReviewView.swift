import SwiftUI

struct LibrarySampleJump: Identifiable {
    let id = UUID()
    let run: UUID
    let location: StreamMatchLocation
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
    }

    nonisolated private struct Finding: Identifiable, Sendable {
        let run: UUID
        let location: StreamMatchLocation
        var id: String { "\(run):\(location.segment):\(location.sample)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Project Review").font(.title2.weight(.semibold))
                Text("\(store.identity.name) · \(runs.count.formatted()) approved \(runs.count == 1 ? "run" : "runs")")
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup("Review Scope") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(runs) { run in
                            Text(run.name).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.frame(maxHeight: 108).padding(.top, 6)
            }
            if settings.ready {
                Text(settings.model).font(.caption).foregroundStyle(.secondary)
                TextField("Ask about the approved runs", text: $prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(3...5).disabled(bench.busy)
                Button("Find runs with clipping or gaps") {
                    prompt = "Compare sample coverage, clipping and ADC errors across the approved runs. Identify intervals worth inspecting."
                }.buttonStyle(.link).disabled(bench.busy)
            } else {
                Text("Enable Local AI and choose a served model in Settings.").foregroundStyle(.secondary)
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
                        ForEach(outcome.findings) { item in
                            Button("\(name(item.run)) · sample \(item.location.sample.formatted())") {
                                inspect(.init(run: item.run, location: item.location))
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
                    .disabled(!settings.ready || bench.busy || prompt.utf8.count > 15_000 ||
                              prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 520)
        .sheet(isPresented: $showJobApproval) {
            ApproveProjectJobsView(jobs: reviewDraft, runName: name) {
                queuedDrafts.formUnion(bench.approveJobs(reviewDraft))
            }
        }
        .interactiveDismissDisabled(bench.projectReviewRunning)
        .onChange(of: settings.enabled) { _, enabled in if !enabled && bench.projectReviewRunning { bench.cancelWork() } }
        .onDisappear { if bench.projectReviewRunning { bench.cancelWork() } }
    }

    private func name(_ id: UUID) -> String { runs.first(where: { $0.id == id })?.name ?? id.uuidString }

    private func evidenceLabel(_ outcome: Outcome, answer: Answer) -> String {
        if outcome.completedTools == 0 { return "The model returned no tool results." }
        return "\(answer.model) · \(outcome.completedTools) tool replies · \(outcome.failedTools) errors"
    }

    private func start() {
        let endpoint = settings.endpoint, model = settings.model, question = prompt
        let project = store, approved = runs.map(\.id)
        issue = nil
        outcome = nil
        staged.removeAll()
        bench.performWithProgress("Reviewing Project with LM Studio", projectReview: true) { [weak bench] _ in
            let scope = try ProjectReview(store: project, approved: approved)
            let client = try LMStudioClient(endpoint)
            defer { client.session.invalidateAndCancel() }
            var results = Outcome()
            do {
                try await client.reviewProject(scope, model: model, prompt: question) { kind, item in
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
            outcome = result.0
            issue = result.1
        }
    }

    nonisolated private static func addFindings(item: any Encodable, results: inout Outcome) {
        struct Tool: Decodable {
            struct Result: Decodable {
                struct Decision: Decodable {
                    let location: StreamMatchLocation?
                    let pulse: ReviewPulse?
                    let segment: UUID?
                    let peakIndex: UInt64?
                }
                let findings: [Decision]?
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
            for decision in (row.result?.findings ?? []) + (row.result?.decisions ?? []) {
                guard results.findings.count < 30 else { return }
                let location = decision.location
                    ?? decision.pulse.map { StreamMatchLocation(segment: $0.range.segment, sample: $0.peakIndex) }
                    ?? decision.segment.flatMap { segment in
                        decision.peakIndex.map { StreamMatchLocation(segment: segment, sample: $0) }
                    }
                guard let location else { continue }
                let finding = Finding(run: row.run, location: location)
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
