"""Check export audio technically; this is not a substitute for listening."""
import argparse
import json
import shlex
import subprocess
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SCENES = ROOT / 'build/native-player-intro'
FINAL = ROOT / 'build/TANEBI-95-native-ja-player-1600p.mp4'
SAMPLE_RATE = 48000


class VerificationError(Exception):
    """An actionable verification or external-command failure."""


def run(command):
    try:
        return subprocess.run(command, check=True, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=600).stdout
    except FileNotFoundError as error:
        raise VerificationError(f'Required command not found: {command[0]}') from error
    except subprocess.TimeoutExpired as error:
        raise VerificationError(f'{command[0]} timed out after 600 seconds') from error
    except subprocess.CalledProcessError as error:
        detail = error.stderr.decode('utf-8', errors='replace').strip()
        raise VerificationError(
            f'{command[0]} failed (exit {error.returncode}): {detail}') from error


def scene_paths(manifest):
    paths = []
    for number, line in enumerate(manifest.read_text(encoding='utf-8-sig').splitlines(), 1):
        try:
            tokens = shlex.split(line, comments=True, posix=True)
        except ValueError as error:
            raise VerificationError(f'{manifest}:{number}: {error}') from error
        if not tokens or tokens == ['ffconcat', 'version', '1.0']:
            continue
        if len(tokens) != 2 or tokens[0] != 'file':
            raise VerificationError(
                f'{manifest}:{number}: expected a complete file entry, got {line!r}')
        path = Path(tokens[1])
        if not path.is_absolute():
            path = manifest.parent / path
        if not path.is_file():
            raise VerificationError(f'Scene file does not exist: {path}')
        paths.append(path.resolve())
    if not paths:
        raise VerificationError(f'No scene files found in {manifest}')
    return paths


def probe(path):
    try:
        metadata = json.loads(run([
        'ffprobe', '-v', 'error', '-show_streams', '-show_format',
        '-of', 'json', str(path)]))
        duration = float(metadata['format']['duration'])
    except (json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
        raise VerificationError(f'Invalid ffprobe metadata for {path}: {error}') from error
    if not np.isfinite(duration) or duration <= 0:
        raise VerificationError(f'Invalid duration for {path}: {duration}')
    audio = [stream for stream in metadata.get('streams', [])
             if stream.get('codec_type') == 'audio']
    if len(audio) != 1:
        raise VerificationError(f'{path.name}: expected one audio stream, found {len(audio)}')
    audio = audio[0]
    if (audio.get('channels') != 2 or audio.get('sample_rate') != str(SAMPLE_RATE)
            or audio.get('codec_name') != 'aac'):
        raise VerificationError(f'{path.name}: expected stereo 48kHz AAC, got {audio}')
    return duration


def decode(path):
    raw = run([
        'ffmpeg', '-v', 'error', '-xerror', '-i', str(path), '-map', '0:a:0',
        '-vn', '-ac', '2', '-ar', str(SAMPLE_RATE), '-af', 'asetpts=N/SR/TB',
        '-f', 'f32le', '-'])
    if not raw or len(raw) % 8:
        raise VerificationError(f'{path.name}: empty or malformed decoded stereo audio')
    samples = np.frombuffer(raw, dtype='<f4').reshape(-1, 2)
    if not np.isfinite(samples).all():
        raise VerificationError(f'{path.name}: non-finite audio samples')
    peak = float(np.max(np.abs(samples)))
    if peak >= 0.98:
        raise VerificationError(f'{path.name}: clipped or unexpectedly loud audio (peak {peak:.6f})')
    if peak <= 0.0001:
        raise VerificationError(f'{path.name}: audio track is effectively silent')
    # Check peaks on both channels before downmixing, so cancellation cannot hide clipping.
    return samples.mean(axis=1, dtype=np.float64), peak


def similarity(reference, candidate):
    if len(reference) < 2 or len(candidate) < len(reference):
        raise VerificationError('Export ends before the complete scene audio can be matched')
    if np.std(reference) < 1e-7:
        raise VerificationError('Scene interior is silent; correlation cannot verify it')
    # Search small codec-delay offsets using FFT cross correlation.
    n = 1 << (len(reference) + len(candidate) - 1).bit_length()
    cross = np.fft.irfft(np.fft.rfft(candidate, n) *
                         np.conj(np.fft.rfft(reference, n)), n)
    lag = int(np.argmax(cross[:max(1, len(candidate)-len(reference)+1)]))
    aligned = candidate[lag:lag+len(reference)]
    return float(np.corrcoef(reference, aligned)[0, 1]), lag


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, default=SCENES / 'concat.txt')
    parser.add_argument('--output', type=Path, default=FINAL)
    args = parser.parse_args()
    try:
        paths = scene_paths(args.manifest)
        export_duration = probe(args.output)
        final, peak = decode(args.output)
        elapsed = 0.0
        for i, path in enumerate(paths, 1):
            duration = probe(path)
            reference, scene_peak = decode(path)
            # Exclude codec padding at the edges; still inspect every scene's interior.
            trim = min(9600, len(reference) // 10)
            reference = reference[trim:len(reference)-trim]
            begin = max(0, round(elapsed*SAMPLE_RATE) + trim - 14400)
            candidate = final[begin:begin+len(reference)+28800]
            correlation, lag = similarity(reference, candidate)
            print(f'Scene {i}/{len(paths)} ({path.name}): stereo 48kHz AAC; '
                  f'correlation={correlation:.6f}; '
                  f'offset={(begin+lag)/SAMPLE_RATE-elapsed-trim/SAMPLE_RATE:.4f}s; '
                  f'peak={20*np.log10(scene_peak):.2f} dBFS')
            if not np.isfinite(correlation) or correlation <= 0.99:
                raise VerificationError(f'Scene {i}: exported audio differs from scene track')
            elapsed += duration
        if abs(export_duration - elapsed) > 0.1:
            raise VerificationError(
                f'Export duration {export_duration:.3f}s differs from scene total {elapsed:.3f}s')
        print(f'Export peak={20*np.log10(peak):.2f} dBFS; duration={export_duration:.3f}s')
        print(f'PASS: all {len(paths)} exported scenes match their separate audio tracks; '
              'no decoded channel clipping detected. This is technical verification, not listening.')
    except (VerificationError, OSError) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
