import AppKit

@MainActor final class HarborLifecycle: NSObject, NSApplicationDelegate {
    private var stopping = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            guard !stopping else { return }
            do { try await DaemonController.shared.start() }
            catch {
                guard !stopping else { return }
                NSApplication.shared.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Could not start the download engine"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !stopping else { return .terminateLater }
        stopping = true
        Task { @MainActor in
            let stopped = await DaemonController.shared.stop()
            if stopped { sender.reply(toApplicationShouldTerminate: true) }
            else {
                stopping = false
                sender.reply(toApplicationShouldTerminate: false)
                sender.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Download engine is still stopping"
                alert.informativeText = "Harbor stayed open because the daemon has not exited. Wait a moment, then quit Harbor again."
                alert.runModal()
            }
        }
        return .terminateLater
    }
}
