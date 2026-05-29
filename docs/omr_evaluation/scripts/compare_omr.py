#!/usr/bin/env python3
"""Compare OMR MusicXML output against gold-standard fixtures.

Usage:
    python compare_omr.py <engine_lr.musicxml> <engine_hf.musicxml>

Engine label is inferred from the parent directory name.
"""

import sys
import xml.etree.ElementTree as ET

BASE = '/Users/jlh5498/Documents/git_root/violin_practice_companion'

GOLD = {
    'lr': f'{BASE}/assets/fixtures/lightly_row_musescore.xml',
    'hf': f'{BASE}/assets/fixtures/happy_farmer_musescore.xml',
}


def extract_notes(path, skip_print_object_no=False):
    """Return list of (step, octave, duration_type, is_rest, alter) tuples."""
    tree = ET.parse(path)
    root = tree.getroot()
    notes = []
    for note in root.iter('note'):
        if skip_print_object_no and note.get('print-object') == 'no':
            continue
        is_rest = note.find('rest') is not None
        if note.find('chord') is not None:
            continue
        if is_rest:
            dur_el = note.find('type')
            dur = dur_el.text if dur_el is not None else 'unknown'
            notes.append(('R', None, dur, True, 0))
        else:
            pitch = note.find('pitch')
            step = pitch.find('step').text if pitch is not None and pitch.find('step') is not None else '?'
            octave = pitch.find('octave').text if pitch is not None and pitch.find('octave') is not None else '?'
            alter_el = pitch.find('alter') if pitch is not None else None
            alter = int(float(alter_el.text)) if alter_el is not None else 0
            dur_el = note.find('type')
            dur = dur_el.text if dur_el is not None else 'unknown'
            notes.append((step, octave, dur, False, alter))
    return notes


def pitch_str(n):
    if n[3]:
        return 'R'
    step, octave, _, _, alter = n
    suffix = '#' if alter > 0 else ('b' if alter < 0 else '')
    return f"{step}{suffix}{octave}"


def compare(gold_path, engine_path, label, engine_label='engine'):
    gold = extract_notes(gold_path, skip_print_object_no=True)
    engine = extract_notes(engine_path)

    print(f"\n{'='*60}")
    print(f"  {label}  [{engine_label}]")
    print(f"{'='*60}")
    print(f"  Gold notes:    {len(gold)}")
    print(f"  Engine notes:  {len(engine)}")

    n = min(len(gold), len(engine))
    pitch_match = dur_match = both_match = 0
    mismatches = []

    for i in range(n):
        g, e = gold[i], engine[i]
        gp, ep = pitch_str(g), pitch_str(e)
        gd, ed = g[2], e[2]
        p_ok = (gp == ep)
        d_ok = (gd == ed)
        if p_ok:
            pitch_match += 1
        if d_ok:
            dur_match += 1
        if p_ok and d_ok:
            both_match += 1
        else:
            mismatches.append((i + 1, gp, gd, ep, ed))

    pct_pitch = 100 * pitch_match / n if n else 0
    pct_dur = 100 * dur_match / n if n else 0
    pct_both = 100 * both_match / n if n else 0
    extra = abs(len(gold) - len(engine))

    print(f"\n  Pitch accuracy:         {pitch_match}/{n} = {pct_pitch:.1f}%")
    print(f"  Duration accuracy:      {dur_match}/{n} = {pct_dur:.1f}%")
    print(f"  Both correct:           {both_match}/{n} = {pct_both:.1f}%")
    print(f"  Extra/missing notes:    {extra}")
    print(f"\n  First 20 mismatches (pos, gold_pitch, gold_dur, engine_pitch, engine_dur):")
    for m in mismatches[:20]:
        pos, gp, gd, ep, ed = m
        pitch_flag = '' if gp == ep else f'PITCH({gp}->{ep})'
        dur_flag = '' if gd == ed else f'DUR({gd}->{ed})'
        print(f"    [{pos:3d}] {pitch_flag} {dur_flag}")

    print(f"\n  First 40 notes (gold | engine):")
    for i in range(min(40, max(len(gold), len(engine)))):
        gn = f"{pitch_str(gold[i])}/{gold[i][2]}" if i < len(gold) else '---'
        en = f"{pitch_str(engine[i])}/{engine[i][2]}" if i < len(engine) else '---'
        match = 'OK' if gn == en else '!!'
        print(f"    {match} [{i+1:3d}]  gold: {gn:15s}  {engine_label}: {en}")

    return pct_both


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <lr.musicxml> <hf.musicxml>")
        sys.exit(1)

    lr_path, hf_path = sys.argv[1], sys.argv[2]
    import os
    engine_label = os.path.basename(os.path.dirname(lr_path)) or 'engine'

    lr_acc = compare(GOLD['lr'], lr_path, 'Lightly Row', engine_label)
    hf_acc = compare(GOLD['hf'], hf_path, 'Happy Farmer', engine_label)

    print(f"\n{'='*60}")
    print(f"  SUMMARY  [{engine_label}]")
    print(f"{'='*60}")
    print(f"  Lightly Row  (pitch+duration): {lr_acc:.1f}%  {'PASS ✓' if lr_acc >= 90 else 'FAIL ✗'} (target ≥90%)")
    print(f"  Happy Farmer (pitch+duration): {hf_acc:.1f}%  {'PASS ✓' if hf_acc >= 90 else 'FAIL ✗'} (target ≥90%)")
