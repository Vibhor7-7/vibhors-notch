import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
