import AppKit

/// AppKit owns the native termination reply. BenchModel remains the source of
/// truth for device, recording and persistence state.
@MainActor final class SignalBenchAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: BenchModel? {
        didSet {
            guard let model else { return }
            if let message = pendingOpenError {
                pendingOpenError = nil
                model.error = message
            }
            if let url = pendingSessionURL {
                pendingSessionURL = nil
                openSession(url, in: model)
            }
        }
    }

    private var terminationTask: Task<Void, Never>?
    private var pendingSessionURL: URL?
    private var pendingOpenError: String?

    // Narrow seams let native delegate coordination be checked without opening
    // alerts or terminating the test process. The shipped defaults use AppKit.
    var terminationReply: (NSApplication, Bool) -> Void = { app, answer in
        app.reply(toApplicationShouldTerminate: answer)
    }
    var forcedQuitDecision: (String) -> Bool = { issue in
        makeQuitAlert(issue).runModal() == .alertSecondButtonReturn
    }

    static func makeQuitAlert(_ issue: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Finish saving before quitting?"
        alert.informativeText = issue + "\n\nKeep Signal Bench open to finish or recover the record. Any Pico record that has not been saved may exist only in RAM and is lost after reset or power loss. An incomplete export may remain on the Mac."
        alert.addButton(withTitle: "Keep Open")
        let quit = alert.addButton(withTitle: "Quit Anyway")
        quit.hasDestructiveAction = true
        return alert
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        guard let model else { return .terminateNow }
        terminationTask = Task { [weak self] in
            let issue = await model.prepareForShutdown(timeout: 30)
            guard let self else {
                model.cancelShutdown()
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            let shouldQuit = issue.map(self.forcedQuitDecision) ?? true
            if !shouldQuit { model.cancelShutdown() }
            self.terminationTask = nil
            self.terminationReply(sender, shouldQuit)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// An explicit LaunchServices open supplies a transient user selected URL.
    /// It does not authorize acquisition or bypass session validation.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.count == 1, let url = urls.first, url.isFileURL else {
            let message = "Open one local Signal Bench session folder at a time."
            if let model { model.error = message } else { pendingOpenError = message }
            return
        }
        guard terminationTask == nil, model?.shutdownInProgress != true else {
            model?.error = "Finish quitting or choose Keep Open before opening a session."
            return
        }
        if let model { openSession(url, in: model) }
        else { pendingSessionURL = url }
    }

    private func openSession(_ url: URL, in model: BenchModel) {
        do { try model.loadSession(at: url) }
        catch { model.error = "Could not open the session. \(error.localizedDescription)" }
    }
}
