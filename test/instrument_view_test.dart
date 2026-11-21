import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicxml_tools/musicxml_tools.dart';
import 'package:violin_practice_companion/models/instrument_profile.dart';
import 'package:violin_practice_companion/services/instrument_view.dart';
import 'package:xml/xml.dart';

import 'support/bundled_scores.dart';

/// A viola as the instrument layer will see it: alto clef, C3 to E5. Here
/// only to exercise the view; the real profile arrives with viola support.
const _viola = InstrumentProfile(
  id: 'viola',
  displayName: 'Viola',
  layerId: 'viola',
  clef: altoClef,
  lowestMidi: 48,
  highestMidi: 76,
);

List<NoteEvent> _notes(String xml) =>
    MusicXmlParser().parse(xml).measures.expand((m) => m.notes).toList();

String _alto(String trebleXml) {
  final doc = XmlDocument.parse(trebleXml);
  for (final c in doc.findAllElements('clef')) {
    c.getElement('sign')?.innerText = 'C';
    c.getElement('line')?.innerText = '3';
  }
  return doc.toXmlString();
}

void main() {
  test('violin and mandolin see every treble score exactly as it is', () {
    for (final f in allScoreFixtures()) {
      final xml = f.readAsStringSync();
      for (final p in [InstrumentProfile.violin, InstrumentProfile.mandolin]) {
        final view = InstrumentView.of(p, xml);
        expect(view.isIdentity, isTrue, reason: '${f.path} for ${p.id}');
        expect(identical(view.apply(xml), xml), isTrue);
        final notes = _notes(xml);
        expect(identical(view.toSource(notes), notes), isTrue);
      }
    }
  });

  test('a treble part is shown to a viola in alto, an octave down', () {
    final xml = File(scorePath('lightly_row')).readAsStringSync();
    final view = InstrumentView.of(_viola, xml);
    expect(view.octaves, -1);
    final shown = view.apply(xml);
    final clefs = XmlDocument.parse(shown).findAllElements('clef');
    expect(clefs, isNotEmpty);
    for (final c in clefs) {
      expect(c.getElement('sign')!.innerText, 'C');
      expect(c.getElement('line')!.innerText, '3');
    }
    final source = _notes(xml);
    final viewed = _notes(shown);
    expect(viewed.length, source.length);
    for (var i = 0; i < source.length; i++) {
      if (source[i].isRest) continue;
      expect(viewed[i].midiNumber, source[i].midiNumber - 12);
    }
  });

  test('a note edited on the viola view goes back to the source pitch', () {
    for (final f in bundledScoreFiles()) {
      final xml = f.readAsStringSync();
      final view = InstrumentView.of(_viola, xml);
      final back = view.toSource(_notes(view.apply(xml)));
      final source = _notes(xml);
      for (var i = 0; i < source.length; i++) {
        expect(
            (back[i].pitch, back[i].midiNumber, back[i].octave),
            (source[i].pitch, source[i].midiNumber, source[i].octave),
            reason: '${f.path} note $i');
      }
    }
  });

  test('an alto part is shown to a violin in treble, an octave up', () {
    // Lightly Row an octave down in alto: a viola part.
    final violinXml = File(scorePath('lightly_row')).readAsStringSync();
    final violaPart = InstrumentView.of(_viola, violinXml).apply(violinXml);
    expect(InstrumentView.of(_viola, violaPart).isIdentity, isTrue);

    final view = InstrumentView.of(InstrumentProfile.violin, violaPart);
    expect(view.octaves, 1);
    final shown = _notes(view.apply(violaPart));
    final original = _notes(violinXml);
    for (var i = 0; i < original.length; i++) {
      expect(shown[i].midiNumber, original[i].midiNumber);
    }
  });

  test('a score with no clef is shown as it is', () {
    final xml = _alto(File(scorePath('lightly_row')).readAsStringSync())
        .replaceAll(RegExp(r'<clef[^>]*>.*?</clef>', dotAll: true), '');
    expect(InstrumentView.of(_viola, xml).isIdentity, isTrue);
  });
}
