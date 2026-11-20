import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/count_in.dart';
import '../models/parsed_piece.dart';
import 'audio_decoder.dart';
import 'audio_score_auto_aligner.dart' show ScoreAudioAnchor;
import 'midi_generator.dart';
import 'score_renderer.dart';

/// A rendered score on disk: the file, and its exact alignment.
class RenderedScoreFile {
  final String path;
  final int bpm;
  final double prerollSeconds;
  final List<ScoreAudioAnchor> anchors;

  const RenderedScoreFile({
    required this.path,
    required this.bpm,
    required this.prerollSeconds,
    required this.anchors,
  });
}

/// Renders the score at a tempo (in an isolate) and encodes it as the app's
/// own recordings are — AAC in an MPEG-4 file, by the platform's encoder
/// (`encodeAac` on the decoder channel) — or leaves it a WAV where there is no
/// encoder yet. One audio file and one JSON sidecar per key, in the cache
/// directory; the sidecar is written last, so its presence means the audio is
/// whole.
///
/// The file is built like a recording's: an .mp4 whose AAC priming is in an
/// edit list (`edts`/`elst`) — on iOS, AVAssetWriter with fileType .mp4, since
/// AVAudioFile and fileType .m4a both write it as iTunes gapless metadata
/// (`udta`/iTunSMPB) instead. That was first blamed for loops stalling on
/// AirPlay; it wasn't the cause (a recording stalled too — see
/// MediaTransport.seekFresh), but a generated file that matches a recording
/// leaves one less difference to suspect.
///
/// The key covers everything the sound depends on, and nothing it doesn't: the
/// note schedule (so a fingering or lyric edit re-renders nothing), the
/// tempo, the opening meter and pickup (the woodblock bars), and the
/// soundfont, patch and renderer versions.
class RenderedScoreCache {
  RenderedScoreCache({this.maxFiles = 12});

  /// About four pieces' three renders, ~2 MB for a one-minute piece.
  final int maxFiles;

  /// Bump when the renderer's output changes for the same inputs.
  // 2: an .mp4 by AVAssetWriter on iOS (an edit list, not iTunes gapless
  // metadata), so the old .m4a files, which stalled AirPlay loops, are
  // replaced.
  static const rendererVersion = 2;

  /// Bars of woodblock before the score.
  static const introBars = 3;

  final _inFlight = <String, Future<RenderedScoreFile?>>{};
  Future<Directory?>? _dir;
  Future<_Sound>? _sound;

  Future<Directory?> _open() => _dir ??= () async {
        try {
          final base = await getApplicationCacheDirectory();
          final dir = Directory('${base.path}/rendered_score');
          await dir.create(recursive: true);
          return dir;
        } catch (e) {
          debugPrint('[rendered] cache disabled: $e');
          return null;
        }
      }();

  Future<_Sound> _loadSound() => _sound ??= () async {
        final patch = jsonDecode(await rootBundle
                .loadString('assets/engine/lookup_tables/midi_patch.json'))
            as Map<String, dynamic>;
        final sf = await rootBundle.load(patch['soundfontAsset'] as String);
        return _Sound(
          soundFont: sf,
          program: patch['violin'] as int,
          velocity: patch['noteVelocity'] as int? ?? 90,
        );
      }();

  /// [piece]'s schedule [data], generated at [bpm], as a file — from the
  /// cache, or rendered now. Null if it can't be made.
  Future<RenderedScoreFile?> obtain(
      ParsedPiece piece, MidiData data, int bpm) async {
    final sound = await _loadSound();
    final key = _keyFor(piece, data, bpm, sound);
    return _inFlight[key] ??= _obtain(key, piece, data, bpm, sound)
        .whenComplete(() {
      // A block, not an arrow: the arrow would return the removed future —
      // this one — and whenComplete would wait on itself forever.
      _inFlight.remove(key);
    });
  }

  Future<RenderedScoreFile?> _obtain(String key, ParsedPiece piece,
      MidiData data, int bpm, _Sound sound) async {
    final dir = await _open();
    if (dir == null) return null;
    final sidecar = File('${dir.path}/$key.json');
    final cached = await _read(sidecar, dir);
    if (cached != null) return cached;

    try {
      final sw = Stopwatch()..start();
      final rendered = await _renderInIsolate(sound, piece, data, bpm);
      final renderMs = sw.elapsedMilliseconds;
      final wav = File('${dir.path}/$key.wav');
      await wav.writeAsBytes(rendered.wav, flush: true);
      var audio = wav;
      sw.reset();
      final mp4 = File('${dir.path}/$key.mp4');
      try {
        await AudioDecoder.channel.invokeMethod<void>('encodeAac', {
          'input': wav.path,
          'output': mp4.path,
          'bitRate': 64000,
        });
        await wav.delete();
        audio = mp4;
      } on MissingPluginException {
        // No encoder on this platform yet: the WAV plays as well, only larger.
      } on PlatformException catch (e) {
        debugPrint('[rendered] AAC encode failed, keeping the WAV: $e');
      }
      final line = '[rendered] ${rendered.seconds.toStringAsFixed(1)}s at '
          '$bpm bpm: render ${renderMs}ms, encode ${sw.elapsedMilliseconds}ms '
          '-> ${audio.path.split('/').last} '
          '(${(audio.lengthSync() / 1024).round()} KB)';
      debugPrint(line);
      unawaited(_logTiming(line));
      await sidecar.writeAsString(jsonEncode({
        'file': audio.path.split('/').last,
        'bpm': bpm,
        'preroll': rendered.preroll,
        'anchors': rendered.anchors,
      }));
      _prune(dir);
      return RenderedScoreFile(
        path: audio.path,
        bpm: bpm,
        prerollSeconds: rendered.preroll,
        anchors: [
          for (final a in rendered.anchors) ScoreAudioAnchor(a[0], a[1]),
        ],
      );
    } catch (e, st) {
      debugPrint('[rendered] render failed at $bpm bpm: $e\n$st');
      return null;
    }
  }

  /// Each render's timing, appended to Documents/rendered_score_log.txt, so a
  /// release build on a device can be timed (copy it off with devicectl, as
  /// `scripts/pull_sync_trace.sh` does the trace). Best effort.
  static Future<void> _logTiming(String line) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      await File('${docs.path}/rendered_score_log.txt').writeAsString(
          '${DateTime.now().toIso8601String()} $line\n',
          mode: FileMode.append,
          flush: true);
    } catch (_) {}
  }

  Future<RenderedScoreFile?> _read(File sidecar, Directory dir) async {
    try {
      if (!await sidecar.exists()) return null;
      final j = jsonDecode(await sidecar.readAsString()) as Map<String, dynamic>;
      final audio = File('${dir.path}/${j['file']}');
      if (!await audio.exists()) return null;
      // Touch both, so pruning drops the least recently USED.
      final now = DateTime.now();
      await sidecar.setLastModified(now);
      await audio.setLastModified(now);
      return RenderedScoreFile(
        path: audio.path,
        bpm: j['bpm'] as int,
        prerollSeconds: (j['preroll'] as num).toDouble(),
        anchors: [
          for (final a in j['anchors'] as List)
            ScoreAudioAnchor(
                (a[0] as num).toDouble(), (a[1] as num).toDouble()),
        ],
      );
    } catch (e) {
      debugPrint('[rendered] unreadable cache entry ${sidecar.path}: $e');
      return null;
    }
  }

  void _prune(Directory dir) {
    try {
      final sidecars = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList();
      if (sidecars.length <= maxFiles) return;
      sidecars.sort(
          (a, b) => a.statSync().modified.compareTo(b.statSync().modified));
      for (final f in sidecars.take(sidecars.length - maxFiles)) {
        final stem = f.path.substring(0, f.path.length - '.json'.length);
        for (final ext in const ['.json', '.mp4', '.m4a', '.wav']) {
          final g = File('$stem$ext');
          if (g.existsSync()) g.deleteSync();
        }
      }
    } catch (e) {
      debugPrint('[rendered] prune failed: $e');
    }
  }

  static String _keyFor(
      ParsedPiece piece, MidiData data, int bpm, _Sound sound) {
    final h = _Fnv64()
      ..addInt(rendererVersion)
      ..addInt(introBars)
      ..addInt(bpm)
      ..addInt(sound.program)
      ..addInt(sound.velocity)
      ..addInt(sound.soundFont.lengthInBytes);
    if (piece.measures.isNotEmpty) {
      final m = piece.meters.first;
      h
        ..addInt(m.beats)
        ..addInt(m.beatType)
        ..addInt(pickupUnitsOf(piece.measures.first,
            beatsPerMeasure: m.beats, beatType: m.beatType));
    }
    for (final n in data.notes) {
      h
        ..addInt((n.onsetSeconds * 1e6).round())
        ..addInt((n.offsetSeconds * 1e6).round())
        ..addInt(n.midiNote);
    }
    for (final t in data.measureOnsetSeconds) {
      h.addInt((t * 1e6).round());
    }
    h.addInt((data.totalDurationSeconds * 1e6).round());
    return 'score_${h.hex}';
  }
}

/// Off the UI isolate: a 2-minute piece is a few hundred ms of CPU on a
/// phone. A top-level function, so the closure carries only its arguments.
Future<({Uint8List wav, double preroll, List<List<double>> anchors, double seconds})>
    _renderInIsolate(_Sound sound, ParsedPiece piece, MidiData data, int bpm) =>
        Isolate.run(() {
          final r = ScoreRenderer(sound.soundFont,
                  program: sound.program, velocity: sound.velocity)
              .render(piece, data, bpm,
                  introBars: RenderedScoreCache.introBars);
          return (
            wav: encodeWav(r),
            preroll: r.prerollSeconds,
            anchors: [
              for (final a in r.anchors) [a.scoreMs, a.audioSec]
            ],
            seconds: r.durationSeconds,
          );
        });

class _Sound {
  final ByteData soundFont;
  final int program;
  final int velocity;
  const _Sound(
      {required this.soundFont, required this.program, required this.velocity});
}

/// FNV-1a over 64 bits, as two 32-bit halves so it is exact on every
/// platform's ints.
class _Fnv64 {
  int _hi = 0xcbf29ce4, _lo = 0x84222325;

  void addInt(int v) {
    final b = ByteData(8)..setInt64(0, v);
    for (var i = 0; i < 8; i++) {
      _addByte(b.getUint8(i));
    }
  }

  void _addByte(int byte) {
    _lo ^= byte;
    // Multiply by the FNV prime 0x100000001b3 = 2^40 + 0x1b3.
    final lo = _lo * 0x1b3;
    final hi = _hi * 0x1b3 + (_lo << 8) + (lo >>> 32);
    _lo = lo & 0xffffffff;
    _hi = hi & 0xffffffff;
  }

  String get hex =>
      _hi.toRadixString(16).padLeft(8, '0') +
      _lo.toRadixString(16).padLeft(8, '0');
}

/// For tests: a key with a stand-in soundfont of [soundFontBytes] bytes.
@visibleForTesting
String renderedScoreKey(ParsedPiece piece, MidiData data, int bpm,
        {int program = 40, int velocity = 90, int soundFontBytes = 0}) =>
    RenderedScoreCache._keyFor(
        piece,
        data,
        bpm,
        _Sound(
            soundFont: ByteData(soundFontBytes),
            program: program,
            velocity: velocity));
