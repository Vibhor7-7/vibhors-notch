import AppKit
import SwiftUI

/// Borderless panel that can take keyboard focus (for notes / teleprompter)
/// without activating the app or stealing the menu bar.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the notch window, positions it over the built-in display's notch,
/// and drives hover-to-expand / leave-to-collapse.
@MainActor
final class NotchController {
    let vm = NotchViewModel()
    let notes = NotesStore()
    let shelf = ShelfStore()
    let calendar = CalendarStore()
    let battery = BatteryMonitor()

    private let panel: NotchPanel
    private var screen: NSScreen?
    private var monitors: [Any] = []
    private var expandWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?

    /// Extra transparent room around the expanded notch so its shadow isn't clipped.
    private let windowPadding = CGSize(width: 40, height: 30)

    init() {
        panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true
        panel.appearance = NSAppearance(named: .darkAqua)

        let root = NotchRootView()
            .environmentObject(vm)
            .environmentObject(notes)
            .environmentObject(shelf)
            .environmentObject(calendar)
            .environmentObject(battery)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting

        vm.requestCollapse = { [weak self] in self?.collapse() }

        layout()
        installMonitors()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
    }

    // MARK: - Layout

    private func layout() {
        guard let screen = NSScreen.builtIn else {
            // Lid closed / no built-in display: stay out of the way.
            collapse()
            panel.orderOut(nil)
            self.screen = nil
            return
        }
        self.screen = screen
        vm.notchSize = screen.notchSize

        let w = vm.expandedSize.width + windowPadding.width * 2
        let h = vm.expandedSize.height + windowPadding.height
        let frame = NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    private var collapsedHitRect: NSRect {
        guard let s = screen else { return .zero }
        let n = vm.notchSize
        return NSRect(x: s.frame.midX - n.width / 2 - 10, y: s.frame.maxY - n.height - 4,
                      width: n.width + 20, height: n.height + 4)
    }

    private var expandedHitRect: NSRect {
        guard let s = screen else { return .zero }
        let e = vm.expandedSize
        return NSRect(x: s.frame.midX - e.width / 2, y: s.frame.maxY - e.height,
                      width: e.width, height: e.height).insetBy(dx: -12, dy: -12)
    }

    /// Keep the notch open while typing, pinned, or reading the teleprompter.
    private var shouldStayOpen: Bool {
        vm.isPinned || vm.prompterPlaying || (panel.isKeyWindow && panel.firstResponder is NSTextView)
    }

    // MARK: - Mouse / keyboard

    private func installMonitors() {
        let moveEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]

        if let m = NSEvent.addGlobalMonitorForEvents(matching: moveEvents, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouse(event) }
        }) { monitors.append(m) }

        if let m = NSEvent.addLocalMonitorForEvents(matching: moveEvents, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouse(event) }
            return event
        }) { monitors.append(m) }

        // A click anywhere outside the notch (global monitor = other apps) closes it.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.vm.isExpanded, !self.vm.isPinned, !self.vm.prompterPlaying else { return }
                self.collapse()
            }
        }) { monitors.append(m) }

        // Esc closes the notch.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.collapse() }
            return nil
        }) { monitors.append(m) }
    }

    private func handleMouse(_ event: NSEvent) {
        let p = NSEvent.mouseLocation

        if vm.isExpanded {
            if expandedHitRect.contains(p) {
                collapseWork?.cancel()
                collapseWork = nil
            } else if collapseWork == nil, !shouldStayOpen {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.collapseWork = nil
                    if !self.expandedHitRect.contains(NSEvent.mouseLocation), !self.shouldStayOpen {
                        self.collapse()
                    }
                }
                collapseWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
            return
        }

        guard collapsedHitRect.contains(p) else {
            expandWork?.cancel()
            expandWork = nil
            return
        }

        // Dragging files onto the notch jumps straight to the shelf.
        if event.type == .leftMouseDragged, Self.dragContainsFiles {
            vm.tab = .shelf
            expand()
            return
        }

        if expandWork == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.expandWork = nil
                if self.collapsedHitRect.contains(NSEvent.mouseLocation) { self.expand() }
            }
            expandWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }
    }

    private static var dragContainsFiles: Bool {
        NSPasteboard(name: .drag).types?.contains(.fileURL) ?? false
    }

    // MARK: - Expand / collapse

    func expand() {
        expandWork?.cancel(); expandWork = nil
        collapseWork?.cancel(); collapseWork = nil
        guard !vm.isExpanded else { return }
        panel.ignoresMouseEvents = false
        withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
            vm.isExpanded = true
        }
    }

    func collapse() {
        expandWork?.cancel(); expandWork = nil
        collapseWork?.cancel(); collapseWork = nil
        guard vm.isExpanded else { return }
        panel.makeFirstResponder(nil)
        panel.ignoresMouseEvents = true
        vm.prompterPlaying = false
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            vm.isExpanded = false
        }
    }
}

extension NSScreen {
    static var builtIn: NSScreen? {
        screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
    }

    /// Size of the camera housing, derived from the menu bar areas on either side of it.
    var notchSize: CGSize {
        let height = safeAreaInsets.top
        guard height > 0, let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else {
            return CGSize(width: 190, height: 32)
        }
        return CGSize(width: frame.width - left.width - right.width, height: height)
    }
}
