import 'package:xml/xml.dart';

import '../models/note_event.dart';
import '../models/parsed_piece.dart';

/// The 2-staff MusicXML for the mandolin-style tab view, plus the ordered list
/// of fingering labels that the SVG post-process swaps in for the native fret
/// numbers (see [VerovioEngraver] and the tab-view plan).
class TabScore {
  /// MusicXML with a second, 4-line tab staff added below the melody.
  final String musicXml;

  /// One label per rendered tab fret, in document order (matches the order the
  /// `<g class="note">`+`<text>` groups appear in the engraved SVG). Empty when
  /// the piece has no tabbable notes.
  final List<String> fingerLabels;

  const TabScore(this.musicXml, this.fingerLabels);
}

/// Builds the tab-view score by adding a second `<staff>` to the melody's
/// MusicXML: staff 1 keeps the standard notation, staff 2 is a 4-line guitar-tab
/// staff carrying each note's violin string + fret.
///
/// Why a MusicXML→MusicXML transform (not MEI): Verovio's MusicXML importer
/// renders a tab staff natively — aligned, with a "T-A-B" clef and rhythm stems
/// — as long as we DON'T emit `<staff-tuning>` (with it, Verovio picks
/// `tab.lute.italian`, drawing frets as SMuFL glyphs; without it, it picks
/// `tab.guitar`, drawing them as swappable `<text>`). String placement is by
/// `<string>` number, independent of tuning, so we supply string+fret explicitly.
///
/// Correlation with the model mirrors [FingeringXmlInjector.inject]: `<note>`
/// elements in document order line up with `parsed.measures.expand(notes)`.
/// Assumes single-voice melodies (these practice pieces are) — one `<backup>`
/// per measure replays its full duration onto staff 2.
class TabScoreGenerator {
  /// Open-string MIDI (from `assets/lookup_tables/fingering_first_position.json`).
  static const _openMidi = {'E': 76, 'A': 69, 'D': 62, 'G': 55};

  /// Violin string → tab string number (1 = top line = E, 4 = bottom = G).
  static const _stringNum = {'E': 1, 'A': 2, 'D': 3, 'G': 4};

  // MusicXML child-order (schema sequence) for stable, importer-friendly output.
  static const _attrOrder = [
    'footnote', 'level', 'divisions', 'key', 'time', 'staves', 'part-symbol',
    'instruments', 'clef', 'staff-details', 'measure-style',
  ];
  static const _noteOrder = [
    'grace', 'cue', 'chord', 'pitch', 'unpitched', 'rest', 'duration', 'tie',
    'instrument', 'footnote', 'level', 'voice', 'type', 'dot', 'accidental',
    'time-modification', 'stem', 'notehead', 'notehead-text', 'staff', 'beam',
    'notations', 'lyric', 'play',
  ];

  /// [fretMode] true when the view shows fret numbers (no fingering-label swap).
  /// [preferOpenFrets] (fret mode only) assigns each note to the highest open
  /// string so frets stay ≤6, instead of following the fingering's string.
  static TabScore generate(
    String musicXml,
    ParsedPiece parsed, {
    bool fretMode = false,
    bool preferOpenFrets = false,
  }) {
    final doc = XmlDocument.parse(musicXml);
    final noteEvents = parsed.measures.expand((m) => m.notes).toList();
    final labels = <String>[];

    // Set up the tab staff. OMR output (homr) splits <attributes> across two
    // blocks — a divisions-only one, then clef/key/time — so two elements must
    // be targeted separately:
    //   * <staves>2 goes in the FIRST block: Verovio fixes the staff count from
    //     the first attributes it sees, so if <staves> arrives later it reports
    //     "Staff 2 cannot be found" and asserts (isTablature) on the tab notes.
    //   * the melody clef lives in whichever block has a <clef>; the TAB clef
    //     (number 2) and staff-details join it there, and we tag (never
    //     duplicate) the existing clef as number 1.
    // Hand-authored pieces have a single attributes block, so both resolve to
    // the same element and this matches the original single-block behaviour.
    final allAttrs = doc.findAllElements('attributes').toList();
    if (allAttrs.isNotEmpty) {
      final clefBlock = allAttrs.firstWhere(
        (a) => a.findElements('clef').isNotEmpty,
        orElse: () => allAttrs.first,
      );
      _setupTabStaff(allAttrs.first, clefBlock);
    }

    var idx = 0;

    for (final measure in doc.findAllElements('measure').toList()) {
      final notes = measure.findElements('note').toList();

      // Pass 1: tag the melody onto staff 1, resolve each note's tab data, and
      // sum the measure duration for the <backup>.
      final tabInfo = <_TabNote>[]; // parallel to `notes`
      var measureDur = 0;
      for (final noteEl in notes) {
        final invisible = noteEl.getAttribute('print-object') == 'no';
        final isChord = noteEl.findElements('chord').isNotEmpty;
        if (!isChord) {
          measureDur += int.tryParse(
                  noteEl.findElements('duration').firstOrNull?.innerText ?? '') ??
              0;
        }
        // OMR notes already carry <staff>1</staff>; strip any existing <staff>
        // before tagging staff 1 so melody notes don't end up with duplicate
        // (invalid) <staff> elements. Mirrors the staff-2 cleanup in
        // _toTabNote. No-op for hand-authored pieces (no pre-existing <staff>).
        for (final s in noteEl.findElements('staff').toList()) {
          noteEl.children.remove(s);
        }
        _insertOrdered(noteEl, _el('staff', text: '1'), _noteOrder);

        final isRest = noteEl.findElements('rest').isNotEmpty;
        if (invisible || isRest) {
          tabInfo.add(_TabNote.silent());
          if (!invisible) {
            // A visible rest still consumes a model note in the injector's
            // scheme; advance to stay aligned.
            if (idx < noteEvents.length) idx++;
          }
          continue;
        }
        final ne = idx < noteEvents.length ? noteEvents[idx++] : null;
        tabInfo.add(_resolve(ne, preferOpenFrets && fretMode));
      }

      // Pass 2: replay the measure onto staff 2 as tab notes.
      if (notes.isNotEmpty) {
        measure.children.add(_backup(measureDur));
        for (var i = 0; i < notes.length; i++) {
          final clone = notes[i].copy();
          _toTabNote(clone, tabInfo[i]);
          if (tabInfo[i].hasFret) labels.add(tabInfo[i].label);
          measure.children.add(clone);
        }
      }
    }

    // Fret mode shows Verovio's native (now-capped) fret numbers directly — no
    // fingering-label swap, so no labels are needed.
    return TabScore(doc.toXmlString(), fretMode ? const [] : labels);
  }

  /// Resolve a model note to its tab string/fret/label.
  ///
  /// String choice: when [preferOpenFrets] (beginner fret mode), always use the
  /// highest open string ([_deriveString], fret ≤6), ignoring the fingering's
  /// string. Otherwise prefer the app's chosen `fingerString`, falling back to
  /// the derived string for notes outside the first-position table.
  ///
  /// Label is the fingering (verbatim, incl. L/H) or, when none was computed,
  /// the fret number so the tab stays complete (used only for the fingering-mode
  /// text swap; fret mode shows the native fret).
  static _TabNote _resolve(NoteEvent? ne, bool preferOpenFrets) {
    if (ne == null || ne.isRest) return _TabNote.silent();
    final letter = preferOpenFrets
        ? _deriveString(ne.midiNumber)
        : (ne.fingerString ?? _deriveString(ne.midiNumber));
    final open = _openMidi[letter]!;
    final fret = ne.midiNumber - open;
    final stringNum = _stringNum[letter]!;
    final label = ne.fingerNumber ?? '$fret';
    return _TabNote(stringNum: stringNum, fret: fret, label: label);
  }

  /// Highest string on which [midi] plays with a small (first-position) fret.
  static String _deriveString(int midi) {
    for (final s in const ['E', 'A', 'D', 'G']) {
      final fret = midi - _openMidi[s]!;
      if (fret >= 0 && fret <= 6) return s;
    }
    return midi >= _openMidi['E']! ? 'E' : 'G';
  }

  /// Add `<staves>2</staves>` to [stavesAttrs], and the staff-2 TAB clef +
  /// 4-line staff-details (plus a number="1" tag on the existing melody clef)
  /// to [clefAttrs]. These are usually the same element; they differ only when
  /// the source splits attributes (OMR output — see [generate]). No
  /// `<staff-tuning>` (keeps the `tab.guitar` import → swappable `<text>`
  /// frets). All inserts respect schema order.
  static void _setupTabStaff(XmlElement stavesAttrs, XmlElement clefAttrs) {
    _insertOrdered(stavesAttrs, _el('staves', text: '2'), _attrOrder);
    // Staff-1 clef: tag an existing one as number="1" (avoid a duplicate),
    // otherwise add an explicit treble clef.
    final existingClef = clefAttrs.findElements('clef').firstOrNull;
    if (existingClef != null) {
      if (existingClef.getAttribute('number') == null) {
        existingClef.setAttribute('number', '1');
      }
    } else {
      _insertOrdered(
          clefAttrs,
          _el('clef', attrs: {'number': '1'}, children: [
            _el('sign', text: 'G'),
            _el('line', text: '2'),
          ]),
          _attrOrder);
    }
    _insertOrdered(
        clefAttrs,
        _el('clef', attrs: {'number': '2'}, children: [
          _el('sign', text: 'TAB'),
          _el('line', text: '5'),
        ]),
        _attrOrder);
    _insertOrdered(
        clefAttrs,
        _el('staff-details', attrs: {'number': '2'}, children: [
          _el('staff-lines', text: '4'),
        ]),
        _attrOrder);
  }

  /// Turn a cloned melody note into its staff-2 tab counterpart: drop staff-1
  /// decoration, set `<staff>2</staff>`, and (for pitched notes) add the
  /// string/fret technical. `<beam>` is kept so Verovio beams the tab rhythm
  /// stems the same way as the melody staff (matching standard tab engraving);
  /// `<stem>` is dropped since the tab draws its own duration symbols.
  static void _toTabNote(XmlElement note, _TabNote info) {
    for (final tag in const ['stem', 'lyric', 'notations', 'staff']) {
      for (final e in note.findElements(tag).toList()) {
        note.children.remove(e);
      }
    }
    if (info.hasFret) {
      _insertOrdered(
          note,
          _el('notations', children: [
            _el('technical', children: [
              _el('string', text: '${info.stringNum}'),
              _el('fret', text: '${info.fret}'),
            ]),
          ]),
          _noteOrder);
    }
    _insertOrdered(note, _el('staff', text: '2'), _noteOrder);
  }

  static XmlElement _backup(int duration) => _el('backup', children: [
        _el('duration', text: '$duration'),
      ]);

  // ── xml helpers ──────────────────────────────────────────────────────────

  static XmlElement _el(String name,
      {String? text,
      Map<String, String> attrs = const {},
      List<XmlElement> children = const []}) {
    return XmlElement(
      XmlName(name),
      [for (final e in attrs.entries) XmlAttribute(XmlName(e.key), e.value)],
      [if (text != null) XmlText(text), ...children],
    );
  }

  /// Insert [child] into [parent] at the position dictated by [order] (ranking
  /// by element tag; unknown tags sort last). Text/whitespace nodes are ignored
  /// for ranking but left in place.
  static void _insertOrdered(
      XmlElement parent, XmlElement child, List<String> order) {
    final rank = order.indexOf(child.name.local);
    final kids = parent.children;
    for (var i = 0; i < kids.length; i++) {
      final k = kids[i];
      if (k is XmlElement) {
        final er = order.indexOf(k.name.local);
        final erank = er < 0 ? order.length : er;
        if (erank > rank) {
          kids.insert(i, child);
          return;
        }
      }
    }
    kids.add(child);
  }
}

class _TabNote {
  final int stringNum;
  final int fret;
  final String label;
  final bool hasFret;
  const _TabNote({required this.stringNum, required this.fret, required this.label})
      : hasFret = true;
  const _TabNote.silent()
      : stringNum = 0,
        fret = 0,
        label = '',
        hasFret = false;
}
