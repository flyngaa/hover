@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import HoverCore

private struct SystemAudioCaptureError: LocalizedError {
    let operation: String
    let status: OSStatus?

    var errorDescription: String? {
        if let status {
            return
                "Hover couldn't \(operation) (OSStatus \(status)). Enable Hover under System Audio Recording Only in System Settings."
        }
        return "Hover couldn't \(operation)."
    }
}

/// ``AudioCapture`` backed by a Core Audio process tap (system audio) and AVAudioEngine
/// (microphone).
///
/// Owns everything between "start recording" and "here is a chunk of audio":
/// device setup, mixing the two sources, buffering, the flush timer, and the
/// chunking policy (via ``Chunker``). All buffer mutation happens on `mixQueue`.
public final class LiveAudioCapture: NSObject, AudioCapture, @unchecked Sendable {

    // MARK: - Configuration / formats

    private let configuration: RecordingConfiguration
    private var sampleRate: Int { configuration.sampleRate }
    private let pcmFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(RecordingConfiguration.default.sampleRate),
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
    private var eventContinuation: AsyncStream<AudioCaptureEvent>.Continuation?

    // MARK: - Devices

    private var systemTapID = AudioObjectID(kAudioObjectUnknown)
    private var systemAggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var systemIOProcID: AudioDeviceIOProcID?
    private let systemAudioQueue = DispatchQueue(
        label: "transcriber.system-audio", qos: .userInteractive)
    private var audioEngine: AVAudioEngine?
    private var inputSource: InputSource = .both

    private let log: @Sendable (String) -> Void

    public init(
        configuration: RecordingConfiguration = .default,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.log = log
    }

    // MARK: - AudioCapture

    public func start(inputSource: InputSource, retainFullRecording: Bool) async throws
        -> AudioCaptureStart
    {
        let (events, continuation) = AsyncStream<AudioCaptureEvent>.makeStream()
        self.inputSource = inputSource
        mixQueue.sync {
            self.chunker = Chunker()
            self.systemSampleQueue = []
            self.fullRecording = []
            self.retainFullRecording = retainFullRecording
            self.transcribing = false
            self.sysAudioBufferCount = 0
            self.micAudioBufferCount = 0
            self.eventContinuation?.finish()
            self.eventContinuation = continuation
        }

        var systemStarted = false
        var systemAudioFailure: String?

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
                systemAudioFailure = error.localizedDescription
                log(
                    "System audio unavailable, falling back to microphone only: \(error.localizedDescription)"
                )
            }
        }
        if inputSource != .system {
            // Only mix (and therefore need echo cancellation) if system audio
            // is genuinely running. When it fell back to mic-only, mixing is a
            // no-op — and turning on voice processing would needlessly duck the
            // Mac's output volume.
            startMicrophone(mixingSystemAudio: systemStarted)
        }

        await MainActor.run { self.startFlushTimer() }
        return AudioCaptureStart(
            outcome: CaptureOutcome(
                systemStarted: systemStarted,
                systemAudioFailure: systemAudioFailure
            ),
            events: events
        )
    }

    public func stop() async -> CaptureStopResult {
        flushTimer?.invalidate()
        flushTimer = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        stopSystemAudio()

        // Force the final chunk out synchronously, so it has been handed to the
        // transcription callback before we return.
        emitChunk(force: true, synchronously: true)

        return mixQueue.sync {
            eventContinuation?.finish()
            eventContinuation = nil
            return CaptureStopResult(
                fullRecording: retainFullRecording ? fullRecording : nil
            )
        }
    }

    public func noteTranscriptionFinished() async {
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
        let work: @Sendable () -> Void = {
            guard
                let chunk = self.chunker.nextChunk(
                    force: force,
                    transcriptionInFlight: self.transcribing
                )
            else { return }
            self.transcribing = true
            self.eventContinuation?.yield(.chunk(chunk))
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
            self.eventContinuation?.yield(.status(status))
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

    // MARK: - System audio (Core Audio process tap)

    private func startSystemAudio() async throws {
        stopSystemAudio()

        let description = CATapDescription(
            monoGlobalTapButExcludeProcesses: Self.currentProcessAudioObjectID().map { [$0] } ?? []
        )
        description.name = "Hover System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.uuid = UUID()

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try Self.check(
            AudioHardwareCreateProcessTap(description, &tapID),
            operation: "create the system audio tap"
        )
        systemTapID = tapID

        do {
            var tapFormatDescription = AudioStreamBasicDescription()
            var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            try Self.check(
                AudioObjectGetPropertyData(
                    tapID, &propertyAddress, 0, nil, &propertySize, &tapFormatDescription),
                operation: "read the system audio format"
            )
            guard let tapFormat = AVAudioFormat(streamDescription: &tapFormatDescription),
                let converter = AVAudioConverter(from: tapFormat, to: pcmFormat)
            else {
                throw SystemAudioCaptureError(
                    operation: "prepare the system audio converter", status: nil)
            }

            let aggregateUID = "com.hover.desktop.system-audio.\(UUID().uuidString)"
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Hover System Audio",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                        kAudioSubTapDriftCompensationKey: true,
                    ]
                ],
            ]

            var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            try Self.check(
                AudioHardwareCreateAggregateDevice(
                    aggregateDescription as CFDictionary, &aggregateDeviceID),
                operation: "create the system audio input"
            )
            systemAggregateDeviceID = aggregateDeviceID

            var ioProcID: AudioDeviceIOProcID?
            try Self.check(
                AudioDeviceCreateIOProcIDWithBlock(
                    &ioProcID, aggregateDeviceID, systemAudioQueue
                ) { [weak self] _, inputData, _, _, _ in
                    self?.consumeSystemAudio(
                        inputData, format: tapFormat, converter: converter)
                },
                operation: "prepare system audio recording"
            )
            systemIOProcID = ioProcID

            try Self.check(
                AudioDeviceStart(aggregateDeviceID, ioProcID),
                operation: "start system audio recording"
            )
        } catch {
            stopSystemAudio()
            throw error
        }
    }

    private func stopSystemAudio() {
        if systemAggregateDeviceID != kAudioObjectUnknown, let systemIOProcID {
            let stopStatus = AudioDeviceStop(systemAggregateDeviceID, systemIOProcID)
            if stopStatus != noErr {
                log("System audio stop failed (OSStatus \(stopStatus))")
            }
            let destroyStatus = AudioDeviceDestroyIOProcID(
                systemAggregateDeviceID, systemIOProcID)
            if destroyStatus != noErr {
                log("System audio callback cleanup failed (OSStatus \(destroyStatus))")
            }
        }
        systemIOProcID = nil

        if systemAggregateDeviceID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(systemAggregateDeviceID)
            if status != noErr {
                log("System audio input cleanup failed (OSStatus \(status))")
            }
            systemAggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if systemTapID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(systemTapID)
            if status != noErr {
                log("System audio tap cleanup failed (OSStatus \(status))")
            }
            systemTapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func consumeSystemAudio(
        _ inputData: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat,
        converter: AVAudioConverter
    ) {
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData))
        guard let firstBuffer = sourceBuffers.first, firstBuffer.mData != nil,
            format.streamDescription.pointee.mBytesPerFrame > 0
        else { return }

        let frameCount = AVAudioFrameCount(
            firstBuffer.mDataByteSize / format.streamDescription.pointee.mBytesPerFrame)
        guard frameCount > 0,
            let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return }
        source.frameLength = frameCount

        let destinationBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        for (sourceBuffer, destinationBuffer) in zip(sourceBuffers, destinationBuffers) {
            guard let sourceData = sourceBuffer.mData, let destinationData = destinationBuffer.mData
            else { continue }
            memcpy(
                destinationData, sourceData,
                min(Int(sourceBuffer.mDataByteSize), Int(destinationBuffer.mDataByteSize)))
        }

        let convertedFrameCapacity = AVAudioFrameCount(
            ceil(Double(frameCount) * pcmFormat.sampleRate / format.sampleRate))
        guard convertedFrameCapacity > 0,
            let converted = AVAudioPCMBuffer(
                pcmFormat: pcmFormat, frameCapacity: convertedFrameCapacity)
        else { return }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            guard !suppliedInput else {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return source
        }
        guard status != .error, conversionError == nil,
            let samples = converted.floatChannelData?[0]
        else { return }

        let systemSamples = [Float](
            UnsafeBufferPointer(start: samples, count: Int(converted.frameLength)))
        mixQueue.async {
            self.sysAudioBufferCount += 1
            if self.inputSource == .system {
                self.enqueue(systemSamples)
            } else {
                self.systemSampleQueue.append(contentsOf: systemSamples)
                let cap = Int(self.configuration.systemMixBufferSeconds * Double(self.sampleRate))
                if self.systemSampleQueue.count > cap {
                    self.systemSampleQueue.removeFirst(self.systemSampleQueue.count - cap)
                }
            }
        }
    }

    private static func currentProcessAudioObjectID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processID = getpid()
        var audioObjectID = AudioObjectID(kAudioObjectUnknown)
        var outputSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &processID) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                qualifier,
                &outputSize,
                &audioObjectID
            )
        }
        return status == noErr && audioObjectID != kAudioObjectUnknown ? audioObjectID : nil
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw SystemAudioCaptureError(operation: operation, status: status)
        }
    }

    // MARK: - Microphone (AVAudioEngine)

    /// - Parameter mixingSystemAudio: whether system audio is actually running
    ///   and will be mixed into this mic stream.
    /// - Returns: whether the microphone actually started.
    /// Failures are logged rather than reported back: there is nothing the caller
    /// can do about them, and mic-only recording is already the fallback path.
    private func startMicrophone(mixingSystemAudio: Bool) {
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
                log(
                    "Echo cancellation unavailable: \(error.localizedDescription) — use headphones for best quality"
                )
            }
        }

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: recordingFormat, to: pcmFormat) else {
            log("Mic converter unavailable for \(recordingFormat)")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) {
            [weak self] buffer, _ in
            guard let self else { return }
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * self.pcmFormat.sampleRate / recordingFormat.sampleRate)
            guard frameCount > 0,
                let converted = AVAudioPCMBuffer(
                    pcmFormat: self.pcmFormat, frameCapacity: frameCount)
            else { return }
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
        } catch {
            log("Microphone error: \(error.localizedDescription)")
        }
    }
}
