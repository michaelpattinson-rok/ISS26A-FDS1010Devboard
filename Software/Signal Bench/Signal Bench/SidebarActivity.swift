import Darwin
import Foundation
import os
import SwiftUI

nonisolated final class WaveformGPUTiming: Sendable {
    static let shared = WaveformGPUTiming()
    private let duration = OSAllocatedUnfairLock(initialState: 0.0)

    func record(start: Double, end: Double) {
        guard start > 0, end.isFinite, end > start else { return }
        duration.withLock { $0 += end - start }
    }

    var seconds: Double { duration.withLock { $0 } }
}

nonisolated struct ProcessActivitySample: Sendable {
    let time: Double
    let cpuSeconds: Double?
    let memoryBytes: UInt64?
    let waveformGPUSeconds: Double

    static func capture() -> Self {
        let time = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        var usage = rusage()
        let cpu = getrusage(RUSAGE_SELF, &usage) == 0
            ? Double(usage.ru_utime.tv_sec) + Double(usage.ru_stime.tv_sec)
                + (Double(usage.ru_utime.tv_usec) + Double(usage.ru_stime.tv_usec)) / 1e6
            : nil
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let bytes: UInt64? = result == KERN_SUCCESS && info.phys_footprint > 0 ? info.phys_footprint : nil
        return .init(time: time, cpuSeconds: cpu, memoryBytes: bytes, waveformGPUSeconds: WaveformGPUTiming.shared.seconds)
    }

    func cpuPercent(since previous: Self) -> Double? {
        guard let before = previous.cpuSeconds, let cpuSeconds, time > previous.time, cpuSeconds >= before else { return nil }
        return 100 * (cpuSeconds - before) / (time - previous.time)
    }

    func waveformGPUMillisecondsPerSecond(since previous: Self) -> Double? {
        guard time > previous.time, waveformGPUSeconds >= previous.waveformGPUSeconds else { return nil }
        return 1_000 * (waveformGPUSeconds - previous.waveformGPUSeconds) / (time - previous.time)
    }
}

struct SidebarActivity: View {
    @State private var cpu: Double?
    @State private var memory: UInt64?
    @State private var gpu: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Signal Bench Activity")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            meter("CPU", value: cpu.map { formatted($0) + "%" },
                  help: "Signal Bench CPU usage. 100% equals one fully used CPU core.")
            meter("RAM", value: memory.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) },
                  help: "Signal Bench memory footprint.")
            meter("Plot GPU", value: gpu.map { formatted($0) + " ms/s" },
                  help: "Milliseconds of Metal waveform rendering per second. Other graphics work is outside this meter.")
        }
        .task {
            var prior: ProcessActivitySample?
            while !Task.isCancelled {
                let sample = await Task.detached(priority: .utility) { ProcessActivitySample.capture() }.value
                guard !Task.isCancelled else { return }
                memory = sample.memoryBytes
                cpu = prior.flatMap { sample.cpuPercent(since: $0) }
                gpu = prior.flatMap { sample.waveformGPUMillisecondsPerSecond(since: $0) }
                prior = sample
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }

    private func formatted(_ value: Double) -> String {
        if value > 0 && value < 0.1 { return "<0.1" }
        return value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func meter(_ title: String, value: String?, help: String) -> some View {
        HStack(spacing: 5) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 5)
            Text(value ?? "…").monospacedDigit().lineLimit(1)
        }
        .font(.caption)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value ?? "Waiting for reading")
        .accessibilityHint(help)
    }
}
