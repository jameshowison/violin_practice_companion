
import 'package:dart_melty_soundfont/dart_melty_soundfont.dart';

import '../models/count_in.dart';
import '../models/parsed_piece.dart';
import 'audio_score_auto_aligner.dart' show ScoreAudioAnchor;
import 'midi_generator.dart';

/// The synthesized score rendered offline to PCM, so it can play like a
/// recording (docs/rendered-score-plan.md).
///
/// [samples] is mono at [sampleRate]. The file opens with [prerollSeconds] of
/// woodblock count (score time 0 is that far in), and [anchors] map score
/// time at [bpm] to file time — exact, since the file is made from the
/// schedule.
class ScoreRender {
  final Float32List samples;
  final int sampleRate;
  final int bpm;
  final double prerollSeconds;
  final List<ScoreAudioAnchor> anchors;

  /// Sample index of each woodblock click, for checking the encoded file.
  final List<int> clickSamples;

  const ScoreRender({
    required this.samples,
    required this.sampleRate,
    required this.bpm,
    required this.prerollSeconds,
    required this.anchors,
    required this.clickSamples,
  });

  double get durationSeconds => samples.length / sampleRate;
}

/// Renders a [MidiData] schedule through a SoundFont with the pure-Dart
/// MeltySynth port: no platform code, so it runs the same on iOS and Android,
/// in an isolate.
///
/// Sounds as the live synth does: the violin [program] on channel 0 at
/// [velocity], dry (no reverb or chorus). The count is the GM drum kit's
/// woodblocks on channel 9: the high block (76) on each bar's first beat, the
/// low one (77) on the rest.
class ScoreRenderer {
  ScoreRenderer(
    this.soundFont, {
    this.program = 40,
    this.velocity = 90,
    this.sampleRate = 44100,
  });

  final ByteData soundFont;
  final int program;
  final int velocity;
  final int sampleRate;

  static const _violinChannel = 0;
  static const _drumChannel = 9;
  static const highBlock = 76;
  static const lowBlock = 77;
  static const _clickVelocity = 110;
  static const _clickHoldSeconds = 0.08;

  /// After the last note-off, how long the release rings before the file ends.
  static const tailSeconds = 1.0;

  /// Applied to the synth's output, which is quiet (master volume 0.5, and
  /// the mono mix halves it again): this brings a single violin line at
  /// velocity 90 to a peak of about 0.45, with room for a double-stop. The
  /// woodblocks come out at the same level.
  static const _gain = 6.0;

  /// Renders [data] (generated from [piece] at [bpm]) with [introBars] bars
  /// of woodblock count in front, less the opening pickup, as [countInPlan]
  /// counts it. [introBars] 0 gives no count and no pre-roll.
  ScoreRender render(ParsedPiece piece, MidiData data, int bpm,
      {int introBars = 3}) {
    final synth = Synthesizer.loadByteData(
      soundFont,
      SynthesizerSettings(
        sampleRate: sampleRate,
        blockSize: 32,
        maximumPolyphony: 32,
        enableReverbAndChorus: false,
      ),
    );
    synth.processMidiMessage(
        channel: _violinChannel, command: 0xC0, data1: program, data2: 0);

    // The count, in 32nd-note units, from the opening bar's meter.
    final clicks = <(double, int)>[]; // (seconds, key)
    var preroll = 0.0;
    if (introBars > 0 && piece.measures.isNotEmpty) {
      final meter = piece.meters.first;
      final perBar = barCounting(meter.beats, meter.beatType).perBar;
      final pickup = pickupUnitsOf(piece.measures.first,
          beatsPerMeasure: meter.beats, beatType: meter.beatType);
      final plan = countInPlan(
        beatsPerMeasure: meter.beats,
        beatType: meter.beatType,
        minBeats: introBars * perBar,
        pickupUnits: pickup,
      );
      if (plan != null) {
        final unitSec = countInUnitSeconds(bpm);
        preroll = plan.totalUnits * unitSec;
        for (var i = 0; i < plan.labels.length; i++) {
          clicks.add((
            i * plan.unit * unitSec,
            plan.labels[i] == 1 ? highBlock : lowBlock,
          ));
        }
      }
    }

    // Every event at its sample. Offs sort before ons at the same sample, so
    // a repeated pitch is released and then struck again.
    final events = <_Event>[];
    int at(double seconds) => (seconds * sampleRate).round();
    for (final (t, key) in clicks) {
      events.add(_Event(at(t), _drumChannel, key, _clickVelocity));
      events.add(_Event(at(t + _clickHoldSeconds), _drumChannel, key, 0));
    }
    var lastOff = preroll;
    for (final n in data.notes) {
      events.add(_Event(
          at(preroll + n.onsetSeconds), _violinChannel, n.midiNote, velocity));
      events.add(_Event(
          at(preroll + n.offsetSeconds), _violinChannel, n.midiNote, 0));
      if (preroll + n.offsetSeconds > lastOff) {
        lastOff = preroll + n.offsetSeconds;
      }
    }
    events.sort((a, b) {
      final c = a.sample.compareTo(b.sample);
      if (c != 0) return c;
      return a.velocity.compareTo(b.velocity); // offs (0) first
    });

    final end = at(
        (preroll + data.totalDurationSeconds > lastOff
                ? preroll + data.totalDurationSeconds
                : lastOff) +
            tailSeconds);
    final out = Float32List(end);
    const chunk = 4096;
    final left = Float32List(chunk);
    final right = Float32List(chunk);
    var pos = 0;
    void renderTo(int until) {
      while (pos < until) {
        final n = (until - pos) < chunk ? until - pos : chunk;
        final l = n == chunk ? left : Float32List.sublistView(left, 0, n);
        final r = n == chunk ? right : Float32List.sublistView(right, 0, n);
        synth.render(l, r);
        for (var i = 0; i < n; i++) {
          out[pos + i] = ((l[i] + r[i]) * 0.5 * _gain).clamp(-1.0, 1.0);
        }
        pos += n;
      }
    }

    for (final e in events) {
      renderTo(e.sample < end ? e.sample : end);
      if (e.velocity > 0) {
        synth.noteOn(channel: e.channel, key: e.key, velocity: e.velocity);
      } else {
        synth.noteOff(channel: e.channel, key: e.key);
      }
    }
    renderTo(end);

    return ScoreRender(
      samples: out,
      sampleRate: sampleRate,
      bpm: bpm,
      prerollSeconds: preroll,
      anchors: [
        for (final onset in data.measureOnsetSeconds)
          ScoreAudioAnchor(onset * 1000, preroll + onset),
      ],
      clickSamples: [for (final (t, _) in clicks) at(t)],
    );
  }
}

class _Event {
  final int sample;
  final int channel;
  final int key;
  final int velocity; // 0 = off
  const _Event(this.sample, this.channel, this.key, this.velocity);
}

/// [render] as a 16-bit PCM mono WAV, for listening and for the spike.
Uint8List encodeWav(ScoreRender render) {
  final n = render.samples.length;
  final b = ByteData(44 + n * 2);
  void tag(int o, String s) {
    for (var i = 0; i < 4; i++) {
      b.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  b.setUint32(4, 36 + n * 2, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, render.sampleRate, Endian.little);
  b.setUint32(28, render.sampleRate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  b.setUint32(40, n * 2, Endian.little);
  for (var i = 0; i < n; i++) {
    final v = (render.samples[i] * 32767).round().clamp(-32768, 32767);
    b.setInt16(44 + i * 2, v, Endian.little);
  }
  return b.buffer.asUint8List();
}
