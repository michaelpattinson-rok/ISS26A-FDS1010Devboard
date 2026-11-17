import CryptoKit
import Foundation

nonisolated enum StreamingCalibration {
    private static func folder(_ project: StreamProjectStore, _ kind: String) throws -> URL {
        try StreamFiles.directory(kind, in: StreamFiles.directory("calibrations", in: project.folder, create: true), create: true)
    }

    static func attempts(_ project: StreamProjectStore) throws -> [CalibrationAttempt] {
        try list(CalibrationAttempt.self, in: folder(project, "attempts")) { $0.valid && $0.id == $1 }.sorted { $0.name < $1.name }
    }

    static func profiles(_ project: StreamProjectStore) throws -> [CalibrationProfile] {
        try list(CalibrationProfile.self, in: folder(project, "profiles")) { $0.valid && $0.id == $1 }.sorted { $0.name < $1.name }
    }

    private static func list<T: Decodable>(_ type: T.Type, in location: URL,
                                            valid: (T, UUID) -> Bool) throws -> [T] {
        try FileManager.default.contentsOfDirectory(at: location, includingPropertiesForKeys: nil).compactMap { url in
            guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
            let item = try StreamFiles.read(type, url)
            guard valid(item, id) else { throw ProfileWorkflowError.invalidEvidence }
            return item
        }
    }

    static func save(_ draft: CalibrationAttempt, to project: StreamProjectStore) throws {
        try project.verify()
        guard draft.valid else { throw ProfileWorkflowError.incompatibleSetup }
        let path = try folder(project, "attempts").appendingPathComponent(draft.id.uuidString + ".json")
        if StreamFiles.exists(path) {
            let old = try StreamFiles.read(CalibrationAttempt.self, path)
            if old.locked, old != draft { throw ProfileWorkflowError.validationNotLocked }
        }
        try StreamFiles.publish(draft, at: path, replace: StreamFiles.exists(path))
    }

    static func readSetup(_ source: URL) throws -> CalibrationProfile {
        guard source.pathExtension.lowercased() == "sigb" else { throw ProfileWorkflowError.invalidSetupFile }
        let body = try StreamFiles.read(source, limit: CalibrationSetupDocument.byteLimit)
        return try StreamFiles.decoder.decode(CalibrationSetupDocument.self, from: body).checked().profile
    }

    static func importSetup(_ source: URL, into project: StreamProjectStore, expected: CalibrationProfile) throws -> CalibrationProfile {
        guard source.pathExtension.lowercased() == "sigb" else { throw ProfileWorkflowError.invalidSetupFile }
        let body = try StreamFiles.read(source, limit: CalibrationSetupDocument.byteLimit)
        var profile = try StreamFiles.decoder.decode(CalibrationSetupDocument.self, from: body).checked().profile
        guard profile == expected else { throw ProfileWorkflowError.invalidSetupFile }
        let sha = StreamFiles.sha(body)
        if let existing = try profiles(project).first(where: { $0.sourceDigest == sha || $0 == profile }) { return existing }
        if try profiles(project).contains(where: { $0.id == profile.id }) { profile.id = UUID() }
        profile.origin = "imported"
        profile.locallyVerifiedElectrical = false
        profile.sourceDigest = sha
        try write(profile, to: project)
        return profile
    }

    static func exportSetup(_ profile: CalibrationProfile, in project: StreamProjectStore, destination: URL) throws -> URL {
        try project.verify()
        let document = try SessionStore.calibrationSetupDocument(profile)
        let data = try StreamFiles.encoder.encode(document)
        guard data.count <= CalibrationSetupDocument.byteLimit else { throw ProfileWorkflowError.invalidSetupFile }
        let name = try SessionStore.projectName(profile.name)
        let url = destination.appendingPathComponent(name + " " + profile.id.uuidString.prefix(8) + ".sigb")
        try Task.checkCancellation()
        try StreamFiles.publish(data, at: url)
        return url
    }

    private static func write(_ profile: CalibrationProfile, to project: StreamProjectStore) throws {
        guard profile.valid else { throw ProfileWorkflowError.invalidEvidence }
        let path = try folder(project, "profiles").appendingPathComponent(profile.id.uuidString + ".json")
        try StreamFiles.publish(profile, at: path)
    }

    static func saveFixtureRevision(_ profile: CalibrationProfile, evidence: Data, in project: StreamProjectStore) throws {
        try project.verify()
        let path = try folder(project, "fixture-evidence").appendingPathComponent(profile.id.uuidString + ".json")
        try StreamFiles.publish(evidence, at: path)
        try write(profile, to: project)
    }

    static func fixtureEvidence(for profile: UUID, in project: StreamProjectStore) throws -> Data {
        let root = try StreamFiles.directory("calibrations", in: project.folder, create: false)
        let folder = try StreamFiles.directory("fixture-evidence", in: root, create: false)
        return try StreamFiles.read(folder.appendingPathComponent(profile.uuidString + ".json"), limit: 4 * 1024 * 1024)
    }

    struct PhaseEvidence {
        var timeline = 0.0
        var sources: [(reader: StreamRangeReader, duration: Double)] = []
        var boots: Set<UInt64> = []
        var interrupted = false

        init(_ runs: [StreamRun], project: StreamProjectStore) throws {
            for run in runs.sorted(by: { $0.created < $1.created }) {
                let reader = try StreamRangeReader(store: project, run: run).prepared()
                let duration = try reader.duration()
                guard duration > 0 else { continue }
                timeline += duration
                sources.append((reader, duration))
                boots.formUnion(run.segments.compactMap(\.boot))
                interrupted = interrupted || run.status != .complete || run.segments.contains(where: \.unknown)
            }
        }

        func inspect(_ requested: Range<Double>, rules: ProfilePulseRules, limits: ProfileLimits?,
                     envelope: ProfileEnvelope?, spectrum: Bool = false,
                     report: (ProfileWindowResult, Int) -> Void, reference: (StreamRangeReference) throws -> Void = { _ in }) throws {
            var offset = 0.0
            for (reader, duration) in sources {
                defer { offset += duration }
                let lower = max(0, requested.lowerBound - offset)
                let upper = min(duration, requested.upperBound - offset)
                guard upper > lower else { continue }
                var begin = lower
                while begin < upper {
                    try Task.checkCancellation()
                    let minute = Int((begin + offset) / 60 + 1e-8)
                    let end = min(upper, Double(minute + 1) * 60 - offset)
                    guard end > begin else { break }
                    var windows = StreamPulseBlocks()
                    func analyze(_ record: CaptureRecord) throws {
                        let value = try ProfileAnalyzer.evaluate(record, rules: rules, limits: limits, envelope: envelope, spectrum: spectrum, streamingWindow: true)
                        report(value, minute)
                    }
                    try reader.visit(.init(lower: begin, upper: end)) { data in
                        try reference(data.reference)
                        try windows.append(data, output: analyze)
                    }
                    try windows.finish(analyze)
                    begin = end
                }
            }
        }
    }

    struct Metrics {
        var coverage: ProfileCoverage
        var baseline: [Double] = []
        var noise: [Double] = []
        var minutes: [Int: ProfileCoverage] = [:]

        mutating func add(_ result: ProfileWindowResult, minute: Int) {
            coverage.add(result)
            minutes[minute, default: ProfileCoverage()].add(result)
            if let value = result.baseline { baseline.append(value) }
            if let value = result.noise { noise.append(value) }
        }

        static func median(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return (sorted[sorted.count / 2] + sorted[(sorted.count - 1) / 2]) / 2
        }

        func checks(_ requested: Range<Double>, limits: ProfileLimits, empty: Bool, minimum: Int) -> [String] {
            var result: [String] = []
            if coverage.usableWindows < minimum { result.append("Too few usable analysis windows.") }
            if coverage.outside > 0 { result.append("One or more windows exceeded the locked baseline, noise, drift or headroom limits.") }
            let first = Int(requested.lowerBound / 60)
            let last = Int(ceil(requested.upperBound / 60)) - 1
            if first <= last {
                for index in first...last {
                    let seconds = min(requested.upperBound, Double(index + 1) * 60) - max(requested.lowerBound, Double(index) * 60)
                    let coverage = minutes[index] ?? ProfileCoverage()
                    if coverage.usable + 0.00001 < limits.minimumUsableSecondsPerMinute * seconds / 60 {
                        result.append("Minute \(index + 1) did not meet the usable coverage requirement.")
                    }
                    if empty && coverage.matches > limits.maximumEmptyMatchesPerBlock {
                        result.append("Minute \(index + 1) exceeded the allowed empty board pulse matches.")
                    }
                    if result.count > 12 { break }
                }
            }
            return result
        }
    }

    static func evaluate(_ entered: CalibrationAttempt, project: StreamProjectStore) throws -> CalibrationProfile {
        guard entered.valid, entered.limits.valid, entered.resultID == nil else { throw ProfileWorkflowError.validationNotLocked }
        var locked = entered
        locked.locked = true
        try save(locked, to: project)
        let all = try project.list().compactMap(\.run).filter {
            $0.curveSource == nil && $0.settings.mode == .calibration && $0.settings.calibrationAttempt == locked.id
        }
        guard all.allSatisfy({ $0.settings.calibrationSetup == locked.setup }) else {
            throw ProfileWorkflowError.incompatibleSetup
        }
        let phaseData = try locked.phases.map { phase in
            (phase, try PhaseEvidence(all.filter { $0.settings.calibrationPhase == phase }, project: project))
        }
        let split = Double(locked.preset.seconds * 2 / 3)
        let tolerance = locked.limits.baselineTolerance
        var centers: [Double] = []
        for (_, phase) in phaseData where phase.timeline > 0 {
            try phase.inspect(0..<min(split, phase.timeline), rules: locked.rules, limits: nil, envelope: nil) { result, _ in
                if let value = result.baseline, result.complete { centers.append(value) }
            }
        }
        let low = centers.min() ?? 0
        let high = centers.max() ?? locked.setup.adcMax
        let envelope = ProfileEnvelope(baselineLow: max(0, low - tolerance), baselineHigh: min(locked.setup.adcMax, high + tolerance))
        let summaries = try phaseData.map { phase, data -> ProfilePhaseSummary in
            let fitRange = 0..<min(split, data.timeline)
            let holdoutRange = min(split, data.timeline)..<data.timeline
            var fit = Metrics(coverage: .init(elapsed: fitRange.countSeconds))
            var holdout = Metrics(coverage: .init(elapsed: holdoutRange.countSeconds))
            var digest = SHA256()
            func evidence(_ range: StreamRangeReference) throws { digest.update(data: try StreamFiles.encoder.encode(range)) }
            try data.inspect(fitRange, rules: locked.rules, limits: locked.limits, envelope: envelope,
                             report: { fit.add($0, minute: $1) }, reference: evidence)
            try data.inspect(holdoutRange, rules: locked.rules, limits: locked.limits, envelope: envelope,
                             report: { holdout.add($0, minute: $1) }, reference: evidence)
            fit.coverage.unknown = max(0, fit.coverage.elapsed - fit.coverage.sampled)
            holdout.coverage.unknown = max(0, holdout.coverage.elapsed - holdout.coverage.sampled)
            fit.coverage.uncertainInterruption = data.interrupted
            holdout.coverage.uncertainInterruption = data.interrupted
            var issues = fit.checks(fitRange, limits: locked.limits, empty: phase != .dark, minimum: locked.limits.minimumFitWindows)
            issues += holdout.checks(holdoutRange, limits: locked.limits, empty: phase != .dark, minimum: locked.limits.minimumHoldoutWindows)
            if data.timeline < Double(locked.preset.seconds) { issues.append("The phase needs more recorded time.") }
            if phase == .repeatEmpty {
                let earlier = phaseData.filter { $0.0 != .repeatEmpty }.reduce(into: Set<UInt64>()) { $0.formUnion($1.1.boots) }
                if data.boots.isEmpty || !data.boots.isDisjoint(with: earlier) { issues.append("Record the repeated empty phase after restarting the acquisition device.") }
            }
            return .init(phase: phase, fit: fit.coverage, holdout: holdout.coverage,
                         fitBaselineMedian: Metrics.median(fit.baseline), fitNoiseMedian: Metrics.median(fit.noise),
                         holdoutBaselineMedian: Metrics.median(holdout.baseline), holdoutNoiseMedian: Metrics.median(holdout.noise),
                         evidenceSHA256: digest.finalize().map { String(format: "%02x", $0) }.joined(), issues: issues)
        }
        let profile = CalibrationProfile(profileID: locked.profileID, revision: locked.revision, name: locked.name,
                                         preset: locked.preset, setup: locked.setup, rules: locked.rules,
                                         limits: locked.limits, envelope: envelope, phases: summaries)
        try write(profile, to: project)
        locked.resultID = profile.id
        try StreamFiles.publish(locked, at: folder(project, "attempts").appendingPathComponent(locked.id.uuidString + ".json"), replace: true)
        return profile
    }

    static func assessPrerun(_ runID: UUID, in project: StreamProjectStore,
                             progress: (Double) -> Void = { _ in }) throws -> CalibratedPrerun.Result {
        try project.verify()
        let lock = try StreamRunLock(project.runDirectory(runID))
        defer { withExtendedLifetime(lock) {} }
        var run = try project.openRun(runID)
        guard run.curveSource == nil, let plan = run.settings.prerunPlan, let profile = run.settings.profile else {
            throw ProfileWorkflowError.invalidEvidence
        }
        let reader = try StreamRangeReader(store: project, run: run).prepared()
        let elapsed = min(plan.length.seconds, try reader.duration())
        let range = 0..<elapsed
        var metrics = Metrics(coverage: .init(elapsed: elapsed))
        var quality = ManualSampleQuality()
        var maxDrift: Double? = nil
        var specificIssues = Set<String>()
        var issues: [String] = []

        if run.status != .complete || run.segments.count != 1 || run.hasUnknownCoverage ||
            run.segments.contains(where: { $0.knownLoss != 0 }) {
            issues.append("The prerun ended with incomplete coverage.")
        }
        if run.hasCadenceMismatch { issues.append("Measured cadence differs from the configured rate.") }
        if run.segments.first?.deadlineReached != true {
            issues.append("The prerun stopped before the timer finished.")
        }

        if elapsed > 0 {
            let fullDuration = try reader.duration()
            var lastStep = 0
            try reader.visit(.init(lower: 0, upper: fullDuration)) { data in
                try quality.append(data.originalPayload, averaging: data.segment.picoAveraging, board: data.segment.board)
                let step = min(20, Int(data.firstSeconds * 20 / fullDuration))
                if step > lastStep { lastStep = step; progress(Double(step) / 100) }
            }
            let phase = try PhaseEvidence([run], project: project)
            var checked = 0.0
            try phase.inspect(range, rules: profile.rules, limits: profile.limits, envelope: profile.envelope) { result, minute in
                metrics.add(result, minute: minute)
                if result.outsideEnvelope || result.usableSamples == 0 { specificIssues.formUnion(result.reasons) }
                if let drift = result.drift { maxDrift = max(maxDrift ?? 0, drift) }
                checked += result.sampledSeconds
                if metrics.coverage.windows.isMultiple(of: 64) { progress(0.2 + min(0.75, 0.75 * checked / elapsed)) }
            }
            let qualityIssues = metrics.checks(range, limits: profile.limits, empty: false, minimum: 2)
            issues += qualityIssues
            if !qualityIssues.isEmpty { issues += specificIssues.sorted() }
        } else {
            issues.append("No verified ADC readings were saved.")
        }
        // Validate the full requested duration. Device and Mac clocks can drift
        // slightly, so allow 1% after the monotonic deadline and clean Stop.
        if elapsed < plan.length.seconds * 0.99 { issues.append("The saved timeline is shorter than the selected prerun.") }
        metrics.coverage.unknown = max(0, elapsed - metrics.coverage.sampled)
        metrics.coverage.uncertainInterruption = run.hasUnknownCoverage || run.status != .complete
        let report = CalibratedPrerun.Report(plan: plan, project: project.identity.id, run: run.id,
            profile: profile.id, inputSHA256: try CalibratedPrerun.snapshot(reader), coverage: metrics.coverage, quality: quality,
            baseline: Metrics.median(metrics.baseline), noise: Metrics.median(metrics.noise), drift: maxDrift,
            issues: Array(issues.prefix(32)))
        guard report.matches(run) else { throw ProfileWorkflowError.invalidEvidence }
        try Task.checkCancellation()
        let link = try report.link()
        run.prerunReport = report
        try project.save(run)
        progress(1)
        return .init(report: report, link: link)
    }

    static func check(_ reader: StreamRangeReader, profile: CalibrationProfile) throws {
        guard reader.run.status == .complete, reader.run.segments.count == 1, reader.run.segments.first?.unknown == false,
              reader.run.settings.purpose == "localDarkCheck", reader.run.settings.profile?.id == profile.id else {
            throw ProfileWorkflowError.invalidEvidence
        }
        let phase = try PhaseEvidence([reader.run], project: reader.store)
        guard phase.timeline >= 120 else { throw ProfileWorkflowError.moreData }
        let range = 0..<120.0
        var metrics = Metrics(coverage: .init(elapsed: range.countSeconds))
        try phase.inspect(range, rules: profile.rules, limits: profile.limits, envelope: profile.envelope) { metrics.add($0, minute: $1) }
        let issues = metrics.checks(range, limits: profile.limits, empty: false, minimum: 2)
        guard issues.isEmpty else { throw StreamFailure.storage("Dark setup check failed. " + issues.joined(separator: " ")) }
    }
}

private extension Range<Double> {
    nonisolated var countSeconds: Double { upperBound - lowerBound }
}
