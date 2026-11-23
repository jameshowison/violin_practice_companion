# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy"]
# ///
"""List the silent stretches in a capture from the AirPlay test receiver.

  uv run gaps.py capture.wav [--min 1.0] [--db -50]

Times are offsets into the capture and, when the .json sidecar is next to it,
wall-clock times too (to line up with the phone's sync trace). A loop seam
shows as a short gap once per pass; the AirPlay stall (CLAUDE.md, "Audio on
iOS", trap 3) as ~10 s. A newly picked receiver plays near -60 dBFS (dither
only) until the phone's volume is raised: that reads as silence here.
"""
import argparse, json, pathlib, time, wave
import numpy as np

ap = argparse.ArgumentParser()
ap.add_argument("wav")
ap.add_argument("--min", type=float, default=1.0, help="shortest gap to report, s")
ap.add_argument("--db", type=float, default=-50.0, help="silence threshold, dBFS")
a = ap.parse_args()

with wave.open(a.wav) as w:
    rate, ch = w.getframerate(), w.getnchannels()
    x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").reshape(-1, ch)
mono = np.abs(x.astype(np.int32)).max(axis=1)
hop = rate // 20                                    # 50 ms windows
n = len(mono) // hop
peak = mono[: n * hop].reshape(n, hop).max(axis=1) / 32768.0
quiet = peak < 10 ** (a.db / 20)

meta_path = pathlib.Path(a.wav).with_suffix(".json")
start = json.loads(meta_path.read_text())["start_epoch"] if meta_path.exists() else None

def stamp(t):
    if start is None:
        return f"{t:8.2f}s"
    w = start + t
    return f"{t:8.2f}s  {time.strftime('%H:%M:%S', time.localtime(w))}.{int(w % 1 * 1000):03d}"

print(f"{a.wav}: {len(mono) / rate:.1f} s, {100 * (~quiet).mean():.0f}% audible")
i, gaps = 0, 0
while i < n:
    if quiet[i]:
        j = i
        while j < n and quiet[j]:
            j += 1
        d = (j - i) * 0.05
        if d >= a.min:
            print(f"  silent {d:6.2f}s from {stamp(i * 0.05)}")
            gaps += 1
        i = j
    else:
        i += 1
print(f"{gaps} gap(s) of ≥{a.min}s")
