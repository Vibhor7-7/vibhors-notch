import AVFoundation
import CoreAudio

/// Mic capture and speaker playback for Apollo, both as PCM16 mono 24 kHz.
///
/// Capture uses AVCaptureSession on the MacBook's built-in mic by default: it delivers
/// 24 kHz PCM16 directly, starts in ~0.1 s, and avoids flipping Bluetooth headphones into
/// their low-quality headset mode. Playback is a separate output-only AVAudioEngine.
/// Push-to-talk stops playback when you press the key, so no echo cancellation is needed.
final class ApolloAudio: NSObject {
    private static let playFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    // Capture
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "apollo.capture.session")
    private let captureQueue = DispatchQueue(label: "apollo.capture.samples")
    private var currentInput: AVCaptureDeviceInput?
    private var onChunk: ((Data) -> Void)?
    private var capturing = false

    // Playback
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var queuedBuffers = 0
    private var generation = 0
    private var stopWork: DispatchWorkItem?

    /// Called on the main thread when playback starts or finishes.
    var onPlayingChanged: ((Bool) -> Void)?

    /// Set `defaults write com.vibhor.notch apollo.useSystemMic -bool true` to use the system default mic.
    private var useSystemMic: Bool { UserDefaults.standard.bool(forKey: "apollo.useSystemMic") }

    override init() {
        super.init()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: captureQueue)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.playFormat)
        // Output device changed (e.g. headphones connected): the engine stops; drop queued audio.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.flushPlayback()
        }
    }

    static func requestMicAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    // MARK: Capture

    /// `onChunk` receives PCM16 24 kHz mono on the main thread.
    func startCapture(_ onChunk: @escaping (Data) -> Void) throws {
        guard let device = preferredMic() else {
            throw NSError(domain: "ApolloAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone found"])
        }
        self.onChunk = onChunk
        capturing = true

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            if self.currentInput?.device != device {
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    if let old = self.currentInput { self.session.removeInput(old) }
                    if self.session.canAddInput(input) { self.session.addInput(input) }
                    self.currentInput = input
                } catch {
                    NSLog("Apollo mic input failed: \(error)")
                }
            }
            if self.session.outputs.isEmpty, self.session.canAddOutput(self.output) {
                self.session.addOutput(self.output)
            }
            self.session.commitConfiguration()
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stopCapture() {
        guard capturing else { return }
        capturing = false
        onChunk = nil
        sessionQueue.async { [weak self] in
            // Let the last in-flight buffer arrive before stopping.
            guard let self, !self.capturing else { return }
            self.session.stopRunning()
        }
    }

    private func preferredMic() -> AVCaptureDevice? {
        if !useSystemMic {
            let mics = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone], mediaType: .audio, position: .unspecified
            ).devices
            if let builtIn = mics.first(where: { $0.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn) }) {
                return builtIn
            }
        }
        return AVCaptureDevice.default(for: .audio)
    }

    // MARK: Playback

    /// Queue PCM16 24 kHz mono for playback. Call on the main thread.
    func play(_ pcm: Data) {
        let frames = pcm.count / 2
        guard frames > 0 else { return }
        stopWork?.cancel()
        if !engine.isRunning {
            do {
                engine.prepare()
                try engine.start()
                // A stopped engine leaves the player reporting isPlaying == true without rendering,
                // so always restart it explicitly.
                player.play()
            } catch {
                NSLog("Apollo playback failed to start: \(error)")
                return
            }
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.playFormat, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            for i in 0..<frames {
                channel[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
            }
        }

        let gen = generation
        queuedBuffers += 1
        if queuedBuffers == 1 { onPlayingChanged?(true) }
        player.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.async { self?.bufferFinished(generation: gen) }
        }
        if !player.isPlaying { player.play() }
    }

    /// Drop everything queued (Apollo was interrupted).
    func flushPlayback() {
        generation += 1
        player.stop()
        if queuedBuffers > 0 {
            queuedBuffers = 0
            onPlayingChanged?(false)
        }
        scheduleEngineStop()
    }

    private func bufferFinished(generation gen: Int) {
        guard gen == generation, queuedBuffers > 0 else { return }
        queuedBuffers -= 1
        if queuedBuffers == 0 {
            onPlayingChanged?(false)
            scheduleEngineStop()
        }
    }

    /// Stop the output engine after a few idle seconds so it doesn't hold the audio device.
    private func scheduleEngineStop() {
        stopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.queuedBuffers == 0, self.engine.isRunning else { return }
            self.player.stop()
            self.engine.stop()
        }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
}

extension ApolloAudio: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.capturing else { return }
            self.onChunk?(data)
        }
    }
}
