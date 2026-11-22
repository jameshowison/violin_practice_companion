"""Ground truth for AirPlay tests: what audio actually reached the receiver.

    shairport-sync -o stdout | python3 -I pcm_monitor.py LOG     # record
    python3 -I pcm_monitor.py --summarize LOG [--since HH:MM:SS] [--silent-db -45]

Recording reads shairport-sync's stdout (S16LE stereo 44.1 kHz) and appends one
line per 100 ms of audio: wall clock, seconds of audio so far, RMS in dBFS.
"GAP" means no bytes for over 250 ms (the sender stopped streaming or stalled);
"RESUME" ends one. scripts/airplay_receiver.sh runs it.

--summarize prints the stream's sessions, every gap, and every silent stretch
(below -60 dBFS for 0.5 s or more) inside a session, so a stall shows up as a
gap or a silence with a time you can match against the app's trace.
"""
import math, os, select, struct, sys, time

SILENT_DB, SILENT_MIN_S = -60.0, 0.5


def stamp():
    t = time.time()
    return time.strftime('%H:%M:%S', time.localtime(t)) + f'.{int(t * 1000) % 1000:03d}'


def record(path):
    fd = sys.stdin.fileno()
    os.set_blocking(fd, False)
    chunk = 4410 * 4  # 100 ms
    buf, frames, last, in_gap = b'', 0, time.time(), False
    out = open(path, 'a', buffering=1)
    out.write(f'{stamp()} monitor start\n')
    while True:
        ready, _, _ = select.select([fd], [], [], 0.25)
        if not ready:
            if not in_gap and time.time() - last > 0.25:
                out.write(f'{stamp()} GAP\n')
                in_gap = True
            continue
        data = os.read(fd, 65536)
        if not data:
            out.write(f'{stamp()} EOF\n')
            return
        if in_gap:
            out.write(f'{stamp()} RESUME after {time.time() - last:.2f}s\n')
            in_gap = False
        last = time.time()
        buf += data
        while len(buf) >= chunk:
            c, buf = buf[:chunk], buf[chunk:]
            frames += 4410
            n = len(c) // 2
            s = struct.unpack(f'<{n}h', c)
            rms = math.sqrt(sum(x * x for x in s) / n)
            db = 20 * math.log10(rms / 32768) if rms > 0 else -120.0
            out.write(f'{stamp()} t={frames / 44100:.1f}s rms={db:.1f}dB\n')


def summarize(path, since=None):
    lines = [l.rstrip('\n') for l in open(path)]
    if since:
        lines = [l for l in lines if l[:8] >= since]
    silent_start, silent_n, audio_n, loud_n = None, 0, 0, 0
    def flush_silence(end):
        nonlocal silent_start, silent_n
        if silent_start and silent_n * 0.1 >= SILENT_MIN_S:
            print(f'  silence {silent_start} → {end}  ({silent_n * 0.1:.1f}s of audio)')
        silent_start, silent_n = None, 0
    for l in lines:
        when, _, rest = l.partition(' ')
        if rest.startswith('t='):
            audio_n += 1
            db = float(rest.split('rms=')[1].rstrip('dB'))
            if db < SILENT_DB:
                silent_start = silent_start or when
                silent_n += 1
            else:
                loud_n += 1
                flush_silence(when)
        else:
            flush_silence(when)
            print(f'{when} {rest}')
    flush_silence('end')
    print(f'audio received: {audio_n * 0.1:.1f}s, of it non-silent: {loud_n * 0.1:.1f}s')


if __name__ == '__main__':
    if sys.argv[1] == '--summarize':
        since = sys.argv[sys.argv.index('--since') + 1] if '--since' in sys.argv else None
        if '--silent-db' in sys.argv:
            SILENT_DB = float(sys.argv[sys.argv.index('--silent-db') + 1])
        summarize(sys.argv[2], since)
    else:
        record(sys.argv[1])
