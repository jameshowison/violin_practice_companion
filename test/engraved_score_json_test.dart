import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/verovio_engraver.dart';

// The on-disk engrave cache hands back EngravedScore.fromJson(toJson()) in
// place of a real engrave, so the round trip must be lossless.
void main() {
  test('EngravedScore survives a JSON round trip', () {
    const r = Rect.fromLTRB(1.5, 2, 30.25, 40);
    final score = EngravedScore(
      viewBox: const Size(800, 1200.5),
      svg: '<svg viewBox="0 0 800 1200.5"><g/></svg>',
      bboxById: {'n1': r},
      measures: const [MeasureAnchor(index: 0, id: 'm1', rect: r)],
      notes: const [
        NoteAnchor(
            id: 'n1', measureIndex: 0, noteIndex: 0, isRest: false, rect: r,
            beatPosition: 0.25),
        NoteAnchor(
            id: 'r1', measureIndex: 0, noteIndex: 1, isRest: true, rect: r),
      ],
      meterSigs: const [r],
      keyAccids: const [r, r],
      measureLine: const [0, 0, 1],
      lineBands: const [(top: 0, bottom: 100), (top: 110, bottom: 210.5)],
      lineContent: const [(top: 5, bottom: 95)],
      fingAnchors: const [(line: 0, x: 12, y: -3.5)],
      harmAnchors: const [(line: 1, x: 40.5, y: 100)],
      pageWidthUnits: 2000,
      renderMs: 42,
    );
    final back = EngravedScore.fromJson(
        jsonDecode(jsonEncode(score.toJson())) as Map<String, dynamic>);

    expect(back.viewBox, score.viewBox);
    expect(back.svg, score.svg);
    expect(back.bboxById, score.bboxById);
    expect(back.measures.single.id, 'm1');
    expect(back.measures.single.rect, r);
    expect(back.notes.map((n) => (n.id, n.isRest, n.beatPosition, n.rect)),
        score.notes.map((n) => (n.id, n.isRest, n.beatPosition, n.rect)));
    expect(back.meterSigs, score.meterSigs);
    expect(back.keyAccids, score.keyAccids);
    expect(back.measureLine, score.measureLine);
    expect(back.lineBands, score.lineBands);
    expect(back.lineContent, score.lineContent);
    expect(back.fingAnchors, score.fingAnchors);
    expect(back.harmAnchors, score.harmAnchors);
    expect(back.pageWidthUnits, 2000);
    expect(back.renderMs, 42);
    expect(back.systemHeightViewBox, score.systemHeightViewBox);
  });
}
