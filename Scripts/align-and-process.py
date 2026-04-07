#!/usr/bin/env python3
"""
Aligns desynced mic track with system audio using cross-correlation,
then produces a properly synchronized output.

Usage:
  python3 Scripts/align-and-process.py <recording-dir> [output-file]

Example:
  python3 Scripts/align-and-process.py \
    ~/Library/Application\ Support/Blackbox/Recordings/2026-04-05-121626-8CAA \
    /tmp/audio-processed-synced.m4a
"""

import json
import os
import subprocess
import sys
import tempfile

import numpy as np
import soundfile as sf
from scipy import signal as sig

SAMPLE_RATE = 48000
CORRELATION_WINDOW = 10  # seconds per checkpoint
MAX_LAG_SECONDS = 15  # max drift to search
NUM_CHECKPOINTS = 12  # measure drift at N points


def extract_track(input_path, track_index, output_path, sr=SAMPLE_RATE):
    subprocess.run([
        "ffmpeg", "-y", "-v", "quiet",
        "-i", input_path,
        "-map", f"0:{track_index}",
        "-ac", "1", "-ar", str(sr),
        "-f", "wav", output_path
    ], check=True)


def measure_offset_at(ref_data, mic_data, position_sec, sr=SAMPLE_RATE):
    """Cross-correlate ref and mic at position. Returns (offset_sec, confidence)."""
    window = CORRELATION_WINDOW * sr
    max_lag = MAX_LAG_SECONDS * sr

    ref_start = int(position_sec * sr)
    ref_end = ref_start + window
    if ref_end > len(ref_data):
        return None

    mic_search_start = max(0, ref_start - max_lag)
    mic_search_end = min(len(mic_data), ref_end + max_lag)
    if mic_search_end - mic_search_start < window:
        return None

    ref_seg = ref_data[ref_start:ref_end]
    mic_seg = mic_data[mic_search_start:mic_search_end]

    ref_norm = ref_seg - np.mean(ref_seg)
    mic_norm = mic_seg - np.mean(mic_seg)
    ref_std = np.std(ref_norm)
    mic_std = np.std(mic_norm)
    if ref_std < 1e-8 or mic_std < 1e-8:
        return None

    corr = sig.correlate(mic_norm, ref_norm, mode='valid')
    best_idx = np.argmax(np.abs(corr))

    mic_aligned_start = mic_search_start + best_idx
    offset_samples = mic_aligned_start - ref_start
    offset_sec = offset_samples / sr

    confidence = np.abs(corr[best_idx]) / (len(ref_norm) * ref_std * mic_std)
    return offset_sec, confidence


def align_mic(ref_data, mic_data, drift_map, sr=SAMPLE_RATE):
    """Resample mic track to align with ref using interpolated drift map."""
    output_len = len(ref_data)
    aligned = np.zeros(output_len, dtype=np.float32)

    # Build interpolation arrays
    drift_times = np.array([d[0] for d in drift_map])
    drift_offsets = np.array([d[1] for d in drift_map])

    # Vectorized: compute source indices for all output samples
    t = np.arange(output_len, dtype=np.float64) / sr
    offsets = np.interp(t, drift_times, drift_offsets)
    src_indices = np.arange(output_len, dtype=np.float64) + offsets * sr

    # Integer and fractional parts for linear interpolation
    src_int = src_indices.astype(np.int64)
    src_frac = (src_indices - src_int).astype(np.float32)

    # Mask valid indices
    valid = (src_int >= 0) & (src_int < len(mic_data) - 1)
    idx = np.where(valid)[0]
    si = src_int[idx]
    sf_arr = src_frac[idx]

    aligned[idx] = (1 - sf_arr) * mic_data[si] + sf_arr * mic_data[si + 1]

    return aligned


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <recording-dir> [output-file]")
        sys.exit(1)

    rec_dir = sys.argv[1]
    input_path = os.path.join(rec_dir, "audio.m4a")
    output_path = (
        sys.argv[2] if len(sys.argv) > 2
        else os.path.join(rec_dir, "audio-processed-synced.m4a")
    )

    if not os.path.exists(input_path):
        print(f"ERROR: {input_path} not found")
        sys.exit(1)

    # Track info
    result = subprocess.run(
        ["ffprobe", "-v", "quiet", "-print_format", "json", "-show_streams", input_path],
        capture_output=True, text=True
    )
    streams = json.loads(result.stdout)["streams"]
    track_count = len(streams)
    print(f"Input: {input_path}")
    print(f"Tracks: {track_count}")
    for i, s in enumerate(streams):
        print(f"  Track {i}: {s['codec_name']} {s['sample_rate']}Hz "
              f"{s['channels']}ch duration={s['duration']}s")

    if track_count < 2:
        print("ERROR: need at least 2 tracks")
        sys.exit(1)

    ref_idx = 1 if track_count >= 3 else 0
    mic_idx = track_count - 1
    print(f"\nReference: track {ref_idx}, Mic: track {mic_idx}")

    with tempfile.TemporaryDirectory() as tmpdir:
        ref_path = os.path.join(tmpdir, "ref.wav")
        mic_path = os.path.join(tmpdir, "mic.wav")

        print("\nExtracting tracks...")
        extract_track(input_path, ref_idx, ref_path)
        extract_track(input_path, mic_idx, mic_path)

        ref_data, _ = sf.read(ref_path, dtype='float32')
        mic_data, _ = sf.read(mic_path, dtype='float32')
        print(f"  Reference: {len(ref_data)/SAMPLE_RATE:.1f}s")
        print(f"  Mic:       {len(mic_data)/SAMPLE_RATE:.1f}s")
        print(f"  Gap:       {(len(ref_data) - len(mic_data))/SAMPLE_RATE:.3f}s")

        # Measure drift at checkpoints
        duration = len(ref_data) / SAMPLE_RATE
        margin = max(30, CORRELATION_WINDOW + 1)
        checkpoints = np.linspace(margin, duration - margin, NUM_CHECKPOINTS)

        print(f"\nMeasuring drift at {NUM_CHECKPOINTS} checkpoints...")
        drift_map = []
        for pos in checkpoints:
            result = measure_offset_at(ref_data, mic_data, pos)
            if result is None:
                print(f"  {pos/60:6.1f}min: FAILED (silence or edge)")
                continue
            offset, confidence = result
            quality = "OK" if confidence > 0.01 else "LOW" if confidence > 0.005 else "SKIP"
            print(f"  {pos/60:6.1f}min: offset={offset:+.4f}s  "
                  f"confidence={confidence:.4f}  {quality}")
            if confidence > 0.003:
                drift_map.append((pos, offset))

        if not drift_map:
            print("\nERROR: could not measure drift at any checkpoint")
            sys.exit(1)

        # Filter outliers using median absolute deviation
        if len(drift_map) >= 3:
            offsets = np.array([d[1] for d in drift_map])
            median = np.median(offsets)
            mad = np.median(np.abs(offsets - median))
            threshold = max(3 * mad, 0.5)  # at least 0.5s tolerance
            filtered = [(t, o) for t, o in drift_map
                        if abs(o - median) <= threshold]
            removed = len(drift_map) - len(filtered)
            if removed > 0:
                print(f"\n  Filtered {removed} outlier(s) "
                      f"(median={median:+.3f}s, threshold={threshold:.3f}s)")
            drift_map = filtered if filtered else drift_map

        # Extrapolate to edges
        if len(drift_map) >= 2:
            slope_start = ((drift_map[1][1] - drift_map[0][1])
                           / (drift_map[1][0] - drift_map[0][0]))
            offset_at_0 = drift_map[0][1] - slope_start * drift_map[0][0]
            slope_end = ((drift_map[-1][1] - drift_map[-2][1])
                         / (drift_map[-1][0] - drift_map[-2][0]))
            offset_at_end = (drift_map[-1][1]
                             + slope_end * (duration - drift_map[-1][0]))
        else:
            offset_at_0 = drift_map[0][1]
            offset_at_end = drift_map[0][1]

        drift_map.insert(0, (0, offset_at_0))
        drift_map.append((duration, offset_at_end))

        print(f"\nDrift map ({len(drift_map)} points):")
        for t, off in drift_map:
            print(f"  {t/60:6.1f}min: {off:+.4f}s")
        total_drift = drift_map[-1][1] - drift_map[0][1]
        print(f"Total drift: {total_drift:+.3f}s")

        # Align
        print("\nAligning mic track...")
        aligned_mic = align_mic(ref_data, mic_data, drift_map)

        # Write aligned mic
        aligned_mic_path = os.path.join(tmpdir, "aligned_mic.wav")
        sf.write(aligned_mic_path, aligned_mic, SAMPLE_RATE)

        # Build output: ref + aligned mic as 2-track M4A
        print(f"\nWriting output: {output_path}")
        ref_out_path = os.path.join(tmpdir, "ref_out.wav")
        sf.write(ref_out_path, ref_data, SAMPLE_RATE)

        subprocess.run([
            "ffmpeg", "-y", "-v", "quiet",
            "-i", ref_out_path,
            "-i", aligned_mic_path,
            "-map", "0:0", "-map", "1:0",
            "-c:a", "aac", "-b:a", "128k",
            output_path
        ], check=True)

        # Also write a single-track mixed version for quick listening
        mixed_path = output_path.replace(".m4a", "-mixed.m4a")
        mix_len = min(len(ref_data), len(aligned_mic))
        mixed = 0.5 * ref_data[:mix_len] + 0.5 * aligned_mic[:mix_len]
        mixed_wav = os.path.join(tmpdir, "mixed.wav")
        sf.write(mixed_wav, mixed, SAMPLE_RATE)
        subprocess.run([
            "ffmpeg", "-y", "-v", "quiet",
            "-i", mixed_wav,
            "-c:a", "aac", "-b:a", "128k",
            mixed_path
        ], check=True)

        size_mt = os.path.getsize(output_path) / 1024 / 1024
        size_mx = os.path.getsize(mixed_path) / 1024 / 1024
        print(f"\nDone!")
        print(f"  2-track (ref+mic): {output_path} ({size_mt:.1f} MB)")
        print(f"  Mixed (listening): {mixed_path} ({size_mx:.1f} MB)")


if __name__ == "__main__":
    main()
