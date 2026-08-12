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
/// device setup, the flush timer, and the chunking policy (via ``TrackChunker``).
/// In Both mode mic and system stay on separate tracks — never sum-mixed — so
/// transcription can label ``AudioSource``; each pipe stamps its samples with the
/// time they arrived on one shared session clock. All buffer mutation happens on
/// `captureQueue`.
public final class LiveAudioCapture: NSObject, AudioCapture, @unchecked Sendable {

    // MARK: - Configuration / formats

    private let configuration: RecordingConfiguration
    private let pcmFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(RecordingConfiguration.default.sampleRate),
        channels: 1,
        interleaved: false
    )!

    // MARK: - Queues / timers

    /// Serializes all buffer mutation (per-source chunkers).
    private let captureQueue = DispatchQueue(label: "transcriber.capture")
    private var flushTimer: Timer?

    // MARK: - State (captureQueue)

    private var tracks = TrackChunker(sources: AudioSource.allCases)
    private var transcribing = false
    /// Buffers received from each pipe since the last status was published, so
    /// "sys ✓ / mic ✓" means "delivering now", not "delivered once at the start".
    private var sysAudioBufferCount = 0
    private var micAudioBufferCount = 0
    /// Session times the mic watchdog reads: when a buffer last arrived, and when
    /// one last contained anything other than silence.
    private var lastMicBufferTime: Double = 0
    private var lastMicSignalTime: Double = 0
    /// Whether the mic has ever handed over a sample that wasn't zero.
    private var micHasSignal = false
    private var eventContinuation: AsyncStream<AudioCaptureEvent>.Continuation?

    // MARK: - Devices

    private var systemTapID = AudioObjectID(kAudioObjectUnknown)
    private var systemAggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var systemIOProcID: AudioDeviceIOProcID?
    private let systemAudioQueue = DispatchQueue(
        label: "transcriber.system-audio", qos: .userInteractive)
    private var audioEngine: AVAudioEngine?

    // MARK: - Microphone health (main queue)

    /// Whether this recording asked for the microphone at all.
    private var micRequested = false
    /// Whether the mic is currently running with echo cancellation.
    private var micEchoCancelling = false
    private var micRestartAttempts = 0

    // MARK: - Session clock

    /// Uptime at the moment capture began; written once in `start`, before any
    /// audio callback can run. Both pipes time-stamp their samples against it, so
    /// mic and system chunks land on one comparable timeline no matter how much
    /// audio each pipe has actually delivered.
    private var sessionStart: TimeInterval = 0

    /// Seconds since capture began, read in the audio callback that received the
    /// samples rather than after the hop onto `captureQueue`.
    private var elapsedSessionTime: Double {
        ProcessInfo.processInfo.systemUptime - sessionStart
    }

    private let log: @Sendable (String) -> Void

    public init(
        configuration: RecordingConfiguration = .default,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.log = log
    }

    // MARK: - AudioCapture

    public func start(inputSource: InputSource) async throws -> AudioCaptureStart {
        let (events, continuation) = AsyncStream<AudioCaptureEvent>.makeStream()
        sessionStart = ProcessInfo.processInfo.systemUptime
        captureQueue.sync {
            self.tracks = TrackChunker(
                sources: Self.sources(for: inputSource),
                configuration: self.configuration
            )
            self.transcribing = false
            self.sysAudioBufferCount = 0
            self.micAudioBufferCount = 0
            self.lastMicBufferTime = 0
            self.lastMicSignalTime = 0
            self.micHasSignal = false
            self.eventContinuation?.finish()
            self.eventContinuation = continuation
        }
        micRequested = inputSource != .system
        micRestartAttempts = 0

        var systemStarted = false

        if inputSource != .microphone {
            do {
                try await startSystemAudio()
                systemStarted = true
                log("System audio capture started")
            } catch {
                // Don't start a partial Both recording — the permission sheet
                // (or Agent Mode fallback) decides whether to retry mic-only.
                captureQueue.sync {
                    self.eventContinuation?.finish()
                    self.eventContinuation = nil
                }
                throw error
            }
        }
        if inputSource != .system {
            // Keep AEC when system capture is active so the Mic track doesn't
            // re-record System Audio as a second copy.
            startMicrophone(echoCancellingSystemAudio: systemStarted)
        }

        await MainActor.run { self.startFlushTimer() }
        return AudioCaptureStart(
            outcome: CaptureOutcome(systemStarted: systemStarted),
            events: events
        )
    }

    public func stop() async {
        flushTimer?.invalidate()
        flushTimer = nil
        micRequested = false

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        stopSystemAudio()

        // Force final chunks out synchronously so both tracks have been handed
        // to the consumer before the stream finishes.
        emitChunk(force: true, synchronously: true)

        captureQueue.sync {
            eventContinuation?.finish()
            eventContinuation = nil
        }
    }

    public func noteTranscriptionFinished() async {
        captureQueue.async { self.transcribing = false }
    }

    private static func sources(for inputSource: InputSource) -> [AudioSource] {
        switch inputSource {
        case .both: return [.microphone, .system]
        case .microphone: return [.microphone]
        case .system: return [.system]
        }
    }

    // MARK: - Flush timer

    private func startFlushTimer() {
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.emitChunk(force: false, synchronously: false)
            self.emitStatus()
            self.checkMicrophoneIsDelivering()
        }
    }

    /// Ask ``TrackChunker`` whose turn it is and yield that chunk. Serial Whisper:
    /// only one chunk is in flight unless `force` is draining every track at stop.
    /// Must run on `captureQueue`; `synchronously` blocks the caller until done.
    private func emitChunk(force: Bool, synchronously: Bool) {
        let work: @Sendable () -> Void = {
            if force {
                while let chunk = self.tracks.nextChunk(force: true) {
                    self.yieldChunk(chunk)
                }
                return
            }
            guard !self.transcribing else { return }
            guard let chunk = self.tracks.nextChunk(force: false) else { return }
            self.yieldChunk(chunk)
        }
        if synchronously {
            captureQueue.sync(execute: work)
        } else {
            captureQueue.async(execute: work)
        }
    }

    /// Must run on `captureQueue`. Logs which track each chunk came from: in Both
    /// mode that's the only way to see from outside that neither pipe is stalled.
    private func yieldChunk(_ chunk: AudioChunk) {
        transcribing = true
        log(
            String(
                format: "%@ chunk %.1fs–%.1fs",
                chunk.source.label, chunk.startTime, chunk.endTime
            )
        )
        eventContinuation?.yield(.chunk(chunk))
    }

    private func emitStatus() {
        captureQueue.async {
            let status = CaptureStatus(
                systemActive: self.sysAudioBufferCount > 0,
                micActive: self.micAudioBufferCount > 0,
                transcribing: self.transcribing
            )
            // Counted per status rather than for the whole session: a pipe that
            // died after its first buffer has to stop reporting itself as active.
            self.sysAudioBufferCount = 0
            self.micAudioBufferCount = 0
            self.eventContinuation?.yield(.status(status))
        }
    }

    /// A silent microphone is Hover's worst failure in Both mode: the recording
    /// looks healthy and saves a transcript with nothing but System lines. There
    /// are two ways to get there, and neither reports an error, so the mic is
    /// watched rather than trusted.
    ///
    /// The engine can stop handing over buffers entirely — a change to the audio
    /// hardware configuration (creating the system audio tap's aggregate device is
    /// one) can leave it running but mute. Or the echo cancellation unit can hand
    /// over buffers of pure zeroes, which happens on some audio hardware and only
    /// ever shows up as a missing Mic track. Either way, rebuild the engine, and
    /// give up echo cancellation rather than the Mic track.
    private func checkMicrophoneIsDelivering() {
        guard micRequested, micRestartAttempts < 2 else { return }
        let (sinceBuffer, sinceSignal, hasSignal) = captureQueue.sync {
            let now = self.elapsedSessionTime
            return (
                now - self.lastMicBufferTime, now - self.lastMicSignalTime, self.micHasSignal
            )
        }

        let stalled = sinceBuffer > 3
        // Only ever true before the first real sample, so a user who simply isn't
        // talking can't trip it mid-recording.
        let zeroedFromTheStart = micEchoCancelling && !hasSignal && sinceSignal > 3
        guard stalled || zeroedFromTheStart else { return }

        micRestartAttempts += 1
        // Echo cancellation is worth keeping through a rebuild when the mic had
        // been working; when it never produced a sample, it is the suspect.
        let keepEchoCancelling = micEchoCancelling && hasSignal && stalled
        log(
            String(
                format: "Microphone %@ for %.1fs — restarting it%@",
                stalled ? "handed over nothing" : "handed over silence only",
                stalled ? sinceBuffer : sinceSignal,
                micEchoCancelling && !keepEchoCancelling
                    ? " without echo cancellation (system audio may echo onto the Mic track)"
                    : ""
            )
        )
        restartMicrophone(echoCancellingSystemAudio: keepEchoCancelling)
    }

    // MARK: - Buffering (captureQueue)

    /// Hand samples to their track. Must be called on `captureQueue`.
    /// `arrivedAt` is when the audio callback received them, on the session clock.
    private func enqueue(_ samples: [Float], source: AudioSource, arrivedAt: Double) {
        tracks.append(samples, from: source, endingAt: arrivedAt)
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
        let arrivedAt = elapsedSessionTime
        captureQueue.async {
            self.sysAudioBufferCount += 1
            self.enqueue(systemSamples, source: .system, arrivedAt: arrivedAt)
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

    /// - Parameter echoCancellingSystemAudio: whether system audio is actually
    ///   running alongside the mic (Both mode). Enables voice processing so the
    ///   Mic track is not a second copy of System Audio.
    /// Failures are logged rather than reported back: there is nothing the caller
    /// can do about them, and mic-only recording is already the fallback path.
    private func startMicrophone(echoCancellingSystemAudio: Bool) {
        let engine = AVAudioEngine()
        audioEngine = engine
        let inputNode = engine.inputNode
        micEchoCancelling = false

        // Echo cancellation strips this Mac's own speaker output from the mic.
        // Essential in Both mode (prevents duplicated System lines on the Mic
        // track), but it also puts the audio hardware into voice-chat mode,
        // which ducks the Mac's output volume. Only enable when system audio is
        // genuinely running — not in mic-only mode or when system audio fell back.
        if echoCancellingSystemAudio {
            // The voice-processing unit is duplex: it hands over input only while
            // its render side is running. An input-only graph leaves the tap with
            // silence — a Both-mode recording whose Mic track is empty. Touching
            // the main mixer connects it to the output node, which gives the unit
            // a render side to run; muted, and with nothing routed into it, so the
            // mic is never played back through the speakers.
            //
            // It has to be connected *before* voice processing is enabled, which
            // re-negotiates the connections already in the graph down to the
            // unit's own rate. A mixer connected afterwards keeps its default
            // 44.1 kHz, the output node then refuses to initialize (OSStatus
            // -10875), and starting the engine throws — no Mic track at all.
            engine.mainMixerNode.outputVolume = 0
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
                micEchoCancelling = true
                log("Echo cancellation enabled")
            } catch {
                log(
                    "Echo cancellation unavailable: \(error.localizedDescription) — use headphones for best quality"
                )
            }
        }

        // Read the format *after* voice processing: enabling it re-points the
        // input at the raw mic array, so the channel count and rate change.
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            log("Microphone format unavailable (\(recordingFormat))")
            return
        }

        guard installMicTap(on: inputNode, recordingFormat: recordingFormat) else { return }

        engine.prepare()
        do {
            try engine.start()
            // The watchdog's window starts when the engine does, not when the
            // recording did — otherwise a slow start looks like a dead mic.
            captureQueue.async {
                self.lastMicBufferTime = self.elapsedSessionTime
                self.lastMicSignalTime = self.lastMicBufferTime
            }
            log(
                "Microphone started (\(recordingFormat.channelCount) ch @ "
                    + "\(Int(recordingFormat.sampleRate)) Hz)"
            )
        } catch {
            log("Microphone error: \(error.localizedDescription)")
            // Take the way out the watchdog would, without waiting for it: a
            // voice-processing graph this Mac won't start costs the whole Mic
            // track, and a Mic track that echoes System Audio beats no Mic track.
            if micEchoCancelling {
                inputNode.removeTap(onBus: 0)
                log("Retrying the microphone without echo cancellation")
                startMicrophone(echoCancellingSystemAudio: false)
            }
        }
    }

    /// Installs the tap that converts mic audio to Hover's 16 kHz mono and hands
    /// it to the Mic track. Returns whether the tap could be set up.
    private func installMicTap(
        on inputNode: AVAudioInputNode,
        recordingFormat: AVAudioFormat
    ) -> Bool {
        // Voice processing hands over the raw mic array: several channels of which
        // only the first is the microphone — the rest carry echo-cancellation
        // reference signal (this Mac's own output). Downmixing all of them would
        // fold System Audio straight back into the Mic track, so take channel 0
        // and convert that one down to 16 kHz.
        guard
            let monoRecordingFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: recordingFormat.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: monoRecordingFormat, to: pcmFormat)
        else {
            log("Mic converter unavailable for \(recordingFormat)")
            return false
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) {
            [weak self] buffer, _ in
            guard let self,
                let mono = Self.firstChannel(of: buffer, as: monoRecordingFormat)
            else { return }

            let convertedCapacity = AVAudioFrameCount(
                ceil(
                    Double(mono.frameLength) * self.pcmFormat.sampleRate
                        / monoRecordingFormat.sampleRate))
            guard convertedCapacity > 0,
                let converted = AVAudioPCMBuffer(
                    pcmFormat: self.pcmFormat, frameCapacity: convertedCapacity)
            else { return }

            var suppliedInput = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, outStatus in
                guard !suppliedInput else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                outStatus.pointee = .haveData
                return mono
            }
            guard status != .error, error == nil, let samples = converted.floatChannelData?[0]
            else { return }

            let micSamples = [Float](
                UnsafeBufferPointer(start: samples, count: Int(converted.frameLength)))
            let arrivedAt = self.elapsedSessionTime
            // Exact zeroes, not a quiet room: that's what a voice-processing unit
            // that isn't really running hands over.
            let hasSignal = micSamples.contains { $0 != 0 }
            self.captureQueue.async {
                self.micAudioBufferCount += 1
                self.lastMicBufferTime = arrivedAt
                if hasSignal {
                    self.lastMicSignalTime = arrivedAt
                    self.micHasSignal = true
                }
                self.enqueue(micSamples, source: .microphone, arrivedAt: arrivedAt)
            }
        }
        return true
    }

    /// Copies channel 0 of `buffer` into a fresh mono buffer, handling both
    /// deinterleaved (what AVAudioEngine hands over) and interleaved layouts.
    static func firstChannel(
        of buffer: AVAudioPCMBuffer,
        as format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        guard frames > 0,
            // A rate the converter wasn't built for would be resampled wrongly and
            // silently; drop it and let the watchdog rebuild at the new format.
            buffer.format.sampleRate == format.sampleRate,
            let source = buffer.floatChannelData?[0],
            let mono = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
            let destination = mono.floatChannelData?[0]
        else { return nil }
        mono.frameLength = AVAudioFrameCount(frames)

        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        if stride == 1 {
            destination.update(from: source, count: frames)
        } else {
            for frame in 0..<frames { destination[frame] = source[frame * stride] }
        }
        return mono
    }

    /// Tears the mic engine down and brings a fresh one up. A configuration change
    /// (the system audio tap's aggregate device is one) can leave the old engine
    /// running but silent, and only a new engine reliably recovers.
    private func restartMicrophone(echoCancellingSystemAudio: Bool) {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        captureQueue.sync {
            self.lastMicBufferTime = self.elapsedSessionTime
            self.lastMicSignalTime = self.lastMicBufferTime
        }
        startMicrophone(echoCancellingSystemAudio: echoCancellingSystemAudio)
    }
}
