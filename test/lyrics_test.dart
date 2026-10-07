import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/models/piece.dart';
import 'package:violin_practice_companion/services/chord_editor.dart';
import 'package:violin_practice_companion/services/lyric_xml_injector.dart';
import 'package:violin_practice_companion/services/measure_xml_editor.dart';
import 'package:violin_practice_companion/services/musicxml_normalizer.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';
import 'package:violin_practice_companion/services/providers.dart';
import 'package:violin_practice_companion/services/verovio_engraver.dart';

/// Lyrics from ABC `w:` lines, end to end short of the engraver: the converter's
/// `<lyric>` output (golden fixtures, regenerated with
/// `node scripts/abc_to_musicxml.cjs test/fixtures/<tune>.abc`), the parser's
/// [NoteEvent.lyrics], verse selection before engraving, and the measure
/// editor not throwing them away.
void main() {
  final parser = MusicXmlParser();

  String golden(String name) =>
      File('test/fixtures/$name.musicxml').readAsStringSync();
  ParsedPiece parse(String xml) =>
      parser.parse(MusicXmlNormalizer.toSoundingPitch(xml));

  /// Verse [v] as "syllable syllable …" with hyphens restored from
  /// `<syllabic>`, read straight off the xml.
  String verseText(String xml, int v) {
    final out = StringBuffer();
    final re = RegExp(
        r'<lyric number="(\d+)"><syllabic>(\w+)</syllabic><text>([^<]*)</text>');
    for (final m in re.allMatches(xml)) {
      if (int.parse(m[1]!) != v) continue;
      final syllabic = m[2]!;
      out.write(m[3]);
      out.write(syllabic == 'begin' || syllabic == 'middle' ? '-' : ' ');
    }
    return out.toString().trim();
  }

  group('converter output', () {
    // `~` in `1.~A` joins two words into one syllable; abcjs hands it back as
    // a non-breaking space, which keeps the engraver from splitting it too.
    test('Amazing Grace: verse 1 reads back as written, hyphens and all', () {
      expect(
        verseText(golden('amazing_grace'), 1),
        startsWith('1.\u00a0A-maz-ing grace, how sweet the sound That saved a '
            'wretch like me. I once was lost,'),
      );
    });

    test('Amazing Grace: held syllables carry <extend/>', () {
      final xml = golden('amazing_grace');
      // `ing__` holds over the rest of the triplet, `me._` over the tie.
      expect(xml, contains('<text>ing</text><extend/>'));
      expect(xml, contains('<text>me.</text><extend/>'));
    });

    test('a verse\'s last syllable never gets an extender', () {
      // Verovio ends an extender only at the verse's next syllable, so one on
      // the last syllable (Circle's trailing `by. _`) ran to the end of the
      // piece under systems with no words at all.
      for (final name in ['circle', 'amazing_grace']) {
        final xml = golden(name);
        for (final v in [1, 2]) {
          final mine = RegExp('<lyric number="$v">.*?</lyric>')
              .allMatches(xml)
              .toList();
          if (mine.isEmpty) continue;
          expect(mine.last[0], isNot(contains('<extend/>')),
              reason: '$name verse $v');
        }
      }
    });

    test('Amazing Grace: the W: verses are kept, not engraved', () {
      final xml = golden('amazing_grace');
      expect(xml, contains('<miscellaneous-field name="abc-words">'));
      expect(xml, contains('Through many dangers'));
      expect(xml, isNot(contains('<credit')));
    });

    test('Amazing Grace: syllables land on the right notes', () {
      final piece = parse(golden('amazing_grace'));
      final sung = [
        for (final n in piece.allNotes)
          if (n.lyrics[1] case final s?) '${n.pitch}:${s.text}',
      ];
      // Pickup D, then G on "maz", the triplet's B on "ing", G on "grace,".
      expect(sung.take(4), ['D4:1.\u00a0A', 'G4:maz', 'B4:ing', 'B4:grace,']);
      // Nothing is ever sung on a rest.
      expect(piece.allNotes.where((n) => n.isRest && n.lyrics.isNotEmpty),
          isEmpty);
    });

    test('Circle: two stacked w: lines become verses 1 and 2', () {
      final piece = parse(golden('circle'));
      expect(piece.verseCount, 2);
      expect(verseText(golden('circle'), 1), startsWith('Will the cir-cle be'));
      expect(verseText(golden('circle'), 2), startsWith('by and by.'));
    });

    test('Gundagai with words: syllables survive ties and long hyphen runs', () {
      final xml = golden('gundagai_lyrics');
      expect(verseText(xml, 1),
          contains('Mur-rum-bid-gee\'s flow-ing be-neath'));
      final bars = parse(xml).measures;
      String? sung(int bar, int note) =>
          bars[bar - 1].notes[note].lyrics[1]?.text;
      // "gai" is held over the tie into bars 8 and 9, so "Where" comes on the
      // second note of bar 9, not the first.
      expect(sung(7, 2), 'gai');
      expect(sung(8, 0), isNull);
      expect(sung(9, 0), isNull);
      expect(sung(9, 1), 'Where');
      expect(xml, contains('<text>gai</text><extend/>'));
    });

    test('Gundagai: a tune without lyrics gets none', () {
      final xml = golden('gundagai');
      expect(xml, isNot(contains('<lyric')));
      final piece = parse(xml);
      expect(piece.verseCount, 0);
      expect(piece.allNotes.where((n) => !n.isRest), isNotEmpty);
    });
  });

  group('parser', () {
    const twoVerses = '''
<score-partwise version="3.1"><part-list><score-part id="P1"/></part-list>
<part id="P1"><measure number="1">
<attributes><divisions>1</divisions><time><beats>2</beats><beat-type>4</beat-type></time></attributes>
<note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration><type>quarter</type>
<lyric number="1"><syllabic>single</syllabic><text>one</text></lyric>
<lyric number="2"><syllabic>single</syllabic><text>two</text></lyric></note>
<note><pitch><step>D</step><octave>4</octave></pitch><duration>1</duration><type>quarter</type>
<lyric><syllabic>single</syllabic><text>bare</text></lyric></note>
</measure></part></score-partwise>''';

    test('reads every verse, keyed by number; a bare <lyric> is verse 1', () {
      final notes = parser.parse(twoVerses).allNotes;
      expect(notes[0].lyrics, {1: const Lyric('one'), 2: const Lyric('two')});
      expect(notes[1].lyrics, {1: const Lyric('bare')});
      expect(parser.parse(twoVerses).verseCount, 2);
    });
  });

  group('LyricXmlInjector.selectVerse', () {
    final xml = golden('circle');

    test('keeps only the chosen verse, renumbered as verse 1', () {
      final v2 = LyricXmlInjector.selectVerse(xml, 2);
      expect(v2, isNot(contains('<lyric number="2"')));
      expect(verseText(v2, 1), verseText(xml, 2));
    });

    test('null strips every lyric', () {
      expect(LyricXmlInjector.selectVerse(xml, null), isNot(contains('<lyric')));
    });

    test('a score with no lyrics comes back untouched', () {
      final plain = golden('gundagai');
      expect(identical(LyricXmlInjector.selectVerse(plain, 1), plain), isTrue);
    });
  });

  group('measure edits', () {
    // Measure 3 of Amazing Grace is `B4 BA` under "grace, how_" — the A is
    // the note "how" is held over.
    final xml = golden('amazing_grace');
    final notes = parser.parse(xml).measures[2].notes;
    List<NoteEvent> saved(List<NoteEvent> edited) => parser
        .parse(MeasureXmlEditor.replaceMeasureNotes(xml, 3, edited, 96))
        .measures[2]
        .notes;

    test('fixing a pitch keeps every syllable as it was, with no warning', () {
      final edited = ChordEditor.replaceAt(notes, 0,
          ChordEditor.repitch(notes[0], pitch: 'C5', midiNumber: 72, octave: 5));
      expect(saved(edited).map((n) => n.lyrics[1]),
          [const Lyric('grace,'), const Lyric('how', extend: true), null]);
      expect(ChordEditor.lyricsMayBeMisaligned(notes, edited), isFalse);
    });

    test('hyphens survive a save: syllabic is part of the model', () {
      // Measure 2: G4 under "maz" (middle), then "ing" (end, held).
      final bar2 = parser.parse(xml).measures[1].notes;
      final out = parser
          .parse(MeasureXmlEditor.replaceMeasureNotes(xml, 2, bar2, 96))
          .measures[1]
          .notes;
      expect(out[0].lyrics[1], const Lyric('maz', syllabic: 'middle'));
      expect(out[1].lyrics[1],
          const Lyric('ing', syllabic: 'end', extend: true));
    });

    test('deleting a sung note hands its words on, and warns', () {
      final edited = ChordEditor.deleteAt(notes, 0).notes;
      expect(saved(edited).first.lyrics[1],
          const Lyric('grace, how', extend: true));
      expect(ChordEditor.lyricsMayBeMisaligned(notes, edited), isTrue);
    });

    test('the last note of a bar hands its words back', () {
      final bar2 = parser.parse(xml).measures[1].notes; // ... "ing" last sung
      final lastSung = bar2.lastIndexWhere((n) => n.lyrics.isNotEmpty);
      final edited =
          ChordEditor.deleteAt(bar2.sublist(0, lastSung + 1), lastSung).notes;
      expect(edited.last.lyrics[1]!.text, endsWith('ing'));
    });

    test('a note made a rest keeps its syllable, and warns', () {
      final edited = ChordEditor.toggleRest(notes, 1);
      final out = saved(edited);
      expect(out[1].isRest, isTrue);
      expect(out[1].lyrics[1]?.text, 'how');
      expect(ChordEditor.lyricsMayBeMisaligned(notes, edited), isTrue);
      // ...and comes back with it.
      final restored = ChordEditor.toggleRest(edited, 1);
      expect(restored[1].lyrics[1]?.text, 'how');
    });

    test('inserting a note warns; a bar with no lyrics never does', () {
      final inserted = ChordEditor.insertAfter(notes, 0, notes[2]).notes;
      expect(ChordEditor.lyricsMayBeMisaligned(notes, inserted), isTrue);
      final plain = parse(golden('gundagai')).measures[1].notes;
      expect(
          ChordEditor.lyricsMayBeMisaligned(
              plain, ChordEditor.deleteAt(plain, 0).notes),
          isFalse);
    });
  });

  group('Lyric.mergedWith', () {
    test('joins inside a word with no space, between words with one', () {
      expect(
          const Lyric('cir', syllabic: 'begin')
              .mergedWith(const Lyric('cle', syllabic: 'end')),
          const Lyric('circle'));
      expect(
          const Lyric('maz', syllabic: 'middle')
              .mergedWith(const Lyric('ing', syllabic: 'end', extend: true)),
          const Lyric('mazing', syllabic: 'end', extend: true));
      expect(const Lyric('the').mergedWith(const Lyric('sound')),
          const Lyric('the sound'));
      expect(
          const Lyric('sound').mergedWith(const Lyric('A', syllabic: 'begin')),
          const Lyric('sound A', syllabic: 'begin'));
    });
  });

  test('the verse choice resets to verse 1 when the piece changes', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(lyricVerseProvider), 1);
    c.read(lyricVerseProvider.notifier).state = 2;
    c.read(selectedPieceProvider.notifier).state =
        const Piece(
            id: 'x', title: 'x', musicXmlFilePath: 'x', sections: []);
    expect(c.read(lyricVerseProvider), 1);
  });

  test('engraved text names a serif the platform has', () {
    // Verovio spaces lyrics with Times metrics; drawn in the iOS fallback sans
    // they ran together. See [VerovioEngraver.resolveTextFont].
    expect(
      VerovioEngraver.resolveTextFont('<text font-family="Times, serif">'),
      '<text font-family="Times New Roman, Times, serif">',
    );
  });

  test('flattening the svg keeps the text font', () {
    // The font is named only on Verovio's inner <svg>, which the flattener
    // replaces with a <g>; it used to take the font-family with it.
    const svg = '<svg viewBox="0 0 100 100">'
        '<svg class="definition-scale" color="black" '
        'font-family="Times New Roman, Times, serif" viewBox="0 0 1000 1000">'
        '<text>la</text></svg></svg>';
    expect(VerovioEngraver.flattenForRenderer(svg),
        contains('<g transform="scale(0.100000, 0.100000)" '
            'font-family="Times New Roman, Times, serif">'));
  });

  test('a system\'s ink reaches down past its lyrics', () {
    // Verovio emits the lyric boxes empty, so without the syllables added by
    // hand a system ended at its notes and the next system's chord bars were
    // drawn over the words. Real Verovio 6.2 output (scale 40, bounding boxes
    // on) of gundagai_lyrics.musicxml, every system of which carries words.
    final svg = File('test/fixtures/verovio_verse.svg').readAsStringSync();
    final withLyrics = VerovioEngraver.systemInkBoxes(svg)!;
    final notesOnly = VerovioEngraver.systemInkBoxes(
        svg.replaceAll('class="syl">', 'class="syl-ignored">'))!;
    expect(withLyrics.length, notesOnly.length);
    expect(withLyrics, isNotEmpty);
    for (var i = 0; i < withLyrics.length; i++) {
      expect(withLyrics[i].bottom, greaterThan(notesOnly[i].bottom),
          reason: 'system $i');
      expect(withLyrics[i].top, notesOnly[i].top, reason: 'system $i');
    }
  });
}
