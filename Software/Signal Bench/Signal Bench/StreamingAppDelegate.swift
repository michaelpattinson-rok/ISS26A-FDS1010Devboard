import AppKit

final class StreamingAppDelegate: NSObject, NSApplicationDelegate {
    weak var bench: StreamingBench?
    private var textClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        textClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: TextClickAway.handle)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let textClickMonitor { NSEvent.removeMonitor(textClickMonitor) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let bench, bench.needsQuitDrain else { return .terminateNow }
        // Keep the normal AppKit event loop active while the recorder and
        // cancellable jobs deliver their completion to the main actor.
        bench.prepareToQuit { [weak sender] ready in
            guard ready else { return }
            DispatchQueue.main.async { sender?.terminate(nil) }
        }
        return .terminateCancel
    }
}
