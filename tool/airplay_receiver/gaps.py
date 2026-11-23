# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy"]
# ///
"""List the silent stretches in a capture from the AirPlay test receiver.

  uv run gaps.py capture.wav [--min 1.0] [--db -50] [--summary]
  receiver.sh gaps NAME [same options]     (on a pulled capture)

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
ap.add_argument("--summary", action="store_true",
                help="one line each: silences while playing, and the stream's own pauses")
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
found = []                                          # (start s, length s)
i = 0
while i < n:
    if quiet[i]:
        j = i
        while j < n and quiet[j]:
            j += 1
        d = (j - i) * 0.05
        if d >= a.min:
            found.append((i * 0.05, d))
        i = j
    else:
        i += 1


def spread(xs):
    xs = sorted(xs)
    return f"shortest {xs[0]:.2f}s, median {xs[len(xs) // 2]:.2f}s, longest {xs[-1]:.2f}s"


if a.summary:
    # Between the first sound and the last: the lead-in before Play and the
    # tail after Stop are left out.
    inner = [g for g in found if g[0] > 0 and g[0] + g[1] < n * 0.05 - 0.05]
    if inner:
        starts = [s for s, _ in inner]
        every = np.diff(starts)
        period = f", every {np.median(every):.2f}s" if len(every) else ""
        print(f"  {len(inner)} silence(s) of ≥{a.min}s while playing{period}: "
              f"{spread([d for _, d in inner])}")
    else:
        print(f"  no silence of ≥{a.min}s while playing")
    if meta_path.exists():
        # The stream's own pauses: the recorder pads each one it measured.
        ev = json.loads(meta_path.read_text())["events"]
        pauses = [e["padded_s"] for e in ev[1:] if e["kind"] == "data"]
        if pauses:
            print(f"  stream paused {len(pauses)} time(s): {spread(pauses)}")
        else:
            print("  stream never paused")
else:
    for s, d in found:
        print(f"  silent {d:6.2f}s from {stamp(s)}")
    print(f"{len(found)} gap(s) of ≥{a.min}s")
