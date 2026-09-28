import SwiftUI

// MARK: - Spotify (AppleScript)

struct SpotifyTrack: Equatable {
    var id: String
    var name: String
    var artist: String
    var album: String
    var artworkURL: String
    var duration: Double // seconds
}

/// Talks to Spotify through its AppleScript dictionary. Never launches Spotify by itself.
final class SpotifyController: ObservableObject {
    static let bundleID = "com.spotify.client"

    @Published private(set) var isRunning = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var track: SpotifyTrack?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var isPlaying = false
    @Published private(set) var shuffling = false
    @Published private(set) var repeating = false
    @Published private(set) var volume: Double = 50

    /// Last known position, advanced locally between polls.
    private var position: Double = 0
    private var positionDate = Date()

    private let queue = DispatchQueue(label: "com.vibhor.notch.spotify")
    private var pollTimer: Timer?
    private var volumeWork: DispatchWorkItem?
    private var lastVolumeChange = Date.distantPast

    private static let separator = "|~|"
    private static let stateScript = """
    if application "Spotify" is running then
        tell application "Spotify"
            if player state is stopped then return "stopped"
            set t to current track
            set s to "\(separator)"
            return (player state as string) & s & (name of t) & s & (artist of t) & s & (album of t) & s & (artwork url of t) & s & (duration of t) & s & (player position) & s & (shuffling as string) & s & (repeating as string) & s & (sound volume) & s & (id of t)
        end tell
    end if
    return "closed"
    """

    init() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil
    }

    func currentPosition(at date: Date = Date()) -> Double {
        guard let track else { return 0 }
        let p = isPlaying ? position + date.timeIntervalSince(positionDate) : position
        return min(max(p, 0), track.duration)
    }

    // MARK: Polling

    func startPolling() {
        stopPolling()
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refresh() {
        isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        guard isRunning else {
            clearTrack()
            return
        }
        run(Self.stateScript) { [weak self] output in
            self?.apply(output)
        }
    }

    private func apply(_ output: String?) {
        guard let output else { return }
        let f = output.components(separatedBy: Self.separator)
        guard f.count >= 11 else {
            clearTrack()
            return
        }

        let newTrack = SpotifyTrack(
            id: f[10], name: f[1], artist: f[2], album: f[3], artworkURL: f[4],
            duration: (Double(f[5]) ?? 0) / 1000
        )
        if newTrack.artworkURL != track?.artworkURL { loadArtwork(newTrack.artworkURL) }
        track = newTrack
        isPlaying = f[0] == "playing"
        position = Double(f[6].replacingOccurrences(of: ",", with: ".")) ?? 0
        positionDate = Date()
        shuffling = f[7] == "true"
        repeating = f[8] == "true"
        // Don't fight the slider while the user is dragging it.
        if Date().timeIntervalSince(lastVolumeChange) > 1.5 {
            volume = Double(f[9]) ?? volume
        }
    }

    private func clearTrack() {
        track = nil
        artwork = nil
        isPlaying = false
    }

    private func loadArtwork(_ urlString: String) {
        guard let url = URL(string: urlString), !urlString.isEmpty else {
            artwork = nil
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let image = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async {
                guard let self, self.track?.artworkURL == urlString else { return }
                self.artwork = image
            }
        }.resume()
    }

    // MARK: Commands

    func playPause() {
        position = currentPosition()
        positionDate = Date()
        isPlaying.toggle()
        command("playpause")
    }

    func next() { command("next track") }
    func previous() { command("previous track") }

    func seek(to seconds: Double) {
        position = seconds
        positionDate = Date()
        command("set player position to \(seconds)")
    }

    func toggleShuffle() {
        shuffling.toggle()
        command("set shuffling to \(shuffling)")
    }

    func toggleRepeat() {
        repeating.toggle()
        command("set repeating to \(repeating)")
    }

    func setVolume(_ value: Double) {
        volume = value
        lastVolumeChange = Date()
        volumeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.command("set sound volume to \(Int(value))", refreshAfter: false)
        }
        volumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    func openSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
    }

    private func command(_ command: String, refreshAfter: Bool = true) {
        guard isRunning else { return }
        run("tell application \"Spotify\" to \(command)") { [weak self] _ in
            guard refreshAfter else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.refresh() }
        }
    }

    /// Runs AppleScript off the main thread; completion is called on main.
    private func run(_ source: String, completion: @escaping (String?) -> Void) {
        queue.async { [weak self] in
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            let output = result?.stringValue
            let code = error?[NSAppleScript.errorNumber] as? Int
            DispatchQueue.main.async {
                // -1743: user hasn't allowed us to control Spotify (Automation permission).
                self?.permissionDenied = code == -1743
                completion(error == nil ? output : nil)
            }
        }
    }
}

// MARK: - Views

struct MediaView: View {
    @EnvironmentObject var spotify: SpotifyController

    var body: some View {
        Group {
            if !spotify.isInstalled {
                placeholder(icon: "music.note", text: "Spotify isn't installed.", showOpen: false)
            } else if !spotify.isRunning {
                placeholder(icon: "music.note", text: "Spotify isn't running.", showOpen: true)
            } else if spotify.permissionDenied {
                VStack(spacing: 10) {
                    Image(systemName: "lock.fill").font(.system(size: 24)).foregroundStyle(.secondary)
                    Text("Allow Vibhor's Notch to control Spotify in Privacy & Security → Automation.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Open Automation Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                    }
                    .buttonStyle(PillButtonStyle(prominent: true))
                }
                .frame(maxWidth: 360)
            } else if let track = spotify.track {
                PlayerView(track: track)
            } else {
                placeholder(icon: "play.circle", text: "Nothing playing.", showOpen: true)
            }
        }
        .onAppear { spotify.startPolling() }
        .onDisappear { spotify.stopPolling() }
    }

    private func placeholder(icon: String, text: String, showOpen: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            if showOpen {
                Button("Open Spotify") { spotify.openSpotify() }
                    .buttonStyle(PillButtonStyle(prominent: true))
            }
        }
    }
}

private struct PlayerView: View {
    @EnvironmentObject var spotify: SpotifyController
    let track: SpotifyTrack

    var body: some View {
        HStack(spacing: 20) {
            artwork
                .frame(width: 170, height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                .onTapGesture { spotify.openSpotify() }
                .help("Open Spotify")

            VStack(alignment: .leading, spacing: 0) {
                Text(track.name)
                    .font(.system(size: 18, weight: .bold))
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .padding(.top, 2)
                Text(track.album)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 1)

                Spacer(minLength: 8)

                SeekBar(duration: track.duration)

                controls
                    .padding(.top, 8)

                volume
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = spotify.artwork {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.08))
                .overlay(Image(systemName: "music.note").font(.system(size: 36)).foregroundStyle(.secondary))
        }
    }

    private var controls: some View {
        HStack(spacing: 0) {
            toggleButton(icon: "shuffle", isOn: spotify.shuffling, help: "Shuffle") { spotify.toggleShuffle() }
            Spacer()
            controlButton(icon: "backward.fill", size: 18) { spotify.previous() }
            Spacer()
            Button { spotify.playPause() } label: {
                Image(systemName: spotify.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 38))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            Spacer()
            controlButton(icon: "forward.fill", size: 18) { spotify.next() }
            Spacer()
            toggleButton(icon: "repeat", isOn: spotify.repeating, help: "Repeat") { spotify.toggleRepeat() }
        }
        .padding(.horizontal, 4)
    }

    private var volume: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Slider(value: Binding(get: { spotify.volume }, set: { spotify.setVolume($0) }), in: 0...100)
                .controlSize(.mini)
                .tint(.white)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func controlButton(icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleButton(icon: String, isOn: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? Color.green : Color.white.opacity(0.5))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Progress bar that advances smoothly between polls and can be dragged to seek.
private struct SeekBar: View {
    @EnvironmentObject var spotify: SpotifyController
    let duration: Double
    @State private var dragValue: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let current = dragValue ?? spotify.currentPosition(at: context.date)
            VStack(spacing: 4) {
                GeometryReader { geo in
                    let fraction = duration > 0 ? CGFloat(current / duration) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(Color.white)
                            .frame(width: max(0, min(1, fraction)) * geo.size.width)
                    }
                    .frame(height: dragValue == nil ? 4 : 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let f = min(max(value.location.x / geo.size.width, 0), 1)
                                dragValue = Double(f) * duration
                            }
                            .onEnded { _ in
                                if let dragValue { spotify.seek(to: dragValue) }
                                dragValue = nil
                            }
                    )
                }
                .frame(height: 10)

                HStack {
                    Text(format(current))
                    Spacer()
                    Text("-" + format(max(duration - current, 0)))
                }
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
        }
    }

    private func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
