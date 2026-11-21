import 'package:meta/meta.dart';
import 'package:xml/xml.dart';

import '../models/key_signature.dart';
import '../models/note_event.dart';

/// Serializes edited notes back into a piece's MusicXML, one measure at a time.
///
/// Sibling to `fingering_xml_injector.dart` (same parse/mutate/`toXmlString`
/// approach), but it rewrites a measure's note list rather than annotating
/// existing notes, so it's a separate class. Single-voice only — `<backup>`/
/// `<forward>` are out of scope (see `docs/plan.md` §2). Chords aren't editable
/// as such, but a chord member's `<chord/>` marker round-trips so saving an
/// edit doesn't silently break the stack into sequential notes.
///
/// **A rewritten measure keeps only what [NoteEvent] holds.** Pitch, duration,
/// dot, drawn accidental, fingering, bowing, ties and lyrics
/// ([NoteEvent.lyrics]) are modelled; slurs, articulations, ornaments and
/// fermatas ride along opaquely in [NoteEvent.carriedNotations], so they stay
/// on their note through an edit; grace notes are carried across as opaque
/// elements (see [replaceMeasureNotes]). **`<stem>` does not survive.** Beams
/// aren't carried either, because a beam belongs to a *group* that an edit can
/// invalidate, so [MusicXmlBeamer] recomputes them afterwards instead. A slur
/// whose other end was deleted is removed ([dropOrphanSlurs]).
class MeasureXmlEditor {
  /// Builds a detached `<note>` element for [note]. `<duration>` is derived
  /// from the note value, dot, and the score's [divisions] (divisions per
  /// quarter note); a quarter note is 8 thirty-second units, so
  /// `duration = units * divisions / 8`.
  ///
  /// A tuplet note carries its `<time-modification>`, and [tupletStart] /
  /// [tupletStop] draw the bracket over its group (see [tupletGroups]).
  static XmlElement buildNoteElement(NoteEvent note, int divisions,
          {bool tupletStart = false, bool tupletStop = false}) =>
      XmlDocument.parse(_noteXml(note, divisions,
              tupletStart: tupletStart, tupletStop: tupletStop))
          .rootElement
          .copy();

  /// The smallest multiple of [divisions] at which every one of [notes] has a
  /// whole-number `<duration>`: a triplet eighth needs divisions divisible by
  /// 3. [divisions] itself when it already serves.
  static int divisionsFor(Iterable<NoteEvent> notes, int divisions) {
    for (var k = 1; k <= 12; k++) {
      final d = divisions * k;
      final fits = notes.every((n) {
        final dur = n.units * d / 8;
        return (dur - dur.round()).abs() < 1e-9;
      });
      if (fits) return d;
    }
    return divisions;
  }

  /// The `<divisions>` in force at [measure]: the last one stated in its part
  /// up to and including it. Null when none is.
  static int? _divisionsAt(XmlElement measure) {
    final part = measure.parentElement;
    if (part == null) return null;
    int? divisions;
    for (final m in part.findElements('measure')) {
      for (final a in m.findElements('attributes')) {
        final d = int.tryParse(
            a.findElements('divisions').firstOrNull?.innerText.trim() ?? '');
        if (d != null) divisions = d;
      }
      if (identical(m, measure)) break;
    }
    return divisions;
  }

  /// Multiplies every `<divisions>` and `<duration>` in [doc] by [factor]:
  /// the same music, counted finer, so a tuplet can be written exactly.
  static void _scaleDivisions(XmlDocument doc, int factor) {
    for (final tag in const ['divisions', 'duration']) {
      for (final el in doc.findAllElements(tag)) {
        final v = int.tryParse(el.innerText.trim());
        if (v != null) el.innerText = '${v * factor}';
      }
    }
  }

  /// Replaces the visible notes of `<measure number="$measureNumber">` with
  /// [notes], leaving `<attributes>`/`<print>`/`<barline>` and any hidden
  /// pickup rests (`print-object="no"`) in place. Returns the re-serialized
  /// MusicXML string.
  ///
  /// Grace notes are carried across rather than rebuilt. They aren't in the
  /// model — [MusicXmlParser] skips them, so they never reach [notes] — but
  /// they are somebody's ornament, and a bar of Gossec's Gavotte has five of
  /// them. Each is held against the timed note it precedes (the same way the
  /// parser holds a `<harmony>` until a note consumes it) and put back in front
  /// of whatever note ends up at that position. A group whose note is gone goes
  /// with it: the ornament belonged to that note, and re-hanging it on the next
  /// one would invent an ornament nobody wrote.
  static String replaceMeasureNotes(
      String musicXml, int measureNumber, List<NoteEvent> notes, int divisions) {
    final doc = XmlDocument.parse(musicXml);

    final measureEl = doc.findAllElements('measure').firstWhere(
          (m) => m.getAttribute('number') == '$measureNumber',
          orElse: () =>
              throw ArgumentError('Measure $measureNumber not found in MusicXML'),
        );
    // The divisions in force at this bar, as the DOCUMENT states them. The
    // caller's figure comes from a parse that may have been of a draft, already
    // counted finer than this file is.
    divisions = _divisionsAt(measureEl) ?? divisions;
    // A triplet in a score counted in quarters or eighths has no whole-number
    // duration: count the whole score finer first.
    final needed = divisionsFor(notes, divisions);
    if (needed != divisions) {
      _scaleDivisions(doc, needed ~/ divisions);
      divisions = needed;
    }

    final part = measureEl.parentElement;
    final orphansBefore =
        part == null ? const <XmlElement>{} : _orphanSlurs(part);

    final children = measureEl.children;
    bool isNote(XmlNode n) => n is XmlElement && n.name.local == 'note';
    bool isGrace(XmlNode n) =>
        isNote(n) && (n as XmlElement).findElements('grace').isNotEmpty;
    // The notes [notes] stands in for: everything timed and visible.
    bool isReplaceable(XmlNode n) =>
        isNote(n) &&
        !isGrace(n) &&
        (n as XmlElement).getAttribute('print-object') != 'no';

    // Grace groups, keyed by the position of the timed note they ornament.
    final graceBefore = <int, List<XmlElement>>{};
    var position = 0;
    var pending = <XmlElement>[];
    for (final child in children) {
      if (isGrace(child)) {
        pending.add(child as XmlElement);
      } else if (isReplaceable(child)) {
        if (pending.isNotEmpty) {
          graceBefore[position] = pending;
          pending = <XmlElement>[];
        }
        position++;
      }
    }

    // Both kinds go; the grace notes come back below, at their anchors.
    bool isRemovable(XmlNode n) => isGrace(n) || isReplaceable(n);
    final firstRemovable = children.indexWhere(isRemovable);
    final int insertIndex;
    if (firstRemovable != -1) {
      // Everything removed sits at or after this index, so it survives removal
      // as the slot the rebuilt notes belong in.
      insertIndex = firstRemovable;
      children.removeWhere(isRemovable);
    } else {
      // Nothing to replace: insert after the last existing <note> (e.g. hidden
      // pickup rests), else at the end of the measure.
      final lastNoteIdx = children.lastIndexWhere(isNote);
      insertIndex = lastNoteIdx == -1 ? children.length : lastNoteIdx + 1;
    }

    final groups = tupletGroups(notes);
    final starts = {for (final g in groups) g.$1};
    // The bracket closes on the group's last primary note, not a chord member.
    final stops = {
      for (final g in groups) notes.lastIndexWhere((n) => !n.isChord, g.$2 - 1),
    };
    children.insertAll(insertIndex, [
      for (var i = 0; i < notes.length; i++) ...[
        ...?graceBefore[i]?.map((g) => g.copy()),
        buildNoteElement(notes[i], divisions,
            tupletStart: starts.contains(i), tupletStop: stops.contains(i)),
      ],
    ]);
    if (part != null) dropOrphanSlurs(part, keep: orphansBefore);
    return doc.toXmlString();
  }

  /// Redraws every tuplet bracket in [musicXml] from the notes' timing, the
  /// way Save writes them ([replaceMeasureNotes]): a bracket starts on the
  /// first note of each [tupletGroups]-style group and stops on its last
  /// primary note. Returns [musicXml] itself when every bracket already
  /// agrees.
  ///
  /// MusicXML says a tuplet twice: `<time-modification>` on each note is the
  /// timing, which the parser, playback and the measure editor read, and
  /// `<tuplet type="start|stop">` is the bracket, which only the engraver
  /// reads. A scan can get the second wrong while the first is right: Minuet 2's
  /// triplet bars had the stop on the quarter after the three eighths, so the
  /// staff bracketed four notes while the editor showed three. The staff is
  /// drawn from the timing instead, so it can't disagree with the editor.
  ///
  /// A group's existing start keeps its attributes (`bracket`, `show-number`,
  /// `placement`), except that one stating no `bracket` gets bracket="yes",
  /// as Save writes it; a new one is written as Save writes it. Grace notes and chord members never carry the marks.
  /// Nested tuplets (a `number` other than 1) are left alone, as are
  /// multi-voice bars, a voice at a time.
  static String rebuildTupletBrackets(String musicXml) {
    final doc = XmlDocument.parse(musicXml);
    return rebracketTuplets(doc) ? doc.toXmlString() : musicXml;
  }

  /// [rebuildTupletBrackets] on a parsed [doc], in place. True when it changed
  /// anything.
  static bool rebracketTuplets(XmlDocument doc) {
    var changed = false;
    for (final measure in doc.findAllElements('measure')) {
      final notes = measure.findElements('note').toList();
      if (!notes.any((n) =>
          n.findElements('time-modification').isNotEmpty ||
          n.findAllElements('tuplet').isNotEmpty)) {
        continue;
      }
      if (measure.findAllElements('tuplet').any((t) =>
          (t.getAttribute('number') ?? '1') != '1')) {
        continue;
      }
      final voices = <String, List<XmlElement>>{};
      for (final n in notes) {
        if (n.findElements('grace').isNotEmpty) {
          changed |= _dropTupletMarks(n);
          continue;
        }
        final v = n.findElements('voice').firstOrNull?.innerText.trim() ?? '1';
        (voices[v] ??= []).add(n);
      }
      for (final voice in voices.values) {
        changed |= _rebracketVoice(voice);
      }
    }
    return changed;
  }

  /// One voice of one bar, in order: see [rebuildTupletBrackets].
  static bool _rebracketVoice(List<XmlElement> notes) {
    bool isChord(XmlElement n) => n.findElements('chord').isNotEmpty;
    String? ratio(XmlElement n) {
      final tm = n.findElements('time-modification').firstOrNull;
      if (tm == null) return null;
      return '${tm.findElements('actual-notes').firstOrNull?.innerText.trim()}'
          ':${tm.findElements('normal-notes').firstOrNull?.innerText.trim()}';
    }

    // The groups, as [tupletGroups] closes them: a run of one ratio, ended
    // once it has filled `actual` of its shortest value.
    final groups = <(int, int)>[];
    int? start;
    var nominal = 0.0;
    var shortest = 0.0;
    var last = -1;
    void close() {
      groups.add((start!, last));
      start = null;
      nominal = 0;
      shortest = 0;
    }

    for (var i = 0; i < notes.length; i++) {
      final n = notes[i];
      if (isChord(n) && i > 0) continue;
      final r = ratio(n);
      if (start != null && r != ratio(notes[start!])) close();
      if (r == null) continue;
      start ??= i;
      last = i;
      final u = _nominalUnits(n);
      nominal += u;
      if (shortest == 0 || u < shortest) shortest = u;
      final actual = int.tryParse(r.split(':').first) ?? 0;
      if (nominal >= actual * shortest - 1e-9) close();
    }
    if (start != null) close();

    final wantStart = {for (final g in groups) g.$1};
    final wantStop = {for (final g in groups) g.$2};
    bool has(XmlElement n, String type) => n
        .findElements('notations')
        .expand((x) => x.findElements('tuplet'))
        .any((t) => t.getAttribute('type') == type);
    var agrees = true;
    for (var i = 0; i < notes.length && agrees; i++) {
      agrees = has(notes[i], 'start') == wantStart.contains(i) &&
          has(notes[i], 'stop') == wantStop.contains(i);
    }
    // A start that states no `bracket` is drawn without one when its group
    // sits under one beam (Verovio's default), as Minuet 2's scanned triplets
    // did once their stops were right. Save always writes one, so the staff
    // does too; an explicit bracket="no" is left alone.
    if (agrees &&
        !notes.any((n) => n
            .findElements('notations')
            .expand((x) => x.findElements('tuplet'))
            .any((t) =>
                t.getAttribute('type') == 'start' &&
                t.getAttribute('bracket') == null))) {
      return false;
    }

    // Each group's start keeps the attributes of the start nearest it.
    final oldStarts = <int, XmlElement>{};
    for (var i = 0; i < notes.length; i++) {
      for (final t in notes[i]
          .findElements('notations')
          .expand((x) => x.findElements('tuplet'))) {
        if (t.getAttribute('type') == 'start') oldStarts[i] = t.copy();
      }
    }
    for (final n in notes) {
      _dropTupletMarks(n);
    }
    for (final (s, e) in groups) {
      final near = oldStarts.entries
          .where((o) => o.key >= s && o.key <= e)
          .map((o) => o.value)
          .firstOrNull;
      if (near != null && near.getAttribute('bracket') == null) {
        near.setAttribute('bracket', 'yes');
      }
      final startEl = near ??
          XmlElement(XmlName.parts('tuplet'),
              [XmlAttribute(XmlName.parts('type'), 'start'), XmlAttribute(XmlName.parts('bracket'), 'yes')]);
      _notationsOf(notes[s]).children.insert(0, startEl);
      _notationsOf(notes[e]).children.insert(
          s == e ? 1 : 0,
          XmlElement(XmlName.parts('tuplet'), [XmlAttribute(XmlName.parts('type'), 'stop')]));
    }
    return true;
  }

  /// A note's written length in 32nd-note units, dots included, before any
  /// tuplet: what [tupletGroups] counts as nominal.
  static double _nominalUnits(XmlElement note) {
    final type = note.findElements('type').firstOrNull?.innerText.trim();
    var u = switch (type) {
      'whole' => 32.0,
      'half' => 16.0,
      'quarter' => 8.0,
      'eighth' => 4.0,
      '16th' => 2.0,
      '32nd' => 1.0,
      '64th' => 0.5,
      _ => 8.0,
    };
    var add = u;
    for (final _ in note.findElements('dot')) {
      add /= 2;
      u += add;
    }
    return u;
  }

  /// Removes [note]'s `<tuplet>` marks, and its `<notations>` if that empties
  /// it. True when there were any.
  static bool _dropTupletMarks(XmlElement note) {
    var any = false;
    for (final notations in note.findElements('notations').toList()) {
      for (final t in notations.findElements('tuplet').toList()) {
        t.remove();
        any = true;
      }
      if (any && notations.childElements.isEmpty) notations.remove();
    }
    return any;
  }

  /// [note]'s `<notations>`, made where MusicXML's order puts it (before any
  /// `<lyric>`, `<play>` or `<listen>`) when it has none.
  static XmlElement _notationsOf(XmlElement note) {
    final existing = note.findElements('notations').firstOrNull;
    if (existing != null) return existing;
    final el = XmlElement(XmlName.parts('notations'));
    final after = note.children.indexWhere((c) =>
        c is XmlElement &&
        const {'lyric', 'play', 'listen'}.contains(c.name.local));
    if (after == -1) {
      note.children.add(el);
    } else {
      note.children.insert(after, el);
    }
    return el;
  }

  /// Removes every slur end in [part] that the edit left without its other
  /// end — a slur from a note that was deleted, or to one — except those in
  /// [keep]: a slur that was already broken before the edit is somebody
  /// else's, and is left as it was. A `<notations>` emptied by it goes too.
  ///
  /// Slurs pair by voice and `number`, in document order, as MusicXML pairs
  /// them; a slur may cross barlines, so the whole part is walked.
  @visibleForTesting
  static void dropOrphanSlurs(XmlElement part,
      {Set<XmlElement> keep = const {}}) {
    for (final slur in _orphanSlurs(part)) {
      if (keep.contains(slur)) continue;
      final notations = slur.parentElement;
      slur.remove();
      if (notations != null && notations.childElements.isEmpty) {
        notations.remove();
      }
    }
  }

  /// The slur ends in [part] with no partner, in the order MusicXML pairs
  /// them — see [dropOrphanSlurs].
  static Set<XmlElement> unpairedSlurs(XmlElement part) => _orphanSlurs(part);

  static Set<XmlElement> _orphanSlurs(XmlElement part) {
    final orphans = <XmlElement>{};
    final open = <String, XmlElement>{};
    for (final note in part.findAllElements('note')) {
      final voice =
          note.findElements('voice').firstOrNull?.innerText.trim() ?? '1';
      final slurs = [
        for (final n in note.findElements('notations'))
          ...n.findElements('slur'),
      ];
      String key(XmlElement s) => '$voice/${s.getAttribute('number') ?? '1'}';
      // Stops first, so a note that ends one slur and begins the next (a
      // chain) closes the old one before opening the new.
      for (final s in slurs.where((s) => s.getAttribute('type') == 'stop')) {
        if (open.remove(key(s)) == null) orphans.add(s);
      }
      for (final s in slurs.where((s) => s.getAttribute('type') == 'start')) {
        final previous = open[key(s)];
        if (previous != null) orphans.add(previous);
        open[key(s)] = s;
      }
    }
    return orphans..addAll(open.values);
  }

  /// Sets the repeat barlines on `<measure number="$measureNumber">` to match
  /// [start] (forward repeat, left edge `|:`) and [end] (backward repeat, right
  /// edge `:|`, drawn as the doubled `light-heavy` barline). Existing forward/
  /// backward repeat barlines are removed first; non-repeat barlines (e.g. a
  /// plain final double bar) are left untouched. Idempotent. Returns the
  /// re-serialized MusicXML string.
  static String setMeasureRepeats(String musicXml, int measureNumber,
      {required bool start, required bool end}) {
    final doc = XmlDocument.parse(musicXml);
    final measureEl = doc.findAllElements('measure').firstWhere(
          (m) => m.getAttribute('number') == '$measureNumber',
          orElse: () =>
              throw ArgumentError('Measure $measureNumber not found in MusicXML'),
        );

    // Drop the forward/backward repeat barlines we manage; leave any non-repeat
    // barlines in place. A volta bracket shares the repeat's barline, so its
    // `<ending>` is kept and put back.
    final kept = <(bool, XmlElement)>[];
    for (final n in measureEl.children.toList()) {
      if (_isRepeatBarline(n, 'forward') || _isRepeatBarline(n, 'backward')) {
        final b = n as XmlElement;
        final left = (b.getAttribute('location') ?? 'right') == 'left';
        for (final e in b.findElements('ending')) {
          kept.add((left, e.copy()));
        }
        b.remove();
      }
    }

    if (start) _addRepeat(measureEl, forward: true);
    if (end) _addRepeat(measureEl, forward: false);
    for (final (left, e) in kept) {
      _addEnding(measureEl, e.getAttribute('number') ?? '1',
          e.getAttribute('type') ?? 'start',
          left: left);
    }
    return doc.toXmlString();
  }

  /// Puts `<measure number="$measureNumber">` under the volta bracket(s)
  /// [endings] (`{1}` a first ending, `{2}` a second, empty for none).
  ///
  /// A bracket spans bars, so this rewrites every `<ending>` in the part:
  /// each run of adjacent bars under the same numbers becomes one bracket,
  /// `start` on its first bar's left barline and a closing mark on its last
  /// bar's right one — `stop` (a closed hook) unless it is the last bracket of
  /// its group with no `:|`, which stays open (`discontinue`), as printed
  /// second endings are. Marking bar 8 as ending 1 and bar 9 as ending 2 is
  /// all a score needs. Idempotent. Throws [ArgumentError] when no measure
  /// has that number.
  static String setMeasureEndings(
      String musicXml, int measureNumber, Set<int> endings) {
    final doc = XmlDocument.parse(musicXml);
    final target = doc.findAllElements('measure').firstWhere(
          (m) => m.getAttribute('number') == '$measureNumber',
          orElse: () =>
              throw ArgumentError('Measure $measureNumber not found in MusicXML'),
        );
    final part = target.parentElement!;
    final measures = part.findElements('measure').toList();

    // Read every bar's brackets as the parser does, then clear them.
    final sets = <Set<int>>[];
    Set<int>? open;
    for (final m in measures) {
      Set<int>? here;
      var closes = false;
      for (final b in m.findElements('barline')) {
        for (final e in b.findElements('ending')) {
          final type = e.getAttribute('type');
          final nums = {
            for (final d in RegExp(r'\d+')
                .allMatches(e.getAttribute('number') ?? ''))
              int.parse(d.group(0)!),
          }..remove(0);
          if (type == 'start') {
            open = nums.isEmpty ? {1} : nums;
            here = open;
          } else {
            here ??= open ?? (nums.isEmpty ? {1} : nums);
            closes = true;
          }
        }
      }
      sets.add(here ?? open ?? const {});
      if (closes) open = null;
    }
    for (final m in measures) {
      for (final b in m.findElements('barline').toList()) {
        b.children.removeWhere(
            (n) => n is XmlElement && n.name.local == 'ending');
        if (b.childElements.isEmpty) b.remove();
      }
    }
    sets[measures.indexOf(target)] = endings;

    bool same(Set<int> a, Set<int> b) =>
        a.length == b.length && a.containsAll(b);
    var i = 0;
    while (i < measures.length) {
      if (sets[i].isEmpty) {
        i++;
        continue;
      }
      var j = i;
      while (j + 1 < measures.length && same(sets[j + 1], sets[i])) {
        j++;
      }
      final number = (sets[i].toList()..sort()).join(', ');
      final lastOfGroup = j + 1 >= measures.length || sets[j + 1].isEmpty;
      final closed = !lastOfGroup || _hasRepeat(measures[j], 'backward');
      _addEnding(measures[i], number, 'start', left: true);
      _addEnding(measures[j], number, closed ? 'stop' : 'discontinue',
          left: false);
      i = j + 1;
    }
    return doc.toXmlString();
  }

  /// Adds `<ending number type>` to [measure]'s left or right barline,
  /// creating the barline if needed, ahead of any `<repeat>` (schema order).
  static void _addEnding(XmlElement measure, String number, String type,
      {required bool left}) {
    final location = left ? 'left' : 'right';
    var barline = measure.findElements('barline').where((b) =>
        (b.getAttribute('location') ?? 'right') == location).firstOrNull;
    if (barline == null) {
      barline = XmlElement(XmlName.parts('barline'), [
        XmlAttribute(XmlName.parts('location'), location),
      ]);
      if (left) {
        final printIdx = measure.children
            .indexWhere((n) => n is XmlElement && n.name.local == 'print');
        measure.children.insert(printIdx == -1 ? 0 : printIdx + 1, barline);
      } else {
        measure.children.add(barline);
      }
    }
    final ending = XmlElement(XmlName.parts('ending'), [
      XmlAttribute(XmlName.parts('number'), number),
      XmlAttribute(XmlName.parts('type'), type),
    ]);
    final repeatIdx = barline.children
        .indexWhere((n) => n is XmlElement && n.name.local == 'repeat');
    if (repeatIdx == -1) {
      barline.children.add(ending);
    } else {
      barline.children.insert(repeatIdx, ending);
    }
  }

  /// Makes [measureNumber] start a new meter: its `<time>` becomes
  /// [beats]/[beatType] (rewritten if it has one, inserted if not), and the
  /// bars after it follow until the next `<time>`.
  ///
  /// It relabels; no note value changes. That is for a score whose bars are
  /// right and whose `<time>` is wrong: The Wellerman imported with four
  /// quarters in every bar under a `2/4` signature, so every bar read as
  /// double-length and the measure editor flagged the lot. Changing the label
  /// to `2/2` makes the file self-consistent without moving a note.
  /// Re-notating a tune into a different meter (halving or doubling every
  /// duration) is a different operation and deliberately not this one.
  ///
  /// This is how the measure editor's time-signature card writes: a change at
  /// any bar, so a piece can move between 3/4 and 4/4. Setting the first bar
  /// sets the piece's opening meter. Throws [ArgumentError] when no measure
  /// has that number.
  static String setTimeChange(String musicXml, int measureNumber,
      {required int beats, required int beatType}) {
    if (beats < 1 || beatType < 1) {
      throw ArgumentError('Time signature $beats/$beatType is not a meter');
    }
    final doc = XmlDocument.parse(musicXml);
    var found = false;
    for (final part in doc.findAllElements('part')) {
      final measure = part
          .findElements('measure')
          .where((m) => m.getAttribute('number') == '$measureNumber')
          .firstOrNull;
      if (measure == null) continue;
      found = true;
      _pinOpeningMeter(part);
      final existing = measure
          .findElements('attributes')
          .expand((a) => a.findElements('time'))
          .firstOrNull;
      if (existing != null) {
        _setChildText(existing, 'beats', '$beats');
        _setChildText(existing, 'beat-type', '$beatType');
        continue;
      }
      _insertTime(_attributesFor(measure), beats, beatType);
    }
    if (!found) throw ArgumentError('No measure $measureNumber');
    doc.findAllElements('part').forEach(fitBarRests);
    return doc.toXmlString();
  }

  /// Removes the meter change at [measureNumber], so the bar carries on in the
  /// meter before it. The first measure keeps its `<time>`: the piece needs an
  /// opening meter, which [setTimeChange] edits instead. Unchanged when the bar
  /// states no `<time>`.
  static String removeTimeChange(String musicXml, int measureNumber) {
    final doc = XmlDocument.parse(musicXml);
    var changed = false;
    for (final part in doc.findAllElements('part')) {
      final measures = part.findElements('measure').toList();
      final i = measures
          .indexWhere((m) => m.getAttribute('number') == '$measureNumber');
      if (i <= 0) continue;
      _pinOpeningMeter(part);
      for (final attributes
          in measures[i].findElements('attributes').toList()) {
        final times = attributes.findElements('time').toList();
        if (times.isEmpty) continue;
        for (final t in times) {
          t.remove();
        }
        changed = true;
        // An `<attributes>` that held only the time would be an empty block.
        if (attributes.childElements.isEmpty) attributes.remove();
      }
    }
    if (!changed) return musicXml;
    doc.findAllElements('part').forEach(fitBarRests);
    return doc.toXmlString();
  }

  /// Writes the meter [part] opens in into its first measure, if that has no
  /// `<time>` of its own.
  ///
  /// A score may state its first meter only later — a scan cropped below its
  /// opening system had just one `<time>`, at bar 19 — and MusicXmlParser then
  /// reads that one as the opening meter too. Changing or removing it would
  /// silently re-meter every bar before it, so before touching any later bar
  /// the opening is pinned where it belongs.
  static void _pinOpeningMeter(XmlElement part) {
    final first = part.findElements('measure').firstOrNull;
    if (first == null) return;
    final hasOwn = first
        .findElements('attributes')
        .any((a) => a.findElements('time').isNotEmpty);
    if (hasOwn) return;
    final opening = part.findAllElements('time').firstOrNull;
    int? read(String tag) => int.tryParse(
        opening?.findElements(tag).firstOrNull?.innerText.trim() ?? '');
    final beats = read('beats'), beatType = read('beat-type');
    if (beats == null || beatType == null) return; // none at all: 4/4
    _insertTime(_attributesFor(first), beats, beatType);
  }

  /// The `<attributes>` in [measure] a `<time>` belongs in: the one already
  /// holding the key or clef (an OMR scan splits divisions from those), else
  /// its first, else a new block placed before the bar's first note.
  static XmlElement _attributesFor(XmlElement measure) {
    final blocks = measure.findElements('attributes').toList();
    final withKeyOrClef = blocks
        .where((a) =>
            a.findElements('key').isNotEmpty ||
            a.findElements('clef').isNotEmpty)
        .firstOrNull;
    if (withKeyOrClef != null) return withKeyOrClef;
    if (blocks.isNotEmpty) return blocks.first;
    final created = XmlElement(XmlName('attributes'));
    final firstMusic = measure.children.indexWhere((n) =>
        n is XmlElement &&
        const {'note', 'backup', 'forward'}.contains(n.name.local));
    measure.children.insert(
        firstMusic == -1 ? measure.children.length : firstMusic, created);
    return created;
  }

  /// Inserts a `<time>` into [attributes] where MusicXML's sequence puts it:
  /// after `<divisions>`/`<key>`, before `<staves>`, `<clef>` and the rest.
  static void _insertTime(XmlElement attributes, int beats, int beatType) {
    const after = {
      'staves', 'part-symbol', 'instruments', 'clef', 'staff-details',
      'transpose', 'directive', 'measure-style',
    };
    final time = XmlDocument.parse(
            '<time><beats>$beats</beats><beat-type>$beatType</beat-type></time>')
        .rootElement
        .copy();
    final at = attributes.children
        .indexWhere((n) => n is XmlElement && after.contains(n.name.local));
    attributes.children.insert(at == -1 ? attributes.children.length : at, time);
  }

  /// Makes [measureNumber] start the key of [fifths] sharps (+) / flats (−):
  /// its `<key>` is rewritten if it has one, inserted if not. Setting the
  /// first bar sets the piece's opening key.
  ///
  /// Unlike [setTimeChange] this is not just a relabel. MusicXML stores the
  /// sounding pitch, and a scan that misread the key wrote its notes in the
  /// wrong one — so every note that was following the old key, from this bar
  /// to the next `<key>`, is re-spelt into the new one
  /// ([KeySignature.rekeyBar]). Notes with a written accidental keep theirs.
  /// Only `<alter>` is touched, so slurs, articulations and the rest of each
  /// note survive. Throws [ArgumentError] when no measure has that number.
  static String setKeyChange(String musicXml, int measureNumber, int fifths) {
    if (fifths < -7 || fifths > 7) {
      throw ArgumentError('Key of $fifths fifths is not a key signature');
    }
    final doc = XmlDocument.parse(musicXml);
    var found = false;
    for (final part in doc.findAllElements('part')) {
      final measures = part.findElements('measure').toList();
      final i = measures
          .indexWhere((m) => m.getAttribute('number') == '$measureNumber');
      if (i < 0) continue;
      found = true;
      _pinOpeningKey(part);
      final from = _keyAt(measures, i);
      final existing = measures[i]
          .findElements('attributes')
          .expand((a) => a.findElements('key'))
          .firstOrNull;
      if (existing != null) {
        _setChildText(existing, 'fifths', '$fifths');
      } else {
        _insertKey(_attributesFor(measures[i]), fifths);
      }
      _rekeySpan(measures, i, from, fifths);
    }
    if (!found) throw ArgumentError('No measure $measureNumber');
    return doc.toXmlString();
  }

  /// Removes the key change at [measureNumber], so the bar carries on in the
  /// key before it, re-spelling the notes it governed back into that key (see
  /// [setKeyChange]). The first measure keeps its `<key>`: [setKeyChange]
  /// edits the opening key instead. Unchanged when the bar states no `<key>`.
  static String removeKeyChange(String musicXml, int measureNumber) {
    final doc = XmlDocument.parse(musicXml);
    var changed = false;
    for (final part in doc.findAllElements('part')) {
      final measures = part.findElements('measure').toList();
      final i = measures
          .indexWhere((m) => m.getAttribute('number') == '$measureNumber');
      if (i <= 0) continue;
      final hasOwn = measures[i]
          .findElements('attributes')
          .any((a) => a.findElements('key').isNotEmpty);
      if (!hasOwn) continue;
      _pinOpeningKey(part);
      final from = _keyAt(measures, i);
      final to = _keyAt(measures, i - 1);
      for (final attributes
          in measures[i].findElements('attributes').toList()) {
        for (final k in attributes.findElements('key').toList()) {
          k.remove();
        }
        if (attributes.childElements.isEmpty) attributes.remove();
      }
      _rekeySpan(measures, i, from, to);
      changed = true;
    }
    return changed ? doc.toXmlString() : musicXml;
  }

  /// The `<fifths>` [measure] states, or null when it states none.
  static int? _ownKey(XmlElement measure) => int.tryParse(measure
          .findElements('attributes')
          .expand((a) => a.findElements('key'))
          .expand((k) => k.findElements('fifths'))
          .firstOrNull
          ?.innerText
          .trim() ??
      '');

  /// The key in force at [measures]`[i]`, as [MusicXmlParser] reads it: the
  /// last stated up to it, else the part's first, else C.
  static int _keyAt(List<XmlElement> measures, int i) {
    for (var k = i; k >= 0; k--) {
      final f = _ownKey(measures[k]);
      if (f != null) return f;
    }
    for (final m in measures) {
      final f = _ownKey(m);
      if (f != null) return f;
    }
    return 0;
  }

  /// Writes the key [part] opens in into its first measure when that states
  /// none — the parser reads a later bar's `<key>` as the opening key too, so
  /// changing that later one must not silently re-key the bars before it. See
  /// [_pinOpeningMeter].
  static void _pinOpeningKey(XmlElement part) {
    final measures = part.findElements('measure').toList();
    if (measures.isEmpty || _ownKey(measures.first) != null) return;
    for (final m in measures) {
      final f = _ownKey(m);
      if (f == null) continue;
      _insertKey(_attributesFor(measures.first), f);
      return;
    }
  }

  /// Inserts a `<key>` into [attributes] where MusicXML's sequence puts it:
  /// after `<divisions>`, before `<time>` and the rest.
  static void _insertKey(XmlElement attributes, int fifths) {
    const after = {
      'time', 'staves', 'part-symbol', 'instruments', 'clef', 'staff-details',
      'transpose', 'directive', 'measure-style',
    };
    final key = XmlDocument.parse('<key><fifths>$fifths</fifths></key>')
        .rootElement
        .copy();
    final at = attributes.children
        .indexWhere((n) => n is XmlElement && after.contains(n.name.local));
    attributes.children.insert(at == -1 ? attributes.children.length : at, key);
  }

  /// Re-spells, from [from] to [to], the notes of the bars whose key is the
  /// one set at [measures]`[i]`: up to the next bar stating its own `<key>`.
  static void _rekeySpan(List<XmlElement> measures, int i, int from, int to) {
    if (from == to) return;
    KeyCarry? carry;
    // A tie into the first bar continues a note the change doesn't touch.
    if (i > 0) {
      final before = measures[i - 1]
          .findElements('note')
          .map(_keyedNote)
          .whereType<KeyedNote>()
          .lastOrNull;
      if (before != null) {
        carry = (
          step: before.step,
          octave: before.octave,
          oldAlter: before.alter,
          newAlter: before.alter,
        );
      }
    }
    for (var k = i; k < measures.length; k++) {
      if (k > i && _ownKey(measures[k]) != null) break;
      final notes = measures[k].findElements('note').toList();
      final keyed = notes.map(_keyedNote).toList();
      final (alters, last) =
          KeySignature.rekeyBar(keyed, from, to, carryIn: carry);
      carry = last;
      for (var n = 0; n < notes.length; n++) {
        final was = keyed[n], now = alters[n];
        if (was == null || now == null || now == was.alter) continue;
        _setAlter(notes[n].getElement('pitch')!, now);
      }
    }
  }

  /// A `<note>` as [KeySignature.rekeyBar] reads it; null for a rest, an
  /// unpitched note, or a microtonal alter it shouldn't guess about.
  static KeyedNote? _keyedNote(XmlElement note) {
    final pitch = note.getElement('pitch');
    if (pitch == null) return null;
    final step = pitch.getElement('step')?.innerText.trim();
    final octave = int.tryParse(pitch.getElement('octave')?.innerText.trim() ?? '');
    final alterText = pitch.getElement('alter')?.innerText.trim();
    final alterD = alterText == null ? 0.0 : double.tryParse(alterText);
    if (step == null || octave == null || alterD == null) return null;
    if (alterD != alterD.roundToDouble()) return null;
    final written = note.getElement('accidental')?.innerText.trim() ?? '';
    return (
      step: step,
      octave: octave,
      alter: alterD.round(),
      written: written.isNotEmpty,
      tieStop: note
          .findElements('tie')
          .any((t) => t.getAttribute('type') == 'stop'),
    );
  }

  /// Sets [pitch]'s `<alter>` to [alter]: removed for 0, inserted after
  /// `<step>` where the schema puts it.
  static void _setAlter(XmlElement pitch, int alter) {
    final existing = pitch.getElement('alter');
    if (alter == 0) {
      existing?.remove();
    } else if (existing != null) {
      existing.innerText = '$alter';
    } else {
      final step = pitch.getElement('step');
      final el = XmlElement(XmlName.parts('alter'), [], [XmlText('$alter')]);
      final at = step == null ? 0 : pitch.children.indexOf(step) + 1;
      pitch.children.insert(at, el);
    }
  }

  /// Sets [element]'s `<$name>` child to [text], creating it if absent.
  static void _setChildText(XmlElement element, String name, String text) {
    final child = element.findElements(name).firstOrNull;
    if (child == null) {
      element.children.add(XmlElement(XmlName.parts(name), [], [XmlText(text)]));
    } else {
      child.innerText = text;
    }
  }

  /// Deletes `<measure number="$measureNumber">` from every part and renumbers
  /// the measures that follow so numbering stays consecutive (a pickup measure
  /// numbered 0 keeps its 0).
  ///
  /// The deleted bar's *context* is handed to its neighbours, so removing a bar
  /// doesn't silently change how the rest of the piece engraves or sounds:
  ///  * `<attributes>` — when the deleted bar was the part's first, its
  ///    divisions/key/time/clef are merged into the next measure (tag by tag,
  ///    never overwriting one the next measure already states), otherwise the
  ///    score would lose its key and time signature.
  ///  * repeat barlines — a `|:` moves to the next measure's left edge and a
  ///    `:|` to the previous measure's right edge, so a repeated strain keeps
  ///    its brackets (and the piece keeps its performance order).
  ///  * `<harmony>` — the deleted bar's last chord symbol is copied to the head
  ///    of the next measure when that measure states no chord of its own, since
  ///    the chord it introduced is still the one sounding.
  ///
  /// Throws [ArgumentError] when no part contains the measure, or when it is the
  /// only measure a part has (a part must keep at least one).
  static String deleteMeasure(String musicXml, int measureNumber) {
    final doc = XmlDocument.parse(musicXml);
    var deleted = false;

    for (final part in doc.findAllElements('part')) {
      final measures = part.findElements('measure').toList();
      final idx =
          measures.indexWhere((m) => m.getAttribute('number') == '$measureNumber');
      if (idx < 0) continue;
      if (measures.length <= 1) {
        throw ArgumentError('Cannot delete measure $measureNumber: '
            'a part must keep at least one measure');
      }
      final target = measures[idx];
      final prev = idx > 0 ? measures[idx - 1] : null;
      final next = idx + 1 < measures.length ? measures[idx + 1] : null;

      if (idx == 0 && next != null) _carryAttributes(target, next);
      // A meter change on the deleted bar still governs the bars after it.
      if (idx > 0 && next != null) _carryTime(target, next);
      if (_hasRepeat(target, 'forward') && next != null) {
        _addRepeat(next, forward: true);
      }
      if (_hasRepeat(target, 'backward') && prev != null) {
        _addRepeat(prev, forward: false);
      }
      if (next != null) _carryHarmony(target, next);

      part.children.remove(target);
      _renumberMeasures(part);
      fitBarRests(part);
      deleted = true;
    }

    if (!deleted) {
      throw ArgumentError('Measure $measureNumber not found in MusicXML');
    }
    return doc.toXmlString();
  }

  // ── deleteMeasure helpers ────────────────────────────────────────────────

  static bool _isRepeatBarline(XmlNode n, String direction) =>
      n is XmlElement &&
      n.name.local == 'barline' &&
      n.findElements('repeat')
          .any((r) => r.getAttribute('direction') == direction);

  static bool _hasRepeat(XmlElement measure, String direction) =>
      measure.children.any((n) => _isRepeatBarline(n, direction));

  /// Adds a forward (left edge) or backward (right edge) repeat barline to
  /// [measure]. No-op when that repeat is already there, so moving a repeat onto
  /// a bar that already carries one can't double it up.
  static void _addRepeat(XmlElement measure, {required bool forward}) {
    if (_hasRepeat(measure, forward ? 'forward' : 'backward')) return;
    // A barline already on that edge (a volta's) takes the repeat itself:
    // two barlines on one edge is not MusicXML.
    final edge = forward ? 'left' : 'right';
    final existing = measure.findElements('barline').where((b) =>
        (b.getAttribute('location') ?? 'right') == edge).firstOrNull;
    if (existing != null) {
      existing.children.removeWhere(
          (n) => n is XmlElement && n.name.local == 'bar-style');
      existing.children.insert(
          0,
          XmlElement(XmlName.parts('bar-style'), [],
              [XmlText(forward ? 'heavy-light' : 'light-heavy')]));
      existing.children.add(XmlElement(XmlName.parts('repeat'), [
        XmlAttribute(XmlName.parts('direction'), forward ? 'forward' : 'backward'),
      ]));
      return;
    }
    if (forward) {
      final barline = XmlDocument.parse(
              '<barline location="left"><bar-style>heavy-light</bar-style>'
              '<repeat direction="forward"/></barline>')
          .rootElement
          .copy();
      // A left barline belongs at the start of the measure, after a leading
      // <print> if one is present.
      final printIdx = measure.children
          .indexWhere((n) => n is XmlElement && n.name.local == 'print');
      measure.children.insert(printIdx == -1 ? 0 : printIdx + 1, barline);
    } else {
      measure.children.add(
          XmlDocument.parse('<barline location="right">'
                  '<bar-style>light-heavy</bar-style>'
                  '<repeat direction="backward"/></barline>')
              .rootElement
              .copy());
    }
  }

  /// MusicXML child-order within `<attributes>`, so a merged block stays
  /// schema-ordered (importers read divisions before it means anything).
  static const _attrOrder = [
    'footnote', 'level', 'divisions', 'key', 'time', 'staves', 'part-symbol',
    'instruments', 'clef', 'staff-details', 'measure-style',
  ];

  /// Merges [from]'s `<attributes>` children into [to], skipping any tag [to]
  /// already states (its own value is the more specific one) and re-sorting the
  /// result into schema order.
  /// Moves [from]'s `<time>` onto [to] when [to] states none of its own.
  static void _carryTime(XmlElement from, XmlElement to) {
    final time = from
        .findElements('attributes')
        .expand((a) => a.findElements('time'))
        .firstOrNull;
    if (time == null) return;
    final hasOwn = to
        .findElements('attributes')
        .any((a) => a.findElements('time').isNotEmpty);
    if (hasOwn) return;
    final beats = int.tryParse(time.getElement('beats')?.innerText.trim() ?? '');
    final beatType =
        int.tryParse(time.getElement('beat-type')?.innerText.trim() ?? '');
    if (beats == null || beatType == null) return;
    _insertTime(_attributesFor(to), beats, beatType);
  }

  /// Gives every whole-bar rest (`<rest measure="yes"/>`) in [part] the
  /// `<duration>` of the meter in force, so that changing a meter, or deleting
  /// the bar that changed it, doesn't leave it the old bar's length — Verovio
  /// squeezes a whole-bar rest that doesn't fill its bar almost to nothing.
  static void fitBarRests(XmlElement part) {
    var divisions = 1;
    var beats = 4, beatType = 4;
    for (final measure in part.findElements('measure')) {
      for (final a in measure.findElements('attributes')) {
        divisions =
            int.tryParse(a.getElement('divisions')?.innerText.trim() ?? '') ??
                divisions;
        final t = a.getElement('time');
        final b = int.tryParse(t?.getElement('beats')?.innerText.trim() ?? '');
        final bt =
            int.tryParse(t?.getElement('beat-type')?.innerText.trim() ?? '');
        if (b != null && bt != null && b > 0 && bt > 0) {
          beats = b;
          beatType = bt;
        }
      }
      final ticks = beats * 4 * divisions;
      if (ticks % beatType != 0) continue; // not a whole number of ticks
      for (final note in measure.findElements('note')) {
        if (note.getElement('rest')?.getAttribute('measure') != 'yes') continue;
        final d = note.getElement('duration');
        if (d != null) {
          d.innerText = '${ticks ~/ beatType}';
        }
      }
    }
  }

  static void _carryAttributes(XmlElement from, XmlElement to) {
    final donors = from.findElements('attributes').toList();
    if (donors.isEmpty) return;
    final present = <String>{
      for (final a in to.findElements('attributes'))
        for (final c in a.childElements) c.name.local,
    };
    final carried = <XmlElement>[
      for (final a in donors)
        for (final c in a.childElements)
          if (!present.contains(c.name.local)) c.copy(),
    ];
    if (carried.isEmpty) return;

    var block = to.findElements('attributes').firstOrNull;
    if (block == null) {
      block = XmlElement(XmlName.parts('attributes'));
      // <attributes> precedes the measure's notes; a <print> stays first.
      final printIdx = to.children
          .indexWhere((n) => n is XmlElement && n.name.local == 'print');
      to.children.insert(printIdx == -1 ? 0 : printIdx + 1, block);
    }
    final merged = [...block.childElements.map((e) => e.copy()), ...carried]
      ..sort((a, b) => _attrRank(a).compareTo(_attrRank(b)));
    block.children
      ..clear()
      ..addAll(merged);
  }

  static int _attrRank(XmlElement e) {
    final i = _attrOrder.indexOf(e.name.local);
    return i < 0 ? _attrOrder.length : i;
  }

  /// Copies [from]'s last `<harmony>` to the head of [to] when [to] states no
  /// chord before its first note — the chord [from] introduced is still
  /// sounding, so it should keep a symbol rather than reverting to the one
  /// before it. A `<harmony>` belongs immediately before the note it applies to.
  static void _carryHarmony(XmlElement from, XmlElement to) {
    final donor = from.findElements('harmony').lastOrNull;
    if (donor == null) return;
    final children = to.children;
    final firstNoteIdx =
        children.indexWhere((n) => n is XmlElement && n.name.local == 'note');
    final headHarmonyIdx =
        children.indexWhere((n) => n is XmlElement && n.name.local == 'harmony');
    final statesOwnChord = headHarmonyIdx != -1 &&
        (firstNoteIdx == -1 || headHarmonyIdx < firstNoteIdx);
    if (statesOwnChord) return;
    children.insert(firstNoteIdx == -1 ? children.length : firstNoteIdx,
        donor.copy());
  }

  /// Renumbers [part]'s measures 1, 2, 3, … in document order. A measure
  /// numbered 0 (a pickup) keeps its 0; a non-numeric number (e.g. an OMR
  /// "1a") is left alone.
  static void _renumberMeasures(XmlElement part) {
    var n = 1;
    for (final m in part.findElements('measure')) {
      final cur = int.tryParse(m.getAttribute('number') ?? '');
      if (cur == null || cur == 0) continue;
      m.setAttribute('number', '${n++}');
    }
  }

  static String _lyricsXml(NoteEvent n) {
    final verses = n.lyrics.keys.toList()..sort();
    return [
      for (final v in verses)
        '<lyric number="$v"><syllabic>${n.lyrics[v]!.syllabic}</syllabic>'
            '<text>${_escape(n.lyrics[v]!.text)}</text>'
            '${n.lyrics[v]!.extend ? '<extend/>' : ''}</lyric>',
    ].join();
  }

  static String _escape(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  static String _noteXml(NoteEvent n, int divisions,
      {bool tupletStart = false, bool tupletStop = false}) {
    final dur = _durationDivisions(n, divisions);
    final type = _typeName(n.noteValue);
    final dot = n.dotted ? '<dot/>' : '';
    // The visible accidental sign — emitted verbatim so a courtesy natural (or
    // any explicit sign) round-trips. MusicXML order: after <dot>, before
    // <notations>. null means "follow the key signature, no sign drawn".
    final accidental =
        n.displayAccidental != null ? '<accidental>${n.displayAccidental}</accidental>' : '';
    // <tie> (sounding) goes after <duration>; <tied> (the arc) shares the one
    // <notations> with the fingering. A tie crossing a barline lives in two
    // bars and an edit rewrites one, so an edit can leave half a tie behind —
    // harmless: MidiGenerator only joins a stop to a matching start.
    final tie = '${n.tieStop ? '<tie type="stop"/>' : ''}'
        '${n.tieStart ? '<tie type="start"/>' : ''}';
    final tied = '${n.tieStop ? '<tied type="stop"/>' : ''}'
        '${n.tieStart ? '<tied type="start"/>' : ''}';
    // A rest is never bowed, nor fingered.
    final bow = n.isRest
        ? ''
        : switch (n.bowing) {
            Bowing.down => '<down-bow/>',
            Bowing.up => '<up-bow/>',
            null => '',
          };
    final finger =
        n.scoreFinger != null ? '<fingering>${n.scoreFinger}</fingering>' : '';
    final technical =
        bow.isEmpty && finger.isEmpty ? '' : '<technical>$bow$finger</technical>';
    // Slurs, articulations, ornaments, fermatas: carried verbatim from the
    // note they were read from ([NoteEvent.carriedNotations]).
    final carried = n.carriedNotations.join();
    final t = n.tuplet;
    // After <accidental>, before <notations>, in MusicXML's <note> order.
    final timeMod = t == null
        ? ''
        : '<time-modification><actual-notes>${t.actual}</actual-notes>'
            '<normal-notes>${t.normal}</normal-notes></time-modification>';
    final bracket = t == null
        ? ''
        : '${tupletStart ? '<tuplet type="start" bracket="yes"/>' : ''}'
            '${tupletStop ? '<tuplet type="stop"/>' : ''}';
    final fingering =
        (tied.isEmpty && technical.isEmpty && bracket.isEmpty && carried.isEmpty)
            ? ''
            : '<notations>$tied$bracket$technical$carried</notations>';
    // Last in MusicXML's <note> order. Written for rests too: a syllable whose
    // note was made a rest in the editor stays put (and the editor warns)
    // rather than vanishing on save.
    final lyrics = _lyricsXml(n);
    if (n.isRest) {
      // A fermata over a rest is common; anything else carried rides along.
      final restNotations = bracket.isEmpty && carried.isEmpty
          ? ''
          : '<notations>$bracket$carried</notations>';
      return '<note><rest/><duration>$dur</duration><type>$type</type>$dot'
          '$timeMod$restNotations$lyrics</note>';
    }
    // A chord member's marker comes first in MusicXML's <note> child order,
    // before <pitch>. Rests are never chord members.
    final chord = n.isChord ? '<chord/>' : '';
    final p = _parsePitch(n.pitch);
    final alter = p.alter != 0 ? '<alter>${p.alter}</alter>' : '';
    return '<note>'
        '$chord'
        '<pitch><step>${p.step}</step>$alter<octave>${p.octave}</octave></pitch>'
        '<duration>$dur</duration>'
        '$tie'
        '<type>$type</type>'
        '$dot'
        '$accidental'
        '$timeMod'
        '$fingering'
        '$lyrics'
        '</note>';
  }

  static int _durationDivisions(NoteEvent n, int divisions) {
    final dur = (n.units * divisions / 8).round(); // quarter = 8 units
    return dur < 1 ? 1 : dur;
  }

  static String _typeName(NoteValue v) => switch (v) {
        NoteValue.whole => 'whole',
        NoteValue.half => 'half',
        NoteValue.quarter => 'quarter',
        NoteValue.eighth => 'eighth',
        NoteValue.sixteenth => '16th',
        NoteValue.thirtySecond => '32nd',
      };

  static ({String step, int alter, int octave}) _parsePitch(String pitch) {
    final m = RegExp(r'^([A-G])([#b]?)(\d)$').firstMatch(pitch);
    if (m == null) return (step: 'C', alter: 0, octave: 4);
    final alter = m.group(2) == '#'
        ? 1
        : m.group(2) == 'b'
            ? -1
            : 0;
    return (step: m.group(1)!, alter: alter, octave: int.parse(m.group(3)!));
  }
}
