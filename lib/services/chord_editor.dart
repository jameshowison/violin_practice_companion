import '../models/duration_step.dart';
import '../models/note_event.dart';
import '../models/section.dart';

/// A contiguous chord group. [start] is the primary's index; [end] is
/// EXCLUSIVE. A note carrying no members is `(start: i, end: i + 1)`.
typedef ChordRange = ({int start, int end});

/// Pure transformations on a measure's note list that keep MusicXML's chord
/// structure intact. Sibling to [MeasureXmlEditor], which serializes the result.
///
/// ## The invariant
///
/// > A chord member ([NoteEvent.isChord]) immediately follows its *primary* —
/// > the nearest preceding note with `isChord == false` — and carries that
/// > primary's [NoteEvent.noteValue]/[NoteEvent.dotted]. A rest is never a
/// > member and never owns members.
///
/// This mirrors MusicXML exactly: `<chord/>` means "I attach to the note before
/// me", so membership is purely positional. That's what makes [stack] a flag
/// flip rather than a splice — the selected note's group already sits directly
/// after the previous group's last member, so setting `isChord` merges the two
/// runs with no reordering.
///
/// Every transform runs [normalize] before returning, so each operation only
/// has to do its local job and the four global rules hold regardless. All
/// transforms are pure: they return a NEW list and never mutate the input.
class ChordEditor {
  ChordEditor._();

  // ── Queries ───────────────────────────────────────────────────────────────

  /// Index of the primary governing [i] (itself when [i] is a primary). A
  /// stray leading member (index 0) counts as its own primary.
  static int primaryIndexOf(List<NoteEvent> notes, int i) {
    var k = i.clamp(0, notes.length - 1);
    while (k > 0 && notes[k].isChord) {
      k--;
    }
    return k;
  }

  /// The whole stack containing [i].
  static ChordRange groupRange(List<NoteEvent> notes, int i) {
    final start = primaryIndexOf(notes, i);
    var end = start + 1;
    while (end < notes.length && notes[end].isChord) {
      end++;
    }
    return (start: start, end: end);
  }

  /// Number of notes sharing [i]'s stem (1 for a plain note).
  static int groupSize(List<NoteEvent> notes, int i) {
    final g = groupRange(notes, i);
    return g.end - g.start;
  }

  /// Every group in document order, in one pass — for [MeasureEditRow].
  static List<ChordRange> groups(List<NoteEvent> notes) {
    final out = <ChordRange>[];
    var i = 0;
    while (i < notes.length) {
      var end = i + 1;
      while (end < notes.length && notes[end].isChord) {
        end++;
      }
      out.add((start: i, end: end));
      i = end;
    }
    return out;
  }

  // ── Enablement ────────────────────────────────────────────────────────────
  //
  // These return null when the operation is allowed, else a user-facing reason.
  // Buttons take BOTH their enabled state and their tooltip from the same call,
  // so the two can never disagree.

  /// Why [i] can't join the previous note's stem, or null when it can.
  static String? stackBlockedReason(List<NoteEvent> notes, int? i) {
    if (i == null || i < 0 || i >= notes.length) return 'Select a note first.';
    if (notes[i].isChord) return 'This note is already stacked.';
    if (i == 0) return 'Nothing before this note to stack onto.';
    if (notes[i].isRest) return "A rest can't be part of a chord.";
    // Resolve through the primary so a malformed member-after-rest is still
    // rejected for the right reason.
    if (notes[primaryIndexOf(notes, i - 1)].isRest) {
      return "Can't stack onto a rest.";
    }
    return null;
  }

  static bool canStack(List<NoteEvent> notes, int? i) =>
      stackBlockedReason(notes, i) == null;

  static bool canUnstack(List<NoteEvent> notes, int? i) =>
      i != null && i > 0 && i < notes.length && notes[i].isChord;

  /// Why [i] can't be turned into a rest, or null when it can.
  ///
  /// Neither end of a chord may become a rest: [MeasureXmlEditor] emits rests
  /// without the `<chord/>` marker, so a member would silently detach into a
  /// sequential rest, and a primary would emit `<rest/>` followed by orphaned
  /// `<chord/>` notes. Requiring an explicit unstack keeps the consequence
  /// visible instead of restructuring the bar behind a button labelled "rest".
  static String? restBlockedReason(List<NoteEvent> notes, int? i) {
    if (i == null || i < 0 || i >= notes.length) return 'Select a note first.';
    if (groupSize(notes, i) > 1) {
      return "Unstack this note first — a chord can't contain a rest.";
    }
    return null;
  }

  // ── Transforms ────────────────────────────────────────────────────────────

  /// Repairs the invariant: drops `isChord` where it can't be represented (a
  /// leading member, a rest member, a member of a rest) and snaps every
  /// surviving member to its primary's duration. Idempotent, and safe to run on
  /// freshly-parsed OMR output. Walks forward so each check sees an
  /// already-repaired predecessor.
  static List<NoteEvent> normalize(List<NoteEvent> notes) {
    final out = [...notes];
    for (var i = 0; i < out.length; i++) {
      if (!out[i].isChord) continue;
      if (i == 0 || out[i].isRest || out[i - 1].isRest) {
        out[i] = out[i].copyWith(isChord: false);
        continue;
      }
      final p = out[primaryIndexOf(out, i)];
      if (out[i].noteValue != p.noteValue || out[i].dotted != p.dotted) {
        out[i] = out[i].copyWith(noteValue: p.noteValue, dotted: p.dotted);
      }
    }
    return out;
  }

  /// [i] joins the previous note's stem, adopting that primary's duration.
  ///
  /// Any members [i] already carries come with it, so stacking a double-stop
  /// onto a note yields a three-note chord rather than orphans. Repeating this
  /// on successive notes is how chords of any size get built.
  static List<NoteEvent> stack(List<NoteEvent> notes, int i) {
    if (!canStack(notes, i)) return [...notes];
    final g = groupRange(notes, i);
    final target = notes[primaryIndexOf(notes, i - 1)];
    final out = [...notes];
    for (var k = g.start; k < g.end; k++) {
      out[k] = out[k].copyWith(
          isChord: true, noteValue: target.noteValue, dotted: target.dotted);
    }
    return normalize(out);
  }

  /// [i] leaves its stem and stands alone again.
  ///
  /// Members after [i] become *its* members — the exact inverse of [stack] for
  /// the last member of a group, and a deliberate split when applied to a middle
  /// one. Extracting a middle note instead would have to reorder the list and
  /// silently move the note's onset.
  static List<NoteEvent> unstack(List<NoteEvent> notes, int i) {
    if (!canUnstack(notes, i)) return [...notes];
    final out = [...notes];
    out[i] = out[i].copyWith(isChord: false);
    return normalize(out);
  }

  /// Applies [step] to every note sharing [i]'s stem — MusicXML requires chord
  /// members to match their primary's duration.
  static List<NoteEvent> setDuration(
      List<NoteEvent> notes, int i, DurationStep step) {
    if (notes.isEmpty) return [...notes];
    final g = groupRange(notes, i);
    final out = [...notes];
    for (var k = g.start; k < g.end; k++) {
      out[k] = out[k].copyWith(noteValue: step.value, dotted: step.dotted);
    }
    return out;
  }

  /// Replaces the note at [i], re-checking the invariant afterwards.
  static List<NoteEvent> replaceAt(List<NoteEvent> notes, int i, NoteEvent n) {
    final out = [...notes];
    out[i] = n;
    return normalize(out);
  }

  /// Toggles [i] between a pitched note and a rest. No-op when blocked (see
  /// [restBlockedReason]). A rest with no usable stored pitch becomes B4.
  static List<NoteEvent> toggleRest(List<NoteEvent> notes, int i) {
    if (restBlockedReason(notes, i) != null) return [...notes];
    final n = notes[i];
    final out = [...notes];
    if (n.isRest) {
      out[i] = RegExp(r'^[A-G]').hasMatch(n.pitch)
          ? n.copyWith(isRest: false)
          : NoteEvent(
              pitch: 'B4',
              midiNumber: 71,
              octave: 4,
              noteValue: n.noteValue,
              dotted: n.dotted,
              isRest: false,
            );
    } else {
      out[i] = n.copyWith(isRest: true);
    }
    return normalize(out);
  }

  /// Inserts [fresh] after the END of [i]'s stack, never between a primary and
  /// its members (which would re-parent the whole stack onto the new note).
  /// Returns the index to select.
  static ({List<NoteEvent> notes, int selectedIndex}) insertAfter(
      List<NoteEvent> notes, int i, NoteEvent fresh) {
    final at = groupRange(notes, i).end;
    final out = [...notes]..insert(at, fresh.copyWith(isChord: false));
    return (notes: normalize(out), selectedIndex: at);
  }

  /// Removes [i]. Deleting a primary promotes its first member so the rest of
  /// the stack isn't re-parented onto whatever precedes — deleting the bottom
  /// note of a double-stop leaves the top note sounding in the same slot, and
  /// the bar total is unchanged. Returns the index to select (null when empty).
  static ({List<NoteEvent> notes, int? selectedIndex}) deleteAt(
      List<NoteEvent> notes, int i) {
    final out = [...notes];
    if (!out[i].isChord && i + 1 < out.length && out[i + 1].isChord) {
      out[i + 1] = out[i + 1].copyWith(isChord: false);
    }
    out.removeAt(i);
    return (
      notes: normalize(out),
      selectedIndex: out.isEmpty ? null : i.clamp(0, out.length - 1),
    );
  }

  /// Rebuilds [from] with a new sounding pitch.
  ///
  /// Fresh-constructs rather than using `copyWith` because clearing
  /// [NoteEvent.displayAccidental] back to null is impossible through a
  /// `?? this.` copyWith — and that is exactly how `isChord` used to get
  /// dropped, un-chording a note on every pitch nudge. Centralizing it here
  /// means the structural fields (chord membership, chord symbol, rhythm) can't
  /// be forgotten again. Fingering is dropped by default because a pitch change
  /// invalidates it; [keepFingering] covers the case where the sounding pitch
  /// is unchanged (e.g. clearing a courtesy natural).
  static NoteEvent repitch(
    NoteEvent from, {
    required String pitch,
    required int midiNumber,
    required int octave,
    String? displayAccidental,
    bool keepFingering = false,
  }) =>
      NoteEvent(
        pitch: pitch,
        midiNumber: midiNumber,
        octave: octave,
        noteValue: from.noteValue,
        dotted: from.dotted,
        isRest: false,
        displayAccidental: displayAccidental,
        chordSymbol: from.chordSymbol,
        isChord: from.isChord,
        scoreFinger: keepFingering ? from.scoreFinger : null,
        fingerNumber: keepFingering ? from.fingerNumber : null,
        fingerString: keepFingering ? from.fingerString : null,
      );

  /// Moves any section marker in [measureNumber] that landed on a chord member
  /// back to its primary — every member shares one onset, so a section can't
  /// begin mid-stem. Markers colliding on one primary dedupe last-wins, matching
  /// [sectionLabelByMeasure]. Markers in other measures pass through untouched.
  static List<Section> normalizeMarkers(
      List<NoteEvent> notes, List<Section> starts, int measureNumber) {
    if (notes.isEmpty) return List.of(starts);
    final out = <Section>[];
    final seen = <int, int>{}; // primary index → position in `out`
    for (final s in starts) {
      if (s.startMeasure != measureNumber) {
        out.add(s);
        continue;
      }
      final at =
          primaryIndexOf(notes, s.startNote.clamp(0, notes.length - 1));
      final moved = Section(
          label: s.label, startMeasure: s.startMeasure, startNote: at);
      final prior = seen[at];
      if (prior != null) {
        out[prior] = moved;
      } else {
        seen[at] = out.length;
        out.add(moved);
      }
    }
    return out;
  }
}
