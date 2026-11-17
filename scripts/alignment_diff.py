#!/usr/bin/env python3
"""Compare two alignment snapshots (test/alignment_corpus_snapshot_test.dart).

    python3 scripts/alignment_diff.py before.json after.json [--threshold 0.25]

Every recording whose barlines moved by more than the threshold is reported,
rated or not: an alignment nobody has complained about is presumed good, so a
change to it is a warning too. A rating only grades the warning:

  REGRESSION       rated good, and it moved
  changed          unrated (presumed good), and it moved
  rated-off moved  every moved bar is inside a span someone marked off:
                   a candidate fix, to check by ear
  rated wrong      rated wrong overall, and it moved

Worst first. Exit status 1 when anything rated good or unrated moved.
"""
import argparse
import json
import sys


def ranges(bars, numbers):
    """Playing-order indices -> '4-6, 10' in measure numbers."""
    out, start, prev = [], None, None
    for b in bars:
        if start is None:
            start = prev = b
        elif b == prev + 1:
            prev = b
        else:
            out.append((start, prev))
            start = prev = b
    if start is not None:
        out.append((start, prev))
    return ', '.join(f'{numbers[a]}' if a == b else f'{numbers[a]}-{numbers[b]}'
                     for a, b in out)


def in_spans(number, spans):
    """Whether measure [number] is inside any [start, end] span."""
    return any(s <= number <= e for s, e in spans)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('before')
    ap.add_argument('after')
    ap.add_argument('--threshold', type=float, default=0.25,
                    help='seconds a barline must move to count (default 0.25)')
    args = ap.parse_args()
    before = json.load(open(args.before))
    after = json.load(open(args.after))

    rows, unchanged = [], 0
    for key in sorted(set(before) | set(after)):
        if key not in before or key not in after:
            rows.append((float('inf'), 'added' if key not in before else 'removed',
                         key, (after.get(key) or before[key]).get('label', ''), ''))
            continue
        b, a = before[key], after[key]
        rating = a.get('rating') or b.get('rating') or {}
        verdict = rating.get('verdict')
        spans = rating.get('offSpans') or []
        n = min(len(b['bars']), len(a['bars']))
        numbers = a.get('numbers') or list(range(1, len(a['bars']) + 1))
        shifts = [abs(a['bars'][i] - b['bars'][i]) for i in range(n)]
        moved = [i for i in range(n) if shifts[i] > args.threshold]
        flag = b.get('compressed') != a.get('compressed')
        if not moved and not flag and len(b['bars']) == len(a['bars']):
            unchanged += 1
            continue
        if moved and spans and all(in_spans(numbers[i], spans) for i in moved):
            grade = 'rated-off moved'
        elif verdict == 'wrong':
            grade = 'rated wrong'
        elif verdict == 'good':
            grade = 'REGRESSION'
        else:
            grade = 'changed'
        worst = max(shifts) if shifts else 0.0
        detail = (f'max {worst:.2f}s, {len(moved)}/{n} bars moved'
                  + (f' (bars {ranges(moved, numbers)})' if moved else '')
                  + (f', compressed {b.get("compressed")} -> {a.get("compressed")}'
                     if flag else '')
                  + (f', bars {len(b["bars"])} -> {len(a["bars"])}'
                     if len(b['bars']) != len(a['bars']) else ''))
        rows.append((worst, grade, key, a.get('label', ''), detail))

    rows.sort(key=lambda r: -r[0])
    for _, grade, key, label, detail in rows:
        print(f'{grade:16} {label or key}\n{"":16} {key}\n{"":16} {detail}')
    print(f'\n{len(rows)} changed, {unchanged} unchanged '
          f'(threshold {args.threshold}s)')
    bad = any(g in ('REGRESSION', 'changed') for _, g, *_ in rows)
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
