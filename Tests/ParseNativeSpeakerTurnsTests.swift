import Testing
@testable import HoverApp

/// The native `sherpa-onnx-offline-speaker-diarization` helper prints human
/// turn lines (`start -- end speaker_NN`), not the JSON `diarize.py` emits.
/// Parsing those lines into speaker turns is pure — tested on canned text so
/// the suite never needs the helper binary.
@Suite struct ParseNativeSpeakerTurnsTests {

    @Test func parsesANormalMultiSpeakerResult() {
        let output = """
        OfflineSpeakerDiarizationConfig(...)
        Started
        0.000 -- 3.800 speaker_00
        3.800 -- 7.200 speaker_01
        7.200 -- 10.000 speaker_00
        """
        let turns = TranscriberEngine.parseNativeSpeakerTurns(output)
        #expect(turns.count == 3)
        #expect(turns[0].start == 0.0)
        #expect(turns[0].end == 3.8)
        #expect(turns[0].speaker == 0)
        #expect(turns[1].start == 3.8)
        #expect(turns[1].end == 7.2)
        #expect(turns[1].speaker == 1)
        #expect(turns[2].start == 7.2)
        #expect(turns[2].end == 10.0)
        #expect(turns[2].speaker == 0)
    }

    @Test func skipsAMalformedLineAndKeepsTheRest() {
        let output = """
        0.000 -- 2.000 speaker_00
        this is not a turn
        2.000 -- 4.000 speaker_01
        """
        let turns = TranscriberEngine.parseNativeSpeakerTurns(output)
        #expect(turns.count == 2)
        #expect(turns[0].speaker == 0)
        #expect(turns[1].speaker == 1)
    }

    @Test func emptyOutputYieldsNoTurns() {
        #expect(TranscriberEngine.parseNativeSpeakerTurns("").isEmpty)
        #expect(TranscriberEngine.parseNativeSpeakerTurns("Started\n").isEmpty)
    }

    /// Today's diarize.py tuning (threshold 0.8, min on/off 0.5s) must map onto
    /// the helper's flags — otherwise tagging quality quietly changes.
    @Test func nativeHelperArgumentsCarryTodaysTuning() {
        let args = TranscriberEngine.nativeSpeakerTaggingArguments(
            segmentationModel: "/models/seg.onnx",
            embeddingModel: "/models/emb.onnx",
            wavPath: "/tmp/session.wav"
        )
        #expect(args == [
            "--clustering.cluster-threshold=0.8",
            "--min-duration-on=0.5",
            "--min-duration-off=0.5",
            "--segmentation.pyannote-model=/models/seg.onnx",
            "--embedding.model=/models/emb.onnx",
            "/tmp/session.wav",
        ])
    }
}
