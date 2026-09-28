import SwiftUI
import ServiceManagement

enum NotchTab: String, CaseIterable, Identifiable {
    case home, notes, shelf, prompter

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .notes: "note.text"
        case .shelf: "tray.full.fill"
        case .prompter: "text.aligncenter"
        }
    }

    var title: String {
        switch self {
        case .home: "Home"
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

    let expandedSize = CGSize(width: 660, height: 270)

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
