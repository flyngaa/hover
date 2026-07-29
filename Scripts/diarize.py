#!/usr/bin/env python3
"""Local speaker diarization helper for Hover.

Reads a mono 16 kHz WAV file, figures out how many distinct speakers there are
and when each of them talks, and prints the result as JSON to stdout:

    {"segments": [{"start": 0.0, "end": 3.8, "speaker": 0}, ...]}

Everything runs on-device via sherpa-onnx (ONNX Runtime). No network, no
account, no token. Only depends on `sherpa_onnx` and `numpy` (see diar-venv).
"""

import argparse
import json
import sys
import wave

import numpy as np
import sherpa_onnx


def read_wav(path):
    """Load a WAV file as float32 mono samples plus its sample rate."""
    with wave.open(path, "rb") as w:
        channels = w.getnchannels()
        sample_width = w.getsampwidth()
        sample_rate = w.getframerate()
        frames = w.readframes(w.getnframes())

    if sample_width != 2:
        raise ValueError(f"Expected 16-bit PCM WAV, got {sample_width * 8}-bit")

    audio = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
    if channels > 1:
        audio = audio.reshape(-1, channels).mean(axis=1)
    return audio, sample_rate


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seg-model", required=True, help="pyannote segmentation model.onnx")
    parser.add_argument("--emb-model", required=True, help="speaker embedding model.onnx")
    parser.add_argument("--wav", required=True, help="input WAV (mono, 16-bit)")
    parser.add_argument(
        "--num-speakers",
        type=int,
        default=0,
        help="exact number of speakers if known; 0 = detect automatically",
    )
    parser.add_argument(
        "--threshold",
        type=float,
        # sherpa-onnx ships 0.5, but on real meeting audio (background noise,
        # laughter, quick interjections, mixed languages) that over-splits badly
        # — one recording produced ~80 "speakers". A higher value merges similar
        # voices, so we bias toward too-few rather than too-many. Trade-off: two
        # people with very similar voices may occasionally share a label.
        default=0.8,
        help="cluster split sensitivity used when num-speakers is 0 (lower = more speakers)",
    )
    args = parser.parse_args()

    clustering = (
        sherpa_onnx.FastClusteringConfig(num_clusters=args.num_speakers)
        if args.num_speakers > 0
        else sherpa_onnx.FastClusteringConfig(threshold=args.threshold)
    )

    config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(
                model=args.seg_model
            ),
        ),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=args.emb_model),
        clustering=clustering,
        # Ignore very short bursts (laughter, background TV, one-word noises):
        # they otherwise get their own spurious "speaker". 0.5s keeps real turns.
        min_duration_on=0.5,
        min_duration_off=0.5,
    )

    if not config.validate():
        print("Invalid diarization config", file=sys.stderr)
        return 2

    sd = sherpa_onnx.OfflineSpeakerDiarization(config)

    audio, sample_rate = read_wav(args.wav)
    if sample_rate != sd.sample_rate:
        raise ValueError(
            f"WAV sample rate {sample_rate} != model rate {sd.sample_rate}"
        )

    result = sd.process(audio).sort_by_start_time()

    segments = [
        {"start": round(seg.start, 3), "end": round(seg.end, 3), "speaker": seg.speaker}
        for seg in result
    ]
    json.dump({"segments": segments}, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
