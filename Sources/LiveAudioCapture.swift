import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreGraphics

/// ``AudioCapture`` backed by ScreenCaptureKit (system audio) and AVAudioEngine
/// (microphone).
///
/// Owns everything between "start recording" and "here is a chunk of audio":
/// device setup, mixing the two sources, buffering, the flush timer, and the
/// chunking policy (via ``Chunker``). All buffer mutation happens on `mixQueue`.
final class LiveAudioCapture: NSObject, AudioCapture, SCStreamDelegate, SCStreamOutput {

    var onChunk: ((AudioChunk) -> Void)?
    var onStatus: ((CaptureStatus) -> Void)?

    // MARK: - Configuration / formats

    private let sampleRate = TranscriberEngine.Config.sampleRate
    private let pcmFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(TranscriberEngine.Config.sampleRate),
        channels: 1,
        interleaved: false
    )!

    // MARK: - Queues / timers

    /// Serializes all buffer mutation (system queue, chunker, full recording).
    private let mixQueue = DispatchQueue(label: "transcriber.mix")
    private var flushTimer: Timer?

    // MARK: - State (mixQueue)

    private var chunker = Chunker()
    /// In Both mode, buffered system audio waiting to be mixed into the mic stream.
    private var systemSampleQueue: [Float] = []
    /// The entire recording, kept only when `retainFullRecording` is on.
    private var fullRecording: [Float] = []
    private var retainFullRecording = false
    private var transcribing = false
    private var sysAudioBufferCount = 0
    private var micAudioBufferCount = 0

    // MARK: - Devices

    private var stream: SCStream?
    private var audioEngine: AVAudioEngine?
    private var inputSource: InputSource = .both

    private let log: (String) -> Void

    init(log: @escaping (String) -> Void = { _ in }) {
        self.log = log
    }

    // MARK: - AudioCapture

    func start(inputSource: InputSource, retainFullRecording: Bool) async throws -> CaptureOutcome {
        self.inputSource = inputSource
        mixQueue.sync {
            self.chunker = Chunker()
            self.systemSampleQueue = []
            self.fullRecording = []
            self.retainFullRecording = retainFullRecording
            self.transcribing = false
            self.sysAudioBufferCount = 0
            self.micAudioBufferCount = 0
        }

        var systemStarted = false
        var micStarted = false

        if inputSource != .microphone {
            do {
                try await startSystemAudio()
                systemStarted = true
                log("System audio capture started")
            } catch {
                // System-only mode genuinely can't continue without it.
                if inputSource == .system { throw error }
                // Both mode: keep recording with the microphone instead of
                // failing outright and leaving an empty transcript behind.
                log("System audio unavailable, falling back to microphone only: \(error.localizedDescription)")
            }
        }
        if inputSource != .system {
            // Only mix (and therefore need echo cancellation) if system audio
            // is genuinely running. When it fell back to mic-only, mixing is a
            // no-op — and turning on voice processing would needlessly duck the
            // Mac's output volume.
            micStarted = startMicrophone(mixingSystemAudio: systemStarted)
        }

        await MainActor.run { self.startFlushTimer() }
        return CaptureOutcome(systemStarted: systemStarted, micStarted: micStarted)
    }

    func stop() -> [Float]? {
        flushTimer?.invalidate()
        flushTimer = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        stream?.stopCapture { _ in }
        stream = nil

        // Force the final chunk out synchronously, so it has been handed to the
        // transcription callback before we return.
        emitChunk(force: true, synchronously: true)

        return mixQueue.sync { retainFullRecording ? fullRecording : nil }
    }

    func noteTranscriptionFinished() {
        mixQueue.async { self.transcribing = false }
    }

    // MARK: - Flush timer

    private func startFlushTimer() {
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.emitChunk(force: false, synchronously: false)
            self.emitStatus()
        }
    }

    /// Ask the chunker for a chunk and, if there is one, hand it to `onChunk`.
    /// Must run on `mixQueue`; `synchronously` blocks the caller until done.
    private func emitChunk(force: Bool, synchronously: Bool) {
        let work = {
            guard let chunk = self.chunker.nextChunk(
                force: force,
                transcriptionInFlight: self.transcribing
            ) else { return }
            self.transcribing = true
            self.onChunk?(chunk)
        }
        if synchronously {
            mixQueue.sync(execute: work)
        } else {
            mixQueue.async(execute: work)
        }
    }

    private func emitStatus() {
        mixQueue.async {
            let status = CaptureStatus(
                systemActive: self.sysAudioBufferCount > 0,
                micActive: self.micAudioBufferCount > 0,
                transcribing: self.transcribing
            )
            DispatchQueue.main.async { self.onStatus?(status) }
        }
    }

    // MARK: - Buffering (mixQueue)

    /// Single entry point for audio headed to the chunker. Also retains the full
    /// recording when asked. Must be called on `mixQueue`.
    private func enqueue(_ samples: [Float]) {
        chunker.append(samples)
        if retainFullRecording {
            fullRecording.append(contentsOf: samples)
        }
    }

    /// Appends mic samples, mixing in any buffered system audio in Both mode.
    /// Must be called on `mixQueue`.
    private func appendMic(_ micSamples: [Float]) {
        guard inputSource == .both, !systemSampleQueue.isEmpty else {
            enqueue(micSamples)
            return
        }
        var mixed = micSamples
        let take = min(mixed.count, systemSampleQueue.count)
        for i in 0..<take {
            mixed[i] = max(-1.0, min(1.0, mixed[i] + systemSampleQueue[i]))
        }
        systemSampleQueue.removeFirst(take)
        enqueue(mixed)
    }

    // MARK: - System audio (ScreenCaptureKit)

    private func startSystemAudio() async throws {
        if !CGPreflightScreenCaptureAccess() && !CGRequestScreenCaptureAccess() {
            throw NSError(domain: "Transcriber", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Screen Recording permission required.\n\nGo to: System Settings > Privacy & Security > Screen Recording, enable it for Hover, then relaunch."
            ])
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "Transcriber", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = sampleRate
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream!.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream!.startCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let pcm = Self.makePCMBuffer(from: sampleBuffer) else { return }

        let buffer: AVAudioPCMBuffer
        if pcm.format == pcmFormat {
            buffer = pcm
        } else {
            guard let converter = AVAudioConverter(from: pcm.format, to: pcmFormat) else { return }
            let frameCount = AVAudioFrameCount(Double(pcm.frameLength) * pcmFormat.sampleRate / pcm.format.sampleRate)
            guard frameCount > 0, let converted = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount) else { return }
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return pcm
            }
            guard error == nil else { return }
            buffer = converted
        }

        guard let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        let systemSamples = [Float](UnsafeBufferPointer(start: samples, count: count))

        mixQueue.async {
            self.sysAudioBufferCount += 1
            if self.inputSource == .system {
                // System-only: this stream drives the transcription buffer directly.
                self.enqueue(systemSamples)
            } else {
                // Both: buffer system audio so the mic tap can mix it in. Cap the
                // buffer so it can't grow unbounded if the two streams drift.
                self.systemSampleQueue.append(contentsOf: systemSamples)
                let cap = Int(TranscriberEngine.Config.systemMixBufferSeconds * Double(self.sampleRate))
                if self.systemSampleQueue.count > cap {
                    self.systemSampleQueue.removeFirst(self.systemSampleQueue.count - cap)
                }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("Stream stopped: \(error.localizedDescription)")
    }

    static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
              let data = dataPointer, totalLength > 0 else { return nil }

        let isFloat = asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
        guard let format = AVAudioFormat(
            commonFormat: isFloat ? .pcmFormatFloat32 : .pcmFormatInt16,
            sampleRate: asbd.pointee.mSampleRate,
            channels: AVAudioChannelCount(asbd.pointee.mChannelsPerFrame),
            interleaved: asbd.pointee.mChannelsPerFrame > 1
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        let bytesPerSample = isFloat ? MemoryLayout<Float>.size : MemoryLayout<Int16>.size
        let byteCount = min(totalLength, Int(buffer.frameLength) * bytesPerSample * Int(format.channelCount))

        if let dst = buffer.floatChannelData {
            memcpy(dst[0], data, byteCount)
        } else if let dst = buffer.int16ChannelData {
            memcpy(dst[0], data, byteCount)
        } else {
            return nil
        }
        return buffer
    }

    // MARK: - Microphone (AVAudioEngine)

    /// - Parameter mixingSystemAudio: whether system audio is actually running
    ///   and will be mixed into this mic stream.
    /// - Returns: whether the microphone actually started.
    private func startMicrophone(mixingSystemAudio: Bool) -> Bool {
        audioEngine = AVAudioEngine()
        let inputNode = audioEngine!.inputNode

        // Echo cancellation strips this Mac's own speaker output from the mic.
        // That's essential when mixing with system audio (prevents doubled
        // words), but it also puts the audio hardware into voice-chat mode,
        // which ducks the Mac's output volume. So only enable it when we're
        // genuinely mixing — not in mic-only mode or when system audio fell back.
        if mixingSystemAudio {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                // Voice processing otherwise ducks all other audio hard (that's
                // why the Mac's volume plunged). Dial that ducking down to its
                // minimum so the user still hears system audio at full volume
                // while echo cancellation keeps the mic clean.
                if #available(macOS 14.0, *) {
                    inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                            enableAdvancedDucking: false,
                            duckingLevel: .min
                        )
                }
                log("Echo cancellation enabled")
            } catch {
                log("Echo cancellation unavailable: \(error.localizedDescription) — use headphones for best quality")
            }
        }

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: recordingFormat, to: pcmFormat) else {
            log("Mic converter unavailable for \(recordingFormat)")
            return false
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * self.pcmFormat.sampleRate / recordingFormat.sampleRate)
            guard frameCount > 0,
                  let converted = AVAudioPCMBuffer(pcmFormat: self.pcmFormat, frameCapacity: frameCount) else { return }
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, let samples = converted.floatChannelData?[0] else { return }

            let count = Int(converted.frameLength)
            let micSamples = [Float](UnsafeBufferPointer(start: samples, count: count))
            self.mixQueue.async {
                self.micAudioBufferCount += 1
                // The mic tap fires continuously while recording, so it drives
                // the transcription buffer. In Both mode we mix in whatever
                // system audio has been buffered; if system audio is unavailable
                // the mic still flows through on its own so the transcript is
                // never silently empty.
                self.appendMic(micSamples)
            }
        }

        audioEngine!.prepare()
        do {
            try audioEngine!.start()
            log("Microphone started")
            return true
        } catch {
            log("Microphone error: \(error.localizedDescription)")
            return false
        }
    }
}
