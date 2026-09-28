import SwiftUI

/// Pomodoro-style timer. Focus sessions auto-start a break when they finish;
/// breaks return to an idle focus session.
final class FocusTimer: ObservableObject {
    enum Phase: String {
        case focus, rest

        var title: String { self == .focus ? "Focus" : "Break" }
        var icon: String { self == .focus ? "timer" : "cup.and.saucer.fill" }
        var color: Color { self == .focus ? .orange : .green }
    }

    @Published private(set) var phase: Phase = .focus
    /// Set while running.
    @Published private(set) var endDate: Date?
    /// Set while paused partway through a session.
    @Published private(set) var pausedRemaining: TimeInterval?

    @Published var focusMinutes: Int {
        didSet { UserDefaults.standard.set(focusMinutes, forKey: "focus.focusMinutes") }
    }
    @Published var breakMinutes: Int {
        didSet { UserDefaults.standard.set(breakMinutes, forKey: "focus.breakMinutes") }
    }
    @Published private var completed: (day: String, count: Int)

    /// Called after a phase runs to completion (not when skipped).
    var onPhaseComplete: ((Phase) -> Void)?

    private var ticker: Timer?

    init() {
        let defaults = UserDefaults.standard
        focusMinutes = defaults.object(forKey: "focus.focusMinutes") as? Int ?? 25
        breakMinutes = defaults.object(forKey: "focus.breakMinutes") as? Int ?? 5
        completed = (defaults.string(forKey: "focus.completedDay") ?? "", defaults.integer(forKey: "focus.completedCount"))
    }

    var duration: TimeInterval { Double(phase == .focus ? focusMinutes : breakMinutes) * 60 }
    var isRunning: Bool { endDate != nil }
    /// Running or paused mid-session; drives the live countdown on the closed notch.
    var isActive: Bool { isRunning || pausedRemaining != nil }

    var completedToday: Int { completed.day == Self.today ? completed.count : 0 }

    func remaining(at date: Date = Date()) -> TimeInterval {
        if let endDate { return max(0, endDate.timeIntervalSince(date)) }
        return pausedRemaining ?? duration
    }

    func progress(at date: Date = Date()) -> Double {
        duration > 0 ? 1 - remaining(at: date) / duration : 0
    }

    // MARK: Controls

    func start() {
        endDate = Date().addingTimeInterval(remaining())
        pausedRemaining = nil
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    func pause() {
        pausedRemaining = remaining()
        endDate = nil
        stopTicker()
    }

    func toggle() { isRunning ? pause() : start() }

    func reset() {
        endDate = nil
        pausedRemaining = nil
        stopTicker()
    }

    func skip() { finishPhase(naturally: false) }

    func select(_ newPhase: Phase) {
        guard newPhase != phase else { return }
        reset()
        phase = newPhase
    }

    // MARK: Internals

    private func tick() {
        if let endDate, Date() >= endDate { finishPhase(naturally: true) }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func finishPhase(naturally: Bool) {
        let finished = phase
        reset()
        phase = finished == .focus ? .rest : .focus

        guard naturally else { return }
        if finished == .focus {
            recordCompletedSession()
            start() // roll straight into the break
        }
        NSSound(named: finished == .focus ? "Glass" : "Hero")?.play()
        onPhaseComplete?(finished)
    }

    private func recordCompletedSession() {
        completed = (Self.today, completedToday + 1)
        UserDefaults.standard.set(completed.day, forKey: "focus.completedDay")
        UserDefaults.standard.set(completed.count, forKey: "focus.completedCount")
    }

    private static var today: String {
        Date().formatted(.iso8601.year().month().day())
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct FocusView: View {
    @EnvironmentObject var focus: FocusTimer

    var body: some View {
        HStack(spacing: 30) {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.1), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: focus.progress(at: context.date))
                        .stroke(focus.phase.color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.5), value: focus.progress(at: context.date))
                    VStack(spacing: 2) {
                        Text(FocusTimer.format(focus.remaining(at: context.date)))
                            .font(.system(size: 38, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(focus.isRunning ? focus.phase.title.uppercased()
                             : focus.isActive ? "PAUSED" : "READY")
                            .font(.system(size: 11, weight: .bold))
                            .kerning(0.8)
                            .foregroundStyle(focus.isRunning ? focus.phase.color : .secondary)
                    }
                }
                .frame(width: 168, height: 168)
            }

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 6) {
                    phaseButton(.focus)
                    phaseButton(.rest)
                }

                HStack(spacing: 8) {
                    Button {
                        focus.toggle()
                    } label: {
                        Label(focus.isRunning ? "Pause" : focus.isActive ? "Resume" : "Start",
                              systemImage: focus.isRunning ? "pause.fill" : "play.fill")
                            .frame(minWidth: 80)
                    }
                    .buttonStyle(PillButtonStyle(prominent: true))

                    Button { focus.reset() } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(IconButtonStyle(size: 28))
                        .help("Reset")
                        .disabled(!focus.isActive)

                    Button { focus.skip() } label: { Image(systemName: "forward.end.fill") }
                        .buttonStyle(IconButtonStyle(size: 28))
                        .help("Skip to \(focus.phase == .focus ? "break" : "focus")")
                }

                VStack(alignment: .leading, spacing: 8) {
                    minutesStepper("Focus", value: $focus.focusMinutes, range: 5...120, step: 5)
                    minutesStepper("Break", value: $focus.breakMinutes, range: 1...30, step: 1)
                }

                HStack(spacing: 5) {
                    Text("Today")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(0..<min(focus.completedToday, 12), id: \.self) { _ in
                        Circle().fill(Color.orange).frame(width: 7, height: 7)
                    }
                    Text("\(focus.completedToday) session\(focus.completedToday == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func phaseButton(_ phase: FocusTimer.Phase) -> some View {
        let selected = focus.phase == phase
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { focus.select(phase) }
        } label: {
            Label(phase.title, systemImage: phase.icon)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .foregroundStyle(selected ? phase.color : Color.white.opacity(0.55))
                .background(Capsule().fill(selected ? phase.color.opacity(0.18) : Color.white.opacity(0.06)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func minutesStepper(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            Button { value.wrappedValue = max(range.lowerBound, value.wrappedValue - step) } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(IconButtonStyle(size: 22))
            Text("\(value.wrappedValue) min")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .frame(width: 52)
            Button { value.wrappedValue = min(range.upperBound, value.wrappedValue + step) } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(IconButtonStyle(size: 22))
        }
    }
}

/// Countdown shown on either side of the closed notch while a session is active.
struct FocusLiveActivity: View {
    @EnvironmentObject var focus: FocusTimer
    let notchWidth: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 0) {
                Image(systemName: focus.phase.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(focus.phase.color)
                    .frame(maxWidth: .infinity)
                Color.clear.frame(width: notchWidth)
                Text(FocusTimer.format(focus.remaining(at: context.date)))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(focus.phase.color)
                    .frame(maxWidth: .infinity)
            }
            .opacity(focus.isRunning ? 1 : 0.5)
        }
    }
}
