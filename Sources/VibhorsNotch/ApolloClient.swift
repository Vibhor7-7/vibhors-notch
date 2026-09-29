import AppKit
import SwiftUI

// MARK: - Models

struct ApolloLine: Identifiable, Equatable {
    let id: String
    var role: String // "user" | "assistant"
    var text: String
    var final: Bool
}

struct ApolloTask: Identifiable, Equatable {
    let id: Int
    var task: String
    var steps: [String] = []
    var result: String?
    var failed = false
    var isDone: Bool { result != nil }
}

struct ApolloApproval: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
}

struct ApolloLink: Identifiable, Equatable {
    var id: String { url }
    let title: String
    let url: String
}

enum ApolloState: String {
    case offline, idle, listening, thinking, working, speaking

    var label: String {
        switch self {
        case .offline: "Offline"
        case .idle: "Ready"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .working: "Working"
        case .speaking: "Speaking"
        }
    }

    var icon: String {
        switch self {
        case .offline: "bolt.horizontal.circle"
        case .idle: "sparkles"
        case .listening: "waveform"
        case .thinking: "ellipsis"
        case .working: "gearshape.2.fill"
        case .speaking: "speaker.wave.2.fill"
        }
    }

    var color: Color {
        switch self {
        case .offline: .gray
        case .idle: .white
        case .listening: .red
        case .thinking, .working: .purple
        case .speaking: .cyan
        }
    }
}

enum DictationState: String {
    case idle, recording, transcribing, polishing

    var label: String {
        switch self {
        case .idle: ""
        case .recording: "Dictating"
        case .transcribing, .polishing: "Writing"
        }
    }
}

// MARK: - Client

/// Connects the notch to the local Apollo service (`apollo serve`) and drives mic/speaker audio.
final class ApolloClient: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var composioReady = false
    @Published private(set) var serverState = "idle"
    @Published private(set) var isCapturing = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var transcript: [ApolloLine] = []
    @Published private(set) var tasks: [ApolloTask] = []
    @Published private(set) var approvals: [ApolloApproval] = []
    @Published private(set) var links: [ApolloLink] = []
    @Published private(set) var dictation: DictationState = .idle
    @Published private(set) var lastError: String?

    var onApprovalRequest: (() -> Void)?
    var onAddTask: ((String) -> Void)?
    var onStartFocus: ((Int) -> Void)?

    private let audio = ApolloAudio()
    private let hotkeys = HotkeyMonitor()
    private let session = URLSession(configuration: .default)
    private var socket: URLSessionWebSocketTask?
    private var reconnectDelay: TimeInterval = 1
    private var errorClearWork: DispatchWorkItem?
    // Whether the push-to-talk key is still down (mic permission can answer after release).
    private var assistantHeld = false
    private var dictationHeld = false
    private var dictationBytes = 0

    private static let port = UserDefaults.standard.object(forKey: "apollo.port") as? Int ?? 8765
    private static let tokenURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Apollo/token")

    private enum Channel: UInt8 {
        case assistantMic = 1, dictationMic = 2, assistantSpeaker = 3
    }

    var state: ApolloState {
        if !connected { return .offline }
        if isCapturing { return .listening }
        if isSpeaking { return .speaking }
        return ApolloState(rawValue: serverState) ?? .idle
    }

    /// Whether the closed notch should show Apollo's status in its ears.
    var showsLiveActivity: Bool {
        dictation != .idle || [.listening, .thinking, .working, .speaking].contains(state)
    }

    init() {
        audio.onPlayingChanged = { [weak self] playing in self?.isSpeaking = playing }
        hotkeys.onPress = { [weak self] key in
            switch key {
            case .rightCommand: self?.startAssistant()
            case .function: self?.startDictation()
            }
        }
        hotkeys.onRelease = { [weak self] key, cancelled in
            switch key {
            case .rightCommand: self?.stopAssistant(cancel: cancelled)
            case .function: self?.stopDictation(cancel: cancelled)
            }
        }
    }

    func start() {
        let trusted = HotkeyMonitor.ensureAccessibility(prompt: true)
        NSLog("Apollo: Accessibility trusted = \(trusted)")
        hotkeys.start()
        connect()
    }

    // MARK: Assistant

    func startAssistant() {
        guard connected, !isCapturing, dictation == .idle else { return }
        assistantHeld = true
        ApolloAudio.requestMicAccess { [weak self] granted in
            guard let self, self.assistantHeld else { return }
            guard granted else { return self.showError("Microphone access is off for Vibhor's Notch.") }
            self.audio.flushPlayback()
            self.send(["type": "assistant.start"])
            do {
                try self.audio.startCapture { [weak self] pcm in self?.sendAudio(.assistantMic, pcm) }
                self.isCapturing = true
            } catch {
                self.send(["type": "assistant.cancel"])
                self.showError("Mic error: \(error.localizedDescription)")
            }
        }
    }

    func stopAssistant(cancel: Bool = false) {
        assistantHeld = false
        guard isCapturing else { return }
        audio.stopCapture()
        isCapturing = false
        send(["type": cancel ? "assistant.cancel" : "assistant.stop"])
    }

    func toggleAssistant() {
        isCapturing ? stopAssistant() : startAssistant()
    }

    func sendText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        audio.flushPlayback()
        send(["type": "assistant.text", "text": trimmed])
    }

    func stopSpeaking() {
        audio.flushPlayback()
        send(["type": "assistant.cancel"])
    }

    func respond(to approval: ApolloApproval, approved: Bool) {
        approvals.removeAll { $0.id == approval.id }
        send(["type": "approval.response", "id": approval.id, "approved": approved])
    }

    func resetConversation() {
        send(["type": "assistant.reset"])
        transcript.removeAll()
        tasks.removeAll { $0.isDone }
        links.removeAll()
    }

    func dismissLink(_ link: ApolloLink) {
        links.removeAll { $0 == link }
    }

    // MARK: Dictation

    func startDictation() {
        guard !isCapturing, dictation == .idle else { return }
        guard connected else { return showError("Apollo isn't running — start it with `apollo serve`.") }
        dictationHeld = true
        ApolloAudio.requestMicAccess { [weak self] granted in
            guard let self, self.dictationHeld else { return }
            guard granted else { return self.showError("Microphone access is off for Vibhor's Notch.") }
            self.send(["type": "dictation.start"])
            do {
                self.dictationBytes = 0
                try self.audio.startCapture { [weak self] pcm in
                    self?.dictationBytes += pcm.count
                    self?.sendAudio(.dictationMic, pcm)
                }
                self.dictation = .recording
            } catch {
                self.send(["type": "dictation.cancel"])
                self.showError("Mic error: \(error.localizedDescription)")
            }
        }
    }

    func stopDictation(cancel: Bool = false) {
        dictationHeld = false
        guard dictation == .recording else { return }
        NSLog("Apollo dictation: stop (cancel=\(cancel)), sent \(dictationBytes) bytes of audio")
        audio.stopCapture()
        send(["type": cancel ? "dictation.cancel" : "dictation.stop"])
        dictation = cancel ? .idle : .transcribing
    }

    // MARK: Connection

    private func connect() {
        guard socket == nil else { return }
        guard let token = try? String(contentsOf: Self.tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty,
              let url = URL(string: "ws://127.0.0.1:\(Self.port)")
        else { return scheduleReconnect() }

        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 4 << 20
        socket = task
        task.resume()
        send(["type": "hello", "token": token])
        receive(on: task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.socket === task else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    self.receive(on: task)
                case .failure:
                    self.disconnected()
                }
            }
        }
    }

    private func disconnected() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        if connected { NSLog("Apollo: disconnected") }
        connected = false
        if isCapturing { audio.stopCapture(); isCapturing = false }
        if dictation == .recording { audio.stopCapture() }
        dictation = .idle
        audio.flushPlayback()
        approvals.removeAll()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 10)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }

    private func send(_ object: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func sendAudio(_ channel: Channel, _ pcm: Data) {
        guard let socket else { return }
        var frame = Data([channel.rawValue])
        frame.append(pcm)
        socket.send(.data(frame)) { _ in }
    }

    // MARK: Incoming

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            if data.first == Channel.assistantSpeaker.rawValue {
                audio.play(data.dropFirst())
            }
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = msg["type"] as? String else { return }
            handle(type: type, msg)
        @unknown default:
            break
        }
    }

    private func handle(type: String, _ msg: [String: Any]) {
        switch type {
        case "ready":
            connected = true
            reconnectDelay = 1
            serverState = msg["status"] as? String ?? "idle"
            composioReady = msg["composio"] as? Bool ?? false
            // A (re)started server numbers tasks from 1 again and has no pending approvals.
            tasks.removeAll()
            approvals.removeAll()

        case "status":
            serverState = msg["state"] as? String ?? "idle"

        case "transcript":
            guard let id = msg["id"] as? String, let text = msg["text"] as? String, !text.isEmpty else { return }
            let line = ApolloLine(id: id, role: msg["role"] as? String ?? "assistant", text: text,
                                  final: msg["final"] as? Bool ?? true)
            if let i = transcript.firstIndex(where: { $0.id == id }) {
                transcript[i] = line
            } else {
                transcript.append(line)
                if transcript.count > 60 { transcript.removeFirst(transcript.count - 60) }
            }

        case "transcript.reset":
            transcript.removeAll()

        case "task.started":
            guard let id = msg["id"] as? Int else { return }
            tasks.append(ApolloTask(id: id, task: msg["task"] as? String ?? ""))
            if tasks.count > 8 { tasks.removeFirst() }

        case "task.step":
            guard let id = msg["id"] as? Int, let text = msg["text"] as? String,
                  let i = tasks.firstIndex(where: { $0.id == id }) else { return }
            tasks[i].steps.append(text)

        case "task.done", "task.failed":
            guard let id = msg["id"] as? Int, let i = tasks.firstIndex(where: { $0.id == id }) else { return }
            tasks[i].failed = type == "task.failed"
            tasks[i].result = (msg["result"] ?? msg["error"]) as? String ?? ""

        case "approval.request":
            guard let id = msg["id"] as? String else { return }
            approvals.append(ApolloApproval(id: id, title: msg["title"] as? String ?? "Approve action",
                                            detail: msg["detail"] as? String ?? ""))
            onApprovalRequest?()

        case "approval.resolved":
            let id = msg["id"] as? String
            approvals.removeAll { $0.id == id }

        case "link":
            guard let url = msg["url"] as? String else { return }
            let link = ApolloLink(title: msg["title"] as? String ?? "Open link", url: url)
            if !links.contains(link) { links.append(link) }
            onApprovalRequest?() // surface it the same way

        case "audio.interrupt":
            audio.flushPlayback()

        case "dictation.state":
            dictation = DictationState(rawValue: msg["state"] as? String ?? "idle") ?? .idle

        case "dictation.result":
            guard let text = msg["text"] as? String, !text.isEmpty else { return }
            if HotkeyMonitor.ensureAccessibility(prompt: false) {
                NSLog("Apollo dictation: inserting \(text.count) characters")
                TextInserter.insert(text)
            } else {
                // Without Accessibility we can't paste; leave the text on the clipboard instead.
                NSLog("Apollo dictation: not trusted for Accessibility; copied to clipboard")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                showError("Dictation copied to clipboard. Allow Vibhor's Notch in Accessibility settings to paste automatically.")
            }

        case "dictation.error":
            showError("Dictation failed: \(msg["message"] as? String ?? "unknown error")")

        case "notch.add_task":
            if let title = msg["title"] as? String { onAddTask?(title) }

        case "notch.focus":
            if let minutes = msg["minutes"] as? Int { onStartFocus?(minutes) }

        case "error":
            showError(msg["message"] as? String ?? "Something went wrong")

        default:
            break
        }
    }

    private func showError(_ message: String) {
        lastError = message
        errorClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.lastError = nil }
        errorClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }
}
