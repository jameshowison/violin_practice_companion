#!/usr/bin/env python3
"""Cut a SoundFont 2 bank down to the presets the app actually plays.

The app plays two sounds through flutter_midi_pro (playback_service_io.dart):
the violin (bank 0, program 40, from assets/engine/lookup_tables/midi_patch.json)
and one claves note from the GM drum kit (bank 128, program 0, key 75) for the
calibration click. GeneralUser GS is ~31 MB for all 260-odd presets; this keeps
those two, the instrument zones they reach, and only the samples those zones
play, so the bundled bank is a small fraction of that. GeneralUser GS's licence
allows modifying it (assets/engine/licenses/generaluser_gs.txt).

    python3 scripts/subset_soundfont.py ../GeneralUser-GS/GeneralUser-GS.sf2 \
        assets/engine/soundfonts/generaluser_gs.sf2 --keep 0:40 --keep 128:0:75

--keep BANK:PROGRAM keeps a whole preset; BANK:PROGRAM:KEY[,KEY...] keeps only
the zones whose key range covers one of those keys (plus global zones). If you
make the app play anything else, add it here and rerun.

Every sample is copied with its 46 trailing guard points, linked stereo
partners are kept and relinked, and preset/bank numbers are unchanged, so
loadSoundfontAsset/selectInstrument calls need no change.
"""
import argparse
import struct
import sys

GEN_KEY_RANGE = 43
GEN_INSTRUMENT = 41
GEN_SAMPLE_ID = 53
GUARD = 46  # zero points the spec requires after each sample


def chunks(data, off, end):
    while off < end:
        cid = data[off:off + 4]
        size = struct.unpack_from('<I', data, off + 4)[0]
        yield cid, off + 8, size
        off += 8 + size + (size & 1)


def read_riff(path):
    data = open(path, 'rb').read()
    assert data[:4] == b'RIFF' and data[8:12] == b'sfbk', 'not an SF2 file'
    lists = {}
    for cid, start, size in chunks(data, 12, len(data)):
        assert cid == b'LIST'
        kind = data[start:start + 4]
        lists[kind] = {c: data[s:s + n] for c, s, n in chunks(data, start + 4, start + size)}
    return lists


def records(blob, fmt):
    n = struct.calcsize(fmt)
    return [struct.unpack_from(fmt, blob, i) for i in range(0, len(blob), n)]


PHDR, BAG, MOD, GEN, INST, SHDR = '<20sHHHIII', '<HH', '<HHhHH', '<HH', '<20sH', '<20sIIIIIBbHH'


def zones(headers, bag_index_field, bags, gens, mods):
    """For each header (minus the terminal), its zones as (gens, mods) lists."""
    out = []
    for i in range(len(headers) - 1):
        b0, b1 = headers[i][bag_index_field], headers[i + 1][bag_index_field]
        zs = []
        for b in range(b0, b1):
            g0, m0 = bags[b]
            g1, m1 = bags[b + 1]
            zs.append((gens[g0:g1], mods[m0:m1]))
        out.append(zs)
    return out


def key_range(zone_gens):
    for oper, amount in zone_gens:
        if oper == GEN_KEY_RANGE:
            return amount & 0xFF, amount >> 8
    return 0, 127


def covers(zone_gens, keys):
    if keys is None:
        return True
    lo, hi = key_range(zone_gens)
    return any(lo <= k <= hi for k in keys)


def has_gen(zone_gens, oper):
    return any(o == oper for o, _ in zone_gens)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('src')
    ap.add_argument('dst')
    ap.add_argument('--keep', action='append', required=True,
                    help='BANK:PROGRAM or BANK:PROGRAM:KEY[,KEY...]')
    args = ap.parse_args()

    keep = {}
    for k in args.keep:
        parts = k.split(':')
        keys = None if len(parts) == 2 else {int(x) for x in parts[2].split(',')}
        keep[(int(parts[0]), int(parts[1]))] = keys

    riff = read_riff(args.src)
    pdta, sdta = riff[b'pdta'], riff[b'sdta']
    if b'sm24' in sdta:
        sys.exit('sm24 (24-bit) banks are not handled')
    smpl = sdta[b'smpl']

    phdr = records(pdta[b'phdr'], PHDR)
    pbag, pmod, pgen = records(pdta[b'pbag'], BAG), records(pdta[b'pmod'], MOD), records(pdta[b'pgen'], GEN)
    inst = records(pdta[b'inst'], INST)
    ibag, imod, igen = records(pdta[b'ibag'], BAG), records(pdta[b'imod'], MOD), records(pdta[b'igen'], GEN)
    shdr = records(pdta[b'shdr'], SHDR)
    pzones = zones(phdr, 3, pbag, pgen, pmod)
    izones = zones(inst, 1, ibag, igen, imod)

    new_presets = []   # (header, [zones])
    inst_map = {}      # (old instrument, keys) -> new index
    new_insts = []     # (name, [zones])
    sample_map = {}    # old sample -> new index
    sample_order = []

    def want_sample(s):
        if s in sample_map:
            return sample_map[s]
        sample_map[s] = len(sample_order)
        sample_order.append(s)
        link, stype = shdr[s][8], shdr[s][9]
        if stype & 0x7 in (2, 4, 8):  # right/left/linked: keep the partner too
            want_sample(link)
        return sample_map[s]

    def want_inst(i, keys):
        key = (i, frozenset(keys) if keys else None)
        if key in inst_map:
            return inst_map[key]
        zs = []
        for g, m in izones[i]:
            is_global = not has_gen(g, GEN_SAMPLE_ID)
            if not is_global and not covers(g, keys):
                continue
            g = [(o, want_sample(a) if o == GEN_SAMPLE_ID else a) for o, a in g]
            zs.append((g, m))
        inst_map[key] = len(new_insts)
        new_insts.append((inst[i][0], zs))
        return inst_map[key]

    found = set()
    for p, h in enumerate(phdr[:-1]):
        bank, program = h[2], h[1]
        if (bank, program) not in keep:
            continue
        found.add((bank, program))
        keys = keep[(bank, program)]
        zs = []
        for g, m in pzones[p]:
            is_global = not has_gen(g, GEN_INSTRUMENT)
            if not is_global and not covers(g, keys):
                continue
            g = [(o, want_inst(a, keys) if o == GEN_INSTRUMENT else a) for o, a in g]
            zs.append((g, m))
        new_presets.append((h, zs))
    missing = set(keep) - found
    if missing:
        sys.exit(f'presets not in {args.src}: {sorted(missing)}')

    # Sample data: each kept sample with its guard points, rebased.
    new_smpl = bytearray()
    new_shdr = []
    for s in sample_order:
        name, start, end, sl, el, rate, pitch, corr, link, stype = shdr[s]
        base = len(new_smpl) // 2
        new_smpl += smpl[start * 2:end * 2]
        new_smpl += b'\0' * (GUARD * 2)
        new_link = sample_map.get(link, 0) if stype & 0x7 in (2, 4, 8) else 0
        new_shdr.append((name, base, base + end - start, base + sl - start,
                         base + el - start, rate, pitch, corr, new_link, stype))

    def pack_zones(groups):
        """Headers' zones -> (bag, gen, mod) blobs and each group's bag start."""
        bags, gens, mods, starts = [], [], [], []
        for zs in groups:
            starts.append(len(bags))
            for g, m in zs:
                bags.append((len(gens), len(mods)))
                gens.extend(g)
                mods.extend(m)
        starts.append(len(bags))
        bags.append((len(gens), len(mods)))
        gens.append((0, 0))
        mods.append((0, 0, 0, 0, 0))
        blob = lambda fmt, rs: b''.join(struct.pack(fmt, *r) for r in rs)
        return blob(BAG, bags), blob(GEN, gens), blob(MOD, mods), starts

    pb, pg, pm, pstarts = pack_zones([zs for _, zs in new_presets])
    ib, ig, im, istarts = pack_zones([zs for _, zs in new_insts])
    phdr_out = b''.join(struct.pack(PHDR, h[0], h[1], h[2], pstarts[i], h[4], h[5], h[6])
                        for i, (h, _) in enumerate(new_presets))
    phdr_out += struct.pack(PHDR, b'EOP', 0, 0, pstarts[-1], 0, 0, 0)
    inst_out = b''.join(struct.pack(INST, n, istarts[i]) for i, (n, _) in enumerate(new_insts))
    inst_out += struct.pack(INST, b'EOI', istarts[-1])
    shdr_out = b''.join(struct.pack(SHDR, *r) for r in new_shdr)
    shdr_out += struct.pack(SHDR, b'EOS', 0, 0, 0, 0, 0, 0, 0, 0, 0)

    def chunk(cid, body):
        return cid + struct.pack('<I', len(body)) + body + (b'\0' if len(body) & 1 else b'')

    def lst(kind, items):
        body = kind + b''.join(chunk(c, b) for c, b in items)
        return chunk(b'LIST', body)

    info = list(riff[b'INFO'].items())
    note = b'Subset for Stringlings by scripts/subset_soundfont.py: ' + \
        ', '.join(args.keep).encode() + b'\0'
    info = [(c, b) for c, b in info if c != b'ICMT'] + [(b'ICMT', note)]
    body = b'sfbk' + lst(b'INFO', info) + lst(b'sdta', [(b'smpl', bytes(new_smpl))]) + lst(b'pdta', [
        (b'phdr', phdr_out), (b'pbag', pb), (b'pmod', pm), (b'pgen', pg),
        (b'inst', inst_out), (b'ibag', ib), (b'imod', im), (b'igen', ig),
        (b'shdr', shdr_out)])
    open(args.dst, 'wb').write(chunk(b'RIFF', body))
    print(f'{args.dst}: {len(new_presets)} presets, {len(new_insts)} instruments, '
          f'{len(sample_order)} samples, {len(body) / 1e6:.1f} MB '
          f'(from {len(phdr) - 1} presets, {len(shdr) - 1} samples)')


if __name__ == '__main__':
    main()
