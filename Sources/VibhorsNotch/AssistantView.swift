import SwiftUI

/// The Apollo tab: conversation on the left, approvals / tasks / links on the right.
struct AssistantView: View {
    @EnvironmentObject var apollo: ApolloClient
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        if apollo.connected {
            HStack(spacing: 16) {
                conversation
                    .frame(maxWidth: .infinity)
                if !apollo.approvals.isEmpty || !apollo.tasks.isEmpty || !apollo.links.isEmpty {
                    sidebar
                        .frame(width: 260)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: apollo.approvals)
            .animation(.easeInOut(duration: 0.2), value: apollo.tasks)
        } else {
            offline
        }
    }

    // MARK: Conversation

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusDot(state: apollo.state)
                Text(apollo.state.label)
                    .font(.system(size: 12, weight: .semibold))
                if !apollo.composioReady {
                    Text("· apps not connected")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help("Composio isn't available; add COMPOSIO_API_KEY to apollo-assistant/.env")
                }
                Spacer()
                if apollo.state == .speaking {
                    Button { apollo.stopSpeaking() } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(IconButtonStyle(size: 24))
                        .help("Stop speaking")
                }
                Button { apollo.resetConversation() } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(IconButtonStyle(size: 24))
                    .help("New conversation")
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        if apollo.transcript.isEmpty {
                            Text("Hold right ⌘ and talk, or type below. Hold Fn anywhere to dictate.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.top, 20)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(apollo.transcript) { line in
                            TranscriptBubble(line: line).id(line.id)
                        }
                    }
                }
                .onChange(of: apollo.transcript) { _, lines in
                    if let last = lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            if let error = apollo.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                TextField("Ask Apollo…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($inputFocused)
                    .onSubmit {
                        apollo.sendText(draft)
                        draft = ""
                    }
                Button { apollo.toggleAssistant() } label: {
                    Image(systemName: apollo.isCapturing ? "stop.circle.fill" : "mic.fill")
                        .foregroundStyle(apollo.isCapturing ? Color.red : Color.white)
                }
                .buttonStyle(IconButtonStyle(size: 26))
                .help(apollo.isCapturing ? "Send" : "Talk (or hold right ⌘)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.07)))
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(apollo.approvals) { ApprovalCard(approval: $0) }
                ForEach(apollo.links) { link in
                    HStack(spacing: 8) {
                        Image(systemName: "link").foregroundStyle(.cyan)
                        Text(link.title).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button("Open") {
                            if let url = URL(string: link.url) { NSWorkspace.shared.open(url) }
                            apollo.dismissLink(link)
                        }
                        .buttonStyle(PillButtonStyle(prominent: true))
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.cyan.opacity(0.12)))
                }
                ForEach(apollo.tasks.reversed()) { TaskCard(task: $0) }
            }
        }
    }

    private var offline: some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Apollo isn't running")
                .font(.system(size: 14, weight: .semibold))
            Text("In apollo-assistant, run  uv run apollo serve  (or  uv run apollo install-agent  to start it at login).")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StatusDot: View {
    let state: ApolloState
    @State private var pulse = false

    var body: some View {
        let active = [.listening, .thinking, .working, .speaking].contains(state)
        Circle()
            .fill(state.color)
            .frame(width: 8, height: 8)
            .scaleEffect(active && pulse ? 1.35 : 1)
            .opacity(active && pulse ? 0.6 : 1)
            .animation(active ? .easeInOut(duration: 0.7).repeatForever() : .default, value: pulse)
            .onAppear { pulse = true }
    }
}

private struct TranscriptBubble: View {
    let line: ApolloLine

    var body: some View {
        let isUser = line.role == "user"
        HStack {
            if isUser { Spacer(minLength: 40) }
            Text(line.text)
                .font(.system(size: 12.5))
                .foregroundStyle(isUser ? Color.white : Color.white.opacity(line.final ? 0.9 : 0.6))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isUser ? Color.blue.opacity(0.35) : Color.white.opacity(0.08))
                )
                .textSelection(.enabled)
            if !isUser { Spacer(minLength: 40) }
        }
    }
}

private struct ApprovalCard: View {
    @EnvironmentObject var apollo: ApolloClient
    let approval: ApolloApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Approve?", systemImage: "hand.raised.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.yellow)
            Text(approval.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
            ScrollView {
                Text(approval.detail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 80)
            HStack {
                Button("Deny") { apollo.respond(to: approval, approved: false) }
                    .buttonStyle(PillButtonStyle())
                Spacer()
                Button("Approve") { apollo.respond(to: approval, approved: true) }
                    .buttonStyle(PillButtonStyle(prominent: true))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.yellow.opacity(0.1))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.yellow.opacity(0.4)))
        )
    }
}

private struct TaskCard: View {
    let task: ApolloTask

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Group {
                    if !task.isDone {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: task.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(task.failed ? Color.red : Color.green)
                    }
                }
                .font(.system(size: 12))
                .frame(width: 14)
                Text(task.task)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
            }
            if let result = task.result {
                Text(result)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            } else if let step = task.steps.last {
                Text(step)
                    .font(.system(size: 11))
                    .foregroundStyle(.purple.opacity(0.9))
                    .lineLimit(1)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
    }
}

/// Apollo / dictation status shown on either side of the closed notch.
struct ApolloLiveActivity: View {
    @EnvironmentObject var apollo: ApolloClient
    let notchWidth: CGFloat

    var body: some View {
        let dictating = apollo.dictation != .idle
        let color: Color = dictating ? .orange : apollo.state.color
        HStack(spacing: 0) {
            Image(systemName: dictating ? "character.cursor.ibeam" : apollo.state.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: true)
                .frame(maxWidth: .infinity)
            Color.clear.frame(width: notchWidth)
            Text(dictating ? apollo.dictation.label : apollo.state.label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
        }
    }
}
