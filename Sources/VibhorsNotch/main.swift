import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one copy may run: two would both react to the hotkeys (double pastes, double audio).
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me.processIdentifier }
        if !others.isEmpty {
            NSApp.terminate(nil)
            return
        }

        controller = NotchController()
        // `open -a "Vibhor's Notch" --args --enable-login-item` turns on Launch at Login.
        if CommandLine.arguments.contains("--enable-login-item") {
            controller?.vm.launchAtLogin = true
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
