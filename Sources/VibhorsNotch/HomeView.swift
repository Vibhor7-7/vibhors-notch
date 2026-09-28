import SwiftUI
import EventKit
import IOKit.ps

// MARK: - Calendar

final class CalendarStore: ObservableObject {
    @Published private(set) var events: [EKEvent] = []
    @Published private(set) var status = EKEventStore.authorizationStatus(for: .event)

    private let store = EKEventStore()

    init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.status = EKEventStore.authorizationStatus(for: .event)
                self.refresh()
            }
        }
    }

    /// Events still in progress or starting before the end of tomorrow.
    func refresh() {
        status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else {
            events = []
            return
        }
        let now = Date()
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now)) ?? now.addingTimeInterval(172_800)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .filter { $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(10)
            .map { $0 }
    }
}

// MARK: - Battery

struct BatteryInfo {
    var level = 100
    var isCharging = false
    var isPluggedIn = false
    var hasBattery = false
}

final class BatteryMonitor: ObservableObject {
    @Published private(set) var info = BatteryInfo()
    private var timer: Timer?

    init() {
        read()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.read() }
    }

    func read() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            info = BatteryInfo(
                level: max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current,
                isCharging: desc[kIOPSIsChargingKey] as? Bool ?? false,
                isPluggedIn: desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                hasBattery: true
            )
            return
        }
    }
}

// MARK: - Views

struct HomeView: View {
    @EnvironmentObject var calendar: CalendarStore
    @EnvironmentObject var battery: BatteryMonitor

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 0) {
                ClockView()
                Spacer(minLength: 8)
                if battery.info.hasBattery {
                    BatteryBadge(info: battery.info)
                }
            }
            .frame(width: 230, alignment: .leading)

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1)

            UpcomingEventsView()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            calendar.refresh()
            battery.read()
        }
    }
}

private struct ClockView: View {
    private static let uses12Hour =
        DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(context.date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                        .font(.system(size: 56, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if Self.uses12Hour {
                        Text(Calendar.current.component(.hour, from: context.date) < 12 ? "AM" : "PM")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct BatteryBadge: View {
    let info: BatteryInfo

    private var symbol: String {
        if info.isCharging { return "battery.100percent.bolt" }
        switch info.level {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private var tint: Color {
        if info.isCharging || info.isPluggedIn { return .green }
        if info.level <= 20 { return .red }
        return .white
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(tint)
            Text("\(info.level)%")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(info.isCharging ? "Charging" : info.isPluggedIn ? "Plugged in" : "On battery")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

private struct UpcomingEventsView: View {
    @EnvironmentObject var calendar: CalendarStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("UP NEXT")
                .font(.system(size: 11, weight: .bold))
                .kerning(0.8)
                .foregroundStyle(.secondary)

            switch calendar.status {
            case .fullAccess:
                if calendar.events.isEmpty {
                    placeholder(icon: "calendar", text: "Nothing on your calendar today or tomorrow.")
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(calendar.events, id: \.self) { EventRow(event: $0) }
                        }
                    }
                }
            case .notDetermined:
                VStack(alignment: .leading, spacing: 10) {
                    placeholder(icon: "calendar.badge.plus", text: "Connect your calendar to see upcoming events.")
                    Button("Connect Calendar") { calendar.requestAccess() }
                        .buttonStyle(PillButtonStyle(prominent: true))
                }
            default:
                VStack(alignment: .leading, spacing: 10) {
                    placeholder(icon: "calendar.badge.exclamationmark", text: "Calendar access is off.")
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                    .buttonStyle(PillButtonStyle())
                }
            }
        }
    }

    private func placeholder(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }
}

private struct EventRow: View {
    let event: EKEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: event.calendar?.color ?? .systemBlue))
                .frame(width: 4, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title ?? "Untitled")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(timeText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(isNow ? Color.green : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let url = event.meetingURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Join", systemImage: "video.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .foregroundStyle(isJoinable ? Color.black : Color.white)
                        .background(Capsule().fill(isJoinable ? Color.green : Color.white.opacity(0.1)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(url.absoluteString)
            }
        }
    }

    /// In progress or starting within 10 minutes.
    private var isJoinable: Bool {
        !event.isAllDay && event.startDate.timeIntervalSinceNow < 600 && event.endDate > Date()
    }

    private var isNow: Bool {
        let now = Date()
        return !event.isAllDay && event.startDate <= now && event.endDate > now
    }

    private var timeText: String {
        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(event.startDate) || event.startDate < Date() { day = "Today" }
        else if cal.isDateInTomorrow(event.startDate) { day = "Tomorrow" }
        else { day = event.startDate.formatted(.dateTime.weekday(.wide)) }

        if event.isAllDay { return "\(day) · All day" }
        let end = event.endDate.formatted(date: .omitted, time: .shortened)
        if isNow { return "Now · until \(end)" }
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        return "\(day) · \(start) – \(end)"
    }
}

extension EKEvent {
    private static let meetingPattern =
        #"https?://[^\s<>"']*(zoom\.us/(j|my|w|s)/|meet\.google\.com/[a-z]|teams\.microsoft\.com/l/meetup-join|teams\.live\.com/meet|webex\.com/|whereby\.com/|meet\.around\.co/|chime\.aws/)[^\s<>"']*"#

    /// First Zoom / Meet / Teams / Webex link found in the event's URL, location or notes.
    var meetingURL: URL? {
        for text in [url?.absoluteString, location, notes].compactMap({ $0 }) {
            if let range = text.range(of: Self.meetingPattern, options: [.regularExpression, .caseInsensitive]) {
                let link = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)>]"))
                if let url = URL(string: link) { return url }
            }
        }
        return nil
    }
}
