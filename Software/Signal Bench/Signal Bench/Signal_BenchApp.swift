import AppKit
import SwiftUI

@main
struct Signal_BenchApp: App {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @StateObject private var bench = StreamingBench()
    @NSApplicationDelegateAdaptor(StreamingAppDelegate.self) private var lifecycle

    var body: some Scene {
        Window("Signal Bench", id: "main") {
            StreamingWorkspace(bench: bench)
                .frame(minWidth: 640, minHeight: 480)
                .windowDismissBehavior(bench.busy ? .disabled : .automatic)
                .onAppear { lifecycle.bench = bench }
                .onChange(of: bench.project?.identity.id) { _, _ in bench.localAI.restore(bench.project) }
                .onChange(of: bench.timeline?.id) { _, id in
                    if id != nil { openWindow(id: "run-timeline") }
                    else { dismissWindow(id: "run-timeline") }
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in bench.sleepStarted() }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in bench.woke() }
        }
        .defaultSize(width: 1080, height: 760)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { bench.projectDialog = .new }
                    .keyboardShortcut("n").disabled(bench.busy || bench.draftDecision != nil || bench.needsProjectAccess)
                Button("Open Project…") { bench.openProject() }
                    .keyboardShortcut("o").disabled(bench.busy || (bench.draftDecision != nil && !bench.needsProjectAccess))
                Button("Show Exports in Finder") { bench.showExports() }
                    .disabled(bench.project == nil)
            }
            CommandMenu("Recording") {
                Button("Add Flag…") { bench.openLiveTimeline(.flag); if bench.timeline != nil { openWindow(id: "run-timeline") } }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(!bench.recording || bench.preview.received == 0)
                Button("Add Note…") { bench.openLiveTimeline(.note); if bench.timeline != nil { openWindow(id: "run-timeline") } }
                    .disabled(!bench.recording)
                Button("Stop Recording") { bench.stop() }
                    .keyboardShortcut(".", modifiers: .command).disabled(!bench.recording)
                Button("Release GPIO Outputs") { bench.release() }.disabled(bench.activeMode != .manual)
            }
        }
        Settings {
            LocalAISettingsView(settings: bench.localAI, project: bench.project)
        }
        Window("Flags & Notes", id: "run-timeline") {
            ZStack {
                if let request = bench.timeline {
                    RunTimelineEditor(bench: bench, request: request).id(request.id)
                } else {
                    ContentUnavailableView("Select a Recording", systemImage: "flag")
                }
            }.onDisappear { bench.closeTimeline() }
                .windowDismissBehavior(bench.timelineSaving ? .disabled : .automatic)
        }
        .defaultSize(width: 760, height: 640)
        .restorationBehavior(.disabled)
    }
}

