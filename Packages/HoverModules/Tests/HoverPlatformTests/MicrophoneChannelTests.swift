import AVFoundation
import Testing

@testable import HoverPlatform

/// Echo cancellation hands the mic over as a multi-channel mic array: channel 0
/// is the microphone, the rest carry this Mac's own output as the reference the
/// canceller works from. Folding those in would put System Audio back onto the
/// Mic track — the exact duplication echo cancellation is there to prevent.
@Suite struct MicrophoneChannelTests {

    /// Built from a stream description rather than `commonFormat:` because that
    /// convenience initializer only knows mono and stereo, and the point here is
    /// the three-or-more-channel mic array voice processing hands over.
    private func format(channels: UInt32, sampleRate: Double = 48_000, interleaved: Bool = false)
        -> AVAudioFormat
    {
        let bytesPerFrame = interleaved ? 4 * channels : 4
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let layout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)!
        return AVAudioFormat(streamDescription: &description, channelLayout: layout)!
    }

    private func mono(sampleRate: Double = 48_000) -> AVAudioFormat {
        format(channels: 1, sampleRate: sampleRate)
    }

    @Test func onlyTheMicrophoneChannelIsKept() throws {
        let source = try #require(
            AVAudioPCMBuffer(pcmFormat: format(channels: 3), frameCapacity: 4))
        source.frameLength = 4
        let channels = try #require(source.floatChannelData)
        for frame in 0..<4 {
            channels[0][frame] = Float(frame) * 0.1  // the microphone
            channels[1][frame] = 1  // echo cancellation reference
            channels[2][frame] = -1
        }

        let extracted = try #require(
            LiveAudioCapture.firstChannel(of: source, as: mono()))

        #expect(extracted.frameLength == 4)
        let samples = try #require(extracted.floatChannelData)[0]
        #expect((0..<4).map { samples[$0] } == [0, 0.1, 0.2, 0.30000001192092896])
    }

    @Test func interleavedInputIsDeinterleaved() throws {
        let source = try #require(
            AVAudioPCMBuffer(
                pcmFormat: format(channels: 2, interleaved: true), frameCapacity: 3))
        source.frameLength = 3
        let samples = try #require(source.floatChannelData)[0]
        for (index, value) in [Float(0.5), 9, 0.6, 9, 0.7, 9].enumerated() {
            samples[index] = value
        }

        let extracted = try #require(
            LiveAudioCapture.firstChannel(of: source, as: mono()))

        let result = try #require(extracted.floatChannelData)[0]
        #expect((0..<3).map { result[$0] } == [0.5, 0.6, 0.7])
    }

    /// The converter downstream is built for one rate. Resampling at the wrong
    /// rate is silent and ruins the audio, so a surprise format is dropped.
    @Test func aBufferAtAnotherSampleRateIsRefused() throws {
        let source = try #require(
            AVAudioPCMBuffer(
                pcmFormat: format(channels: 1, sampleRate: 44_100), frameCapacity: 2))
        source.frameLength = 2

        #expect(LiveAudioCapture.firstChannel(of: source, as: mono(sampleRate: 48_000)) == nil)
    }

    @Test func anEmptyBufferYieldsNothing() throws {
        let source = try #require(AVAudioPCMBuffer(pcmFormat: mono(), frameCapacity: 2))
        source.frameLength = 0

        #expect(LiveAudioCapture.firstChannel(of: source, as: mono()) == nil)
    }
}
