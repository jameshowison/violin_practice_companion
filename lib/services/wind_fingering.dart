import 'dart:ui' show Color;

import 'package:musicxml_tools/musicxml_tools.dart';
import 'package:score_view/score_view.dart' show EngravedMeasureMap;

import '../models/recorder_fingering.dart';
import 'fingering_annotation_builder.dart' show stackVoiceIndex;
import 'midi_generator.dart' show HighlightEvent;

/// What a wind's fingering side panel and colour lane need from a piece:
/// the notes in the order they are played, which one is current, and each
/// note's group (docs/family/windlings-app.md, step W2).

/// One struck note in playing order. [performanceIndex] is the pass
/// ([HighlightEvent.performanceIndex]); -1 when the order is the document's.
typedef PlayedNote = ({
  int measureNumber,
  int noteIndex,
  int midi,
  String pitch,
  int performanceIndex,
});

/// The struck notes of [parsed] in playing order: from the player's
/// highlight [events] (repeats unfolded) when there are any, else in
/// document order. Rests, chord members below the top and tie continuations
/// are left out: none of them asks for a new fingering.
List<PlayedNote> playingOrder(ParsedPiece parsed, List<HighlightEvent> events) {
  final byNumber = {for (final m in parsed.measures) m.number: m};
  final out = <PlayedNote>[];
  if (events.isNotEmpty) {
    for (final e in events) {
      if (e.restBeat != null || e.isTieContinuation) continue;
      final m = byNumber[e.measureNumber];
      if (m == null || e.noteIndex < 0 || e.noteIndex >= m.notes.length) {
        continue;
      }
      final k = stackVoiceIndex(m.notes, e.noteIndex);
      if (k == null) continue;
      final n = m.notes[k];
      if (n.isRest || n.tieStop) continue;
      if (out.isNotEmpty) {
        final last = out.last;
        if (last.performanceIndex == e.performanceIndex &&
            last.measureNumber == m.number &&
            last.noteIndex == k) {
          continue;
        }
      }
      out.add((
        measureNumber: m.number,
        noteIndex: k,
        midi: n.midiNumber,
        pitch: n.pitch,
        performanceIndex: e.performanceIndex,
      ));
    }
    if (out.isNotEmpty) return out;
  }
  for (final m in parsed.measures) {
    for (var j = 0; j < m.notes.length; j++) {
      final k = stackVoiceIndex(m.notes, j);
      if (k == null) continue;
      final n = m.notes[k];
      if (n.isRest || n.tieStop) continue;
      out.add((
        measureNumber: m.number,
        noteIndex: k,
        midi: n.midiNumber,
        pitch: n.pitch,
        performanceIndex: -1,
      ));
    }
  }
  return out;
}

/// The index into [order] of the note the panel shows, or null when [order]
/// is empty.
///
/// - While playing ([playing] non-null): the note being played. Over a rest
///   it is the next note, to get ready for; over a held tie, the note held.
/// - Stopped: the note last tapped ([tapped], a model measure number and
///   note index), if it is inside the [selectionStart..selectionEnd] bars or
///   nothing is selected; else the selection's first note (on its pass,
///   [selectionPerf], when that is pinned); else the first note.
int? focusIndex(
  List<PlayedNote> order, {
  HighlightEvent? playing,
  ({int measure, int note})? tapped,
  ({int startMeasure, int startNote, int endMeasure, int startPerf})?
      selection,
}) {
  if (order.isEmpty) return null;
  if (playing != null) {
    final byPass = order.first.performanceIndex >= 0;
    int cmp(PlayedNote o) {
      if (byPass) {
        final c = o.performanceIndex.compareTo(playing.performanceIndex);
        if (c != 0) return c;
      } else if (o.measureNumber != playing.measureNumber) {
        return -1; // unknown order: only the same bar compares
      }
      return o.noteIndex.compareTo(playing.noteIndex);
    }

    if (playing.isTieContinuation) {
      for (var i = order.length - 1; i >= 0; i--) {
        if (cmp(order[i]) <= 0 &&
            (byPass || order[i].measureNumber == playing.measureNumber)) {
          return i;
        }
      }
    }
    for (var i = 0; i < order.length; i++) {
      final o = order[i];
      if (!byPass && o.measureNumber != playing.measureNumber) continue;
      if (cmp(o) >= 0) return i;
    }
  }
  int? firstAt(int measure, int note, {int perf = -1}) {
    for (var i = 0; i < order.length; i++) {
      final o = order[i];
      if (perf >= 0 && o.performanceIndex >= 0 && o.performanceIndex < perf) {
        continue;
      }
      if (o.measureNumber == measure && o.noteIndex >= note) return i;
    }
    return null;
  }

  if (tapped != null &&
      (selection == null ||
          (tapped.measure >= selection.startMeasure &&
              tapped.measure <= selection.endMeasure))) {
    final i = firstAt(tapped.measure, tapped.note) ??
        firstAt(tapped.measure, 0);
    if (i != null) return i;
  }
  if (selection != null) {
    for (var m = selection.startMeasure; m <= selection.endMeasure; m++) {
      final i = firstAt(m, m == selection.startMeasure ? selection.startNote : 0,
          perf: selection.startPerf);
      if (i != null) return i;
    }
  }
  return 0;
}

/// One coloured dash under a note on the engraved staff: the lane.
/// Addressed like `FingeringAnnotation` (engraved measure index, note index).
typedef NoteLaneDash = ({int measureIndex, int noteIndex, Color color});

/// A dash for every struck note of [parsed] that [chart] has, coloured by its
/// group through [colorOf]. Notes off the chart get none.
List<NoteLaneDash> windLaneDashes(
  EngravedMeasureMap measureMap,
  ParsedPiece parsed,
  HoleFingeringChart chart,
  Color Function(FingeringGroup) colorOf,
) {
  final out = <NoteLaneDash>[];
  for (final m in parsed.measures) {
    if (measureMap.firstIndexOf(m.number) < 0) continue;
    for (var j = 0; j < m.notes.length; j++) {
      final k = stackVoiceIndex(m.notes, j);
      if (k == null) continue;
      final n = m.notes[k];
      if (n.isRest) continue;
      final entry = chart[n.midiNumber];
      if (entry == null) continue;
      final at = measureMap.locate(m.number, k);
      if (at == null) continue;
      out.add((
        measureIndex: at.index,
        noteIndex: at.note,
        color: colorOf(entry.group),
      ));
    }
  }
  return out;
}
