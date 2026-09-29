import SwiftUI
import ServiceManagement

enum NotchTab: String, CaseIterable, Identifiable {
    case home, assistant, media, tasks, notes, shelf, focus, prompter

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .assistant: "sparkles"
        case .media: "music.note"
        case .tasks: "checklist"
        case .focus: "timer"
        case .notes: "note.text"
        case .shelf: "tray.full.fill"
        case .prompter: "text.aligncenter"
        }
    }

    var title: String {
        switch self {
        case .home: "Home"
        case .assistant: "Apollo"
        case .media: "Music"
        case .tasks: "Tasks"
        case .focus: "Focus Timer"
        case .notes: "Notes"
        case .shelf: "Shelf"
        case .prompter: "Teleprompter"
        }
    }
}

final class NotchViewModel: ObservableObject {
    @Published var isExpanded = false
    @Published var tab: NotchTab = .home
    @Published var isPinned = false
    @Published var prompterPlaying = false
    @Published var notchSize = CGSize(width: 190, height: 32)

    let expandedSize = CGSize(width: 760, height: 290)

    /// Width of each side of the closed notch when showing a live countdown.
    static let liveActivityEarWidth: CGFloat = 72

    var requestCollapse: () -> Void = {}

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Launch at login failed: \(error)")
            }
            objectWillChange.send()
        }
    }
}
