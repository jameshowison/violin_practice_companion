import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

// The synth swallows a soundfont that fails to load (playback_service_io.dart,
// _initMidi), so a wrong path is silence, not an error: the 2026-11-11 asset
// move left midi_patch.json pointing at assets/soundfonts/ for a day. And the
// bundled bank is cut down to what the app plays (scripts/subset_soundfont.py),
// so a new program would be silence too.
void main() {
  final patch = jsonDecode(
          File('assets/engine/lookup_tables/midi_patch.json').readAsStringSync())
      as Map<String, dynamic>;
  final path = patch['soundfontAsset'] as String;
  final sf2 = File(path);

  test('midi_patch.json points into a folder pubspec bundles', () {
    final dir = path.substring(0, path.lastIndexOf('/') + 1);
    expect(File('pubspec.yaml').readAsStringSync(), contains('- $dir\n'));
    expect(Directory(dir).existsSync(), isTrue, reason: dir);
  });

  test('the bundled bank has the violin program and the claves kit',
      skip: sf2.existsSync()
          ? null
          : '$path not present (gitignored; see README, "The soundfont")',
      () {
    final presets = _presets(sf2.readAsBytesSync());
    expect(presets, contains((0, patch['violin'] as int)));
    // The calibration click: GM drum kit, bank 128 program 0.
    expect(presets, contains((128, 0)));
  });
}

/// (bank, program) of every preset in an SF2's phdr chunk.
Set<(int, int)> _presets(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  String id(int at) => ascii.decode(bytes.sublist(at, at + 4));
  // RIFF sfbk → LIST pdta → phdr; walk chunks rather than assume offsets.
  Set<(int, int)>? walk(int from, int to) {
    var at = from;
    while (at + 8 <= to) {
      final size = data.getUint32(at + 4, Endian.little);
      if (id(at) == 'LIST') {
        final found = walk(at + 12, at + 8 + size);
        if (found != null) return found;
      } else if (id(at) == 'phdr') {
        final out = <(int, int)>{};
        for (var r = at + 8; r + 38 <= at + 8 + size - 38; r += 38) {
          out.add((
            data.getUint16(r + 22, Endian.little),
            data.getUint16(r + 20, Endian.little)
          ));
        }
        return out;
      }
      at += 8 + size + (size & 1);
    }
    return null;
  }

  return walk(12, bytes.length) ?? {};
}
