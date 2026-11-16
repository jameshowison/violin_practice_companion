#!/usr/bin/env python3
"""Score screen-scan results (integration_test/screen_scan_test.dart).

    python3 -I scripts/omr_eval/score_screen_scan.py <SCREEN_SCAN_DIR>

Each case directory is named `<piece_id>[__variant]`; its `out.musicxml` is
compared with `assets/library/<piece_id>/score.musicxml`, or with
`gold.musicxml` in the case directory when there is one (a scanned piece from
the dev library). Notes are compared as a sequence by edit distance, so one
dropped note costs one error rather than shifting everything after it.

SER  = edit distance over (pitch, duration) tokens / gold length
PER  = the same over pitch only (rests included as 'R')
"""
import os
import sys
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def notes(path, skip_hidden):
    out = []
    for note in ET.parse(path).getroot().iter('note'):
        if skip_hidden and note.get('print-object') == 'no':
            continue
        if note.find('chord') is not None or note.find('grace') is not None:
            continue
        typ = note.findtext('type') or '?'
        dots = len(note.findall('dot'))
        dur = typ + '.' * dots
        if note.find('rest') is not None:
            out.append(('R', dur))
            continue
        p = note.find('pitch')
        alter = int(float(p.findtext('alter') or 0))
        acc = '#' * alter if alter > 0 else 'b' * -alter
        out.append((f"{p.findtext('step')}{acc}{p.findtext('octave')}", dur))
    return out


def edit(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]


def main(base):
    for name in sorted(os.listdir(base)):
        case = os.path.join(base, name)
        out = os.path.join(case, 'out.musicxml')
        if not os.path.isfile(out):
            continue
        gold = os.path.join(case, 'gold.musicxml')
        if not os.path.isfile(gold):
            gold = os.path.join(ROOT, 'assets', 'library', name.split('__')[0], 'score.musicxml')
        if os.path.getsize(out) == 0:
            print(f'{name:40s} FAILED ({open(os.path.join(case, "out.error")).read()[:80]})')
            continue
        g, e = notes(gold, True), notes(out, False)
        ser = edit(g, e) / len(g)
        per = edit([x[0] for x in g], [x[0] for x in e]) / len(g)
        print(f'{name:40s} gold {len(g):3d}  got {len(e):3d}  SER {ser:6.1%}  PER {per:6.1%}')


if __name__ == '__main__':
    main(sys.argv[1])
