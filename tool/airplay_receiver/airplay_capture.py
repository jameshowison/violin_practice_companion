#!/usr/bin/env python3
"""Drain shairport-sync's FIFO forever; while a capture is on, write a WAV.

shairport-sync writes nothing to the pipe while nothing plays, so the raw
stream has no gaps in it. This writer keeps the WAV on the wall clock instead:
when audio resumes after a quiet spell, it pads silence for the time that
went by, so a 10 s stall in the app is 10 s of silence in the file, at the
right offset. The JSON sidecar has the wall-clock start (to line up with the
phone's sync trace) and every data stop/resume.

A capture is on while /var/lib/airplay-capture/control holds its name
(airplay-ctl capture start/stop). That file is written by another user
(airplay), so its contents are validated here too, and capture files are
created with O_EXCL|O_NOFOLLOW. A capture stops by itself after MAX_S, or
when the capture filesystem (its own size-limited image) runs low.
"""
import json, os, re, select, time, wave

FIFO = "/var/lib/airplay-fifo/audio.fifo"
CAP = "/var/lib/airplay-capture"
CTL = os.path.join(CAP, "control")
DIR = os.path.join(CAP, "captures")
RATE, CH, BPF = 44100, 2, 4          # S16_LE stereo
QUIET_S = 0.3                        # no data this long = a stop
MAX_S = 3600
MIN_FREE = 64 * 1024 * 1024
NAME = re.compile(r"[A-Za-z0-9_-]{1,48}")


def wanted():
    try:
        with open(CTL, "rb") as f:
            s = f.read(64).decode("ascii", "replace").strip()
    except (FileNotFoundError, IsADirectoryError):
        return None
    return s if NAME.fullmatch(s) else None


def free_bytes():
    st = os.statvfs(CAP)
    return st.f_bavail * st.f_frsize


def stop_request():
    try: os.remove(CTL)
    except FileNotFoundError: pass


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(t)) + f".{int(t % 1 * 1000):03d}"


def create(path):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o640)
    return os.fdopen(fd, "wb")


class Capture:
    def __init__(self, name):
        self.name = name
        self.path = os.path.join(DIR, name)
        self.f = create(self.path + ".wav.part")
        self.w = wave.open(self.f, "wb")
        self.w.setnchannels(CH); self.w.setsampwidth(2); self.w.setframerate(RATE)
        self.t0 = time.monotonic(); self.wall0 = time.time()
        self.frames = 0; self.padded = 0; self.events = []
        self.flowing = False; self.last_data = None; self.ended = "stop"

    def now(self):
        return time.monotonic() - self.t0

    def pad_to(self, t):
        missing = int(t * RATE) - self.frames
        if missing <= 0:
            return 0
        chunk = b"\0" * (RATE * BPF)
        left = missing
        while left > 0:
            n = min(left, RATE)
            self.w.writeframes(chunk[: n * BPF]); left -= n
        self.frames += missing; self.padded += missing
        return missing

    def data(self, buf):
        t = self.now()
        if not self.flowing:
            gap = self.pad_to(t)
            self.events.append({"t": round(t, 3), "kind": "data", "padded_s": round(gap / RATE, 3)})
            self.flowing = True
        self.w.writeframes(buf); self.frames += len(buf) // BPF
        self.last_data = t

    def tick(self):
        if self.flowing and self.now() - self.last_data > QUIET_S:
            self.flowing = False
            self.events.append({"t": round(self.last_data, 3), "kind": "quiet"})

    def close(self):
        self.tick()
        if self.ended != "disk_low":
            self.pad_to(self.now())
        self.w.close(); self.f.close()
        os.replace(self.path + ".wav.part", self.path + ".wav")
        meta = {"name": self.name, "start_wall": iso(self.wall0), "start_epoch": self.wall0,
                "rate": RATE, "channels": CH, "duration_s": round(self.frames / RATE, 3),
                "padded_s": round(self.padded / RATE, 3), "ended": self.ended,
                "events": self.events}
        with create(self.path + ".json.part") as f:
            f.write(json.dumps(meta, indent=1).encode())
        os.replace(self.path + ".json.part", self.path + ".json")


def taken(name):
    return any(os.path.lexists(os.path.join(DIR, name + s)) for s in (".wav", ".json", ".wav.part"))


def main():
    fd = os.open(FIFO, os.O_RDONLY | os.O_NONBLOCK)
    cap, rest, refused, next_disk = None, b"", None, 0.0
    while True:
        r, _, _ = select.select([fd], [], [], 0.1)
        buf = b""
        if r:
            try:
                buf = os.read(fd, 65536)
            except BlockingIOError:
                pass
            if not buf:              # writer closed: EOF until it reopens
                time.sleep(0.05)
        name = wanted()
        if cap:
            end = None
            if name != cap.name:
                end = "stop"
            elif cap.now() > MAX_S:
                end = "max_length"
            elif time.monotonic() >= next_disk:
                next_disk = time.monotonic() + 2
                if free_bytes() < MIN_FREE:
                    end = "disk_low"
            if end:
                cap.ended = end
                cap.close(); cap = None
                if end != "stop":
                    stop_request(); name = None
        if name != refused:
            refused = None
        if name and not cap and name != refused:
            if taken(name) or free_bytes() < MIN_FREE:
                refused = name       # airplay-ctl refuses these first; belt and braces
            else:
                cap, rest = Capture(name), b""
        if cap and buf:
            buf = rest + buf
            cut = len(buf) - len(buf) % BPF
            rest = buf[cut:]
            if cut:
                cap.data(buf[:cut])
        if cap:
            cap.tick()


if __name__ == "__main__":
    main()
