import SwiftUI

/// Paste a script, then it auto-scrolls right under the camera.
struct PrompterView: View {
    @EnvironmentObject var vm: NotchViewModel

    @AppStorage("prompter.script") private var script = ""
    @AppStorage("prompter.speed") private var speed: Double = 30      // points per second
    @AppStorage("prompter.fontSize") private var fontSize: Double = 24

    @State private var isEditing = true
    @State private var baseOffset: CGFloat = 0
    @State private var playStart: Date?
    @State private var textHeight: CGFloat = 0
    @State private var dragStartOffset: CGFloat?

    private var isPlaying: Bool { playStart != nil }

    var body: some View {
        Group {
            if isEditing { editView } else { readView }
        }
        .onAppear { isEditing = script.isEmpty }
        .onDisappear { pause() }
        .onChange(of: speed) { oldSpeed, _ in
            // Rebase so a speed change doesn't make the text jump.
            guard let start = playStart else { return }
            let now = Date()
            baseOffset += CGFloat(now.timeIntervalSince(start) * oldSpeed)
            playStart = now
        }
    }

    // MARK: Edit

    private var editView: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.05))
                if script.isEmpty {
                    Text("Paste or type your script here…")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $script)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
            }

            HStack(spacing: 8) {
                Button {
                    if let s = NSPasteboard.general.string(forType: .string) { script = s }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(PillButtonStyle())

                Button("Clear") { script = "" }
                    .buttonStyle(PillButtonStyle())
                    .disabled(script.isEmpty)

                Spacer()

                Text("\(script.split { $0.isWhitespace }.count) words")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Button {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    baseOffset = 0
                    isEditing = false
                    play()
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .disabled(script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: Read

    private var readView: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                TimelineView(.animation(paused: !isPlaying)) { context in
                    let offset = currentOffset(at: context.date)
                    Text(script)
                        .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                        .lineSpacing(fontSize * 0.25)
                        .multilineTextAlignment(.center)
                        .frame(width: geo.size.width)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(
                            GeometryReader { t in
                                Color.clear
                                    .onAppear { textHeight = t.size.height }
                                    .onChange(of: t.size.height) { _, h in textHeight = h }
                            }
                        )
                        .offset(y: geo.size.height * 0.2 - offset)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                }
                .clipped()
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.15),
                            .init(color: .black, location: 0.8),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if dragStartOffset == nil {
                                pause()
                                dragStartOffset = baseOffset
                            }
                            baseOffset = clamp((dragStartOffset ?? 0) - value.translation.height)
                        }
                        .onEnded { _ in dragStartOffset = nil }
                )
            }

            controls
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button {
                pause()
                isEditing = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(IconButtonStyle())
            .help("Edit script")

            Button {
                pause()
                baseOffset = 0
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .buttonStyle(IconButtonStyle())
            .help("Back to start")

            Button {
                isPlaying ? pause() : play()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 36)
            }
            .buttonStyle(IconButtonStyle())
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / pause (Space)")

            Spacer()

            stepper(icon: "tortoise.fill", value: "\(Int(speed))", help: "Scroll speed") {
                speed = max(5, speed - 5)
            } increment: {
                speed = min(200, speed + 5)
            }

            stepper(icon: "textformat.size", value: "\(Int(fontSize))", help: "Font size") {
                fontSize = max(12, fontSize - 2)
            } increment: {
                fontSize = min(60, fontSize + 2)
            }
        }
    }

    private func stepper(icon: String, value: String, help: String,
                         decrement: @escaping () -> Void, increment: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Button(action: decrement) { Image(systemName: "minus") }
                .buttonStyle(IconButtonStyle(size: 22))
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(value).font(.system(size: 11, weight: .semibold)).monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .frame(minWidth: 44)
            Button(action: increment) { Image(systemName: "plus") }
                .buttonStyle(IconButtonStyle(size: 22))
        }
        .help(help)
    }

    // MARK: Playback

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), max(textHeight, 0))
    }

    private func currentOffset(at date: Date) -> CGFloat {
        var offset = baseOffset
        if let start = playStart {
            offset += CGFloat(date.timeIntervalSince(start) * speed)
        }
        return clamp(offset)
    }

    private func play() {
        if baseOffset >= textHeight, textHeight > 0 { baseOffset = 0 }
        playStart = Date()
        vm.prompterPlaying = true
    }

    private func pause() {
        baseOffset = currentOffset(at: Date())
        playStart = nil
        vm.prompterPlaying = false
    }
}
