import 'package:xml/xml.dart';

import 'measure_xml_editor.dart';
import 'musicxml_parser.dart';

/// One place where a MusicXML file says the same thing twice and the two
/// copies disagree. [measure] is the bar's `number` attribute.
class Inconsistency {
  final String kind;
  final String measure;
  final String detail;
  const Inconsistency(this.kind, this.measure, this.detail);

  @override
  String toString() => '$kind, bar $measure: $detail';
}

/// MusicXML states several facts twice: once for the ear and once for the
/// eye. The app reads one copy, the engraver often reads the other, so a file
/// whose copies disagree plays one thing and draws another, and the measure
/// editor (which shows what the app read) can't show the difference.
///
/// | Fact | The app reads | The engraver reads | [repair] makes the other follow |
/// |---|---|---|---|
/// | Tuplet | `<time-modification>` | `<tuplet>` start/stop | brackets from timing |
/// | Note length | `<type>` + `<dot>` | `<duration>` too | `<duration>` from the type |
/// | Tie | `<tie>` or `<tied>` | `<tied>` | both halves on every tied note |
/// | Slur, wedge | start/stop pairs | the pair | an unpaired end is dropped |
/// | Tempo | the printed `<metronome>` | the printed mark | `<sound tempo>` from the mark |
///
/// A note shorter than a 16th is also [check]ed: the app has no such value
/// and reads it as a quarter, so it plays wrong whatever the file says.
///
/// Accidentals, the first of these the app met, are settled by
/// `MusicXmlNormalizer` (`<alter>` and `<accidental>`). Measure numbers are
/// only [check]ed: the editor finds a bar by its `number`, so two bars sharing
/// one would be edited as one, and which number is meant can't be guessed.
///
/// Every repair is gated on a disagreement, so a consistent file comes back
/// unchanged, character for character. Run with the other repairs in
/// `PieceRepository.repair`, wherever MusicXML enters or leaves the app.
class MusicXmlConsistency {
  /// [musicXml] with every repairable disagreement settled in favour of the
  /// copy the app reads (see the table above).
  static String repair(String musicXml) {
    final doc = XmlDocument.parse(musicXml);
    var changed = MeasureXmlEditor.rebracketTuplets(doc);
    changed |= _durations(doc, null);
    changed |= _ties(doc, null);
    changed |= _unpaired(doc, null);
    changed |= _tempo(doc, null);
    return changed ? doc.toXmlString() : musicXml;
  }

  /// Every disagreement in [musicXml], including the ones [repair] can't
  /// settle (a duration in a bar with several voices, a length the file's
  /// divisions can't state, a measure number used twice). Empty for a
  /// consistent file. Doesn't change [musicXml].
  static List<Inconsistency> check(String musicXml) {
    final found = <Inconsistency>[];
    void report(String kind, XmlElement inMeasure, String detail) => found.add(
        Inconsistency(kind, _measureOf(inMeasure)?.getAttribute('number') ?? '?',
            detail));

    final doc = XmlDocument.parse(musicXml);
    // Tuplets: what the rebuild would change, bar by bar.
    final rebuilt = doc.copy();
    if (MeasureXmlEditor.rebracketTuplets(rebuilt)) {
      final before = doc.findAllElements('measure').toList();
      final after = rebuilt.findAllElements('measure').toList();
      for (var i = 0; i < before.length && i < after.length; i++) {
        if (_tupletMarks(before[i]) != _tupletMarks(after[i])) {
          report('tuplet', before[i],
              'brackets ${_tupletMarks(before[i])} but timing says '
              '${_tupletMarks(after[i])}');
        }
      }
    }
    final copy = doc.copy();
    _durations(copy, report);
    _ties(copy, report);
    _unpaired(copy, report);
    _tempo(copy, report);
    for (final part in doc.findAllElements('part')) {
      final seen = <String>{};
      for (final m in part.findElements('measure')) {
        final n = m.getAttribute('number') ?? '';
        if (!seen.add(n)) report('measure-number', m, 'number used twice');
      }
    }
    return found;
  }

  static XmlElement? _measureOf(XmlElement e) {
    XmlElement? at = e;
    while (at != null && at.name.local != 'measure') {
      at = at.parentElement;
    }
    return at;
  }

  /// A bar's tuplet marks, note by note: s(tart), e(nd), - (none).
  static String _tupletMarks(XmlElement measure) => [
        for (final n in measure.findElements('note'))
          switch (n
              .findAllElements('tuplet')
              .map((t) => t.getAttribute('type') == 'start' ? 's' : 'e')
              .join()) {
            '' => '-',
            final marks => marks,
          },
      ].join(' ');

  // ---- note length -------------------------------------------------------

  /// The note types `NoteValue` has.
  static const _modelled = {'whole', 'half', 'quarter', 'eighth', '16th'};

  /// A note type's length in 64th notes.
  static const _sixtyFourths = {
    'whole': 64,
    'half': 32,
    'quarter': 16,
    'eighth': 8,
    '16th': 4,
    '32nd': 2,
    '64th': 1,
  };

  /// `<duration>` from `<type>`, `<dot>` and `<time-modification>`, which is
  /// how the parser times a note. Skips grace notes (no duration), whole-bar
  /// rests (they last the bar whatever their type) and notes with no type. A
  /// bar with `<backup>` or `<forward>` is only reported: its voices are
  /// lined up by those durations, and changing one note's would misalign them.
  static bool _durations(
      XmlDocument doc, void Function(String, XmlElement, String)? report) {
    var changed = false;
    for (final part in doc.findAllElements('part')) {
      var divisions = 1;
      for (final measure in part.findElements('measure')) {
        for (final d in measure.findAllElements('divisions')) {
          divisions = int.tryParse(d.innerText.trim()) ?? divisions;
        }
        final voiced = measure.findElements('backup').isNotEmpty ||
            measure.findElements('forward').isNotEmpty;
        for (final note in measure.findElements('note')) {
          if (note.findElements('grace').isNotEmpty) continue;
          if (note.findElements('rest').any((r) => r.getAttribute('measure') == 'yes')) {
            continue;
          }
          final type = note.findElements('type').firstOrNull?.innerText.trim();
          // The app's note values stop at a 16th (`NoteValue`); the parser
          // reads anything else as a quarter, so the staff and the playback
          // part ways. Only reported: there is nothing to make agree.
          if (type != null && !_modelled.contains(type)) {
            report?.call('note-value', note,
                'a $type, which the app reads as a quarter');
          }
          final base = _sixtyFourths[type];
          if (base == null) continue;
          // 64ths times 4 so a dot on a 64th stays whole; a quarter is 64.
          var units = base * 4;
          var add = units;
          for (final _ in note.findElements('dot')) {
            add ~/= 2;
            units += add;
          }
          var top = units * divisions, bottom = 64;
          final tm = note.findElements('time-modification').firstOrNull;
          if (tm != null) {
            final actual = int.tryParse(
                tm.findElements('actual-notes').firstOrNull?.innerText.trim() ?? '');
            final normal = int.tryParse(
                tm.findElements('normal-notes').firstOrNull?.innerText.trim() ?? '');
            if (actual == null || normal == null || actual == 0) continue;
            top *= normal;
            bottom *= actual;
          }
          final durEl = note.findElements('duration').firstOrNull;
          final stated = int.tryParse(durEl?.innerText.trim() ?? '');
          if (top % bottom != 0) {
            report?.call('duration', note,
                'a $type can\'t be stated in $divisions divisions a quarter');
            continue;
          }
          final want = top ~/ bottom;
          if (stated == want) continue;
          report?.call('duration', note,
              '<duration> $stated but a ${'dotted ' * note.findElements('dot').length}'
              '$type${tm == null ? '' : ' in a tuplet'} is $want'
              '${voiced ? ' (several voices: not repaired)' : ''}');
          if (voiced || durEl == null) continue;
          durEl.innerText = '$want';
          changed = true;
        }
      }
    }
    return changed;
  }

  // ---- ties ----------------------------------------------------------------

  /// Every tied note carries both halves: `<tie>` (heard) and `<tied>` (drawn),
  /// the union of what it has. The parser already reads either; the engraver
  /// draws only `<tied>`, so a `<tie>` alone plays tied and shows no arc.
  static bool _ties(
      XmlDocument doc, void Function(String, XmlElement, String)? report) {
    var changed = false;
    for (final note in doc.findAllElements('note')) {
      Set<String> typesOf(Iterable<XmlElement> els) => {
            for (final e in els)
              if (e.getAttribute('type') case final t? when t == 'start' || t == 'stop') t,
          };
      final tie = typesOf(note.findElements('tie'));
      final tied = typesOf(note
          .findElements('notations')
          .expand((n) => n.findElements('tied')));
      if (tie.length == tied.length && tie.containsAll(tied)) continue;
      final dur = note.findElements('duration').firstOrNull;
      for (final t in const ['stop', 'start']) {
        if (tied.contains(t) && !tie.contains(t) && dur != null) {
          report?.call('tie', note, 'arc ($t) drawn but no tie heard');
          final after = note.findElements('tie').lastOrNull ?? dur;
          after.parent!.children.insert(after.parent!.children.indexOf(after) + 1,
              XmlElement(XmlName.parts('tie'), [XmlAttribute(XmlName.parts('type'), t)]));
          changed = true;
        }
        if (tie.contains(t) && !tied.contains(t)) {
          report?.call('tie', note, 'tie ($t) heard but no arc drawn');
          _notationsOf(note).children.add(XmlElement(
              XmlName.parts('tied'), [XmlAttribute(XmlName.parts('type'), t)]));
          changed = true;
        }
      }
    }
    return changed;
  }

  // ---- unpaired marks ------------------------------------------------------

  /// Drops a slur or wedge end with no partner: the engraver draws nothing
  /// for it, and an editor that pairs marks would pair it with the wrong one.
  static bool _unpaired(
      XmlDocument doc, void Function(String, XmlElement, String)? report) {
    var changed = false;
    for (final part in doc.findAllElements('part')) {
      for (final slur in MeasureXmlEditor.unpairedSlurs(part)) {
        report?.call('slur', slur,
            'slur ${slur.getAttribute('type')} with no partner');
        _removeEmptying(slur, const {'notations'});
        changed = true;
      }
      final open = <String, XmlElement>{};
      final orphans = <XmlElement>[];
      for (final w in part.findAllElements('wedge')) {
        final key = w.getAttribute('number') ?? '1';
        switch (w.getAttribute('type')) {
          case 'crescendo' || 'diminuendo':
            if (open[key] case final prev?) orphans.add(prev);
            open[key] = w;
          case 'stop':
            if (open.remove(key) == null) orphans.add(w);
        }
      }
      orphans.addAll(open.values);
      for (final w in orphans) {
        report?.call('wedge', w, 'wedge ${w.getAttribute('type')} with no partner');
        _removeEmptying(w, const {'direction-type', 'direction'});
        changed = true;
      }
    }
    return changed;
  }

  /// Removes [el], then each ancestor named in [chain] that it left empty.
  static void _removeEmptying(XmlElement el, Set<String> chain) {
    var parent = el.parentElement;
    el.remove();
    while (parent != null &&
        chain.contains(parent.name.local) &&
        parent.childElements
            .every((c) => c.name.local == 'sound' || c.name.local == 'offset')) {
      // A direction left with only its <sound>/<offset> has nothing to draw;
      // keep it if the sound still carries something.
      if (parent.findElements('sound').any((s) => s.attributes.isNotEmpty)) break;
      final up = parent.parentElement;
      parent.remove();
      parent = up;
    }
  }

  // ---- tempo ---------------------------------------------------------------

  /// A printed tempo mark wins: each `<sound tempo>` in a bar that prints a
  /// `<metronome>` is set to it. A recording's own tempo still overrides both
  /// at playback; this only settles which marking the score means.
  static bool _tempo(
      XmlDocument doc, void Function(String, XmlElement, String)? report) {
    var changed = false;
    for (final measure in doc.findAllElements('measure')) {
      final marks = measure
          .findAllElements('metronome')
          .map(MusicXmlParser.metronomeQuarters)
          .whereType<double>()
          .toSet();
      // Two different printed marks in one bar: which sound goes with which
      // can't be told apart, so only a sound in the mark's own direction.
      for (final sound in measure.findAllElements('sound')) {
        final stated = double.tryParse(sound.getAttribute('tempo') ?? '');
        if (stated == null) continue;
        final own = sound.parentElement?.findAllElements('metronome')
            .map(MusicXmlParser.metronomeQuarters)
            .whereType<double>()
            .firstOrNull;
        final printed = own ?? (marks.length == 1 ? marks.first : null);
        if (printed == null || (printed - stated).abs() < 0.01) continue;
        final text = printed == printed.roundToDouble()
            ? '${printed.round()}'
            : '$printed';
        report?.call('tempo', sound, 'plays $stated but the printed mark is $text');
        sound.setAttribute('tempo', text);
        changed = true;
      }
    }
    return changed;
  }

  /// [note]'s `<notations>`, made before any `<lyric>`, `<play>` or `<listen>`
  /// when it has none (MusicXML's order).
  static XmlElement _notationsOf(XmlElement note) {
    final existing = note.findElements('notations').firstOrNull;
    if (existing != null) return existing;
    final el = XmlElement(XmlName.parts('notations'));
    final at = note.children.indexWhere((c) =>
        c is XmlElement &&
        const {'lyric', 'play', 'listen'}.contains(c.name.local));
    if (at == -1) {
      note.children.add(el);
    } else {
      note.children.insert(at, el);
    }
    return el;
  }
}
