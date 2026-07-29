import Foundation
import AVFoundation

/// Writes float audio samples to a 16-bit mono WAV file.
///
/// A small low-level helper shared by the Whisper transcription path and the
/// speaker-diarization pass — both hand raw `[Float]` samples to an external
/// tool that reads a WAV from disk.
enum WAVFile {

    enum WriteError: Error, LocalizedError {
        case bufferAllocationFailed
        var errorDescription: String? {
            switch self {
            case .bufferAllocationFailed:
                return "Could not allocate the audio buffer for the WAV file."
            }
        }
    }

    /// Write `samples` (mono float) as a 16-bit PCM WAV at `sampleRate`.
    static func write(samples: [Float], sampleRate: Int, to url: URL) throws {
        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: pcmFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw WriteError.bufferAllocationFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])
        try file.write(from: buffer)
    }
}
