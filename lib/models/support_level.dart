import 'package:musicxml_tools/musicxml_tools.dart';

/// Practice mode's steps, from the most help on screen to none at all. The
/// Fade button moves one step down this list, a tap on the score one step up.
///
/// * [full] — whatever the player's own display settings show. Practice mode
///   never adds a support the player has switched off.
/// * [letters] — the note names alone (even when the player normally has them
///   off: names are what this step is for).
/// * [staff] — the bare engraving. The rows the supports used stay reserved,
///   so no note moves between steps.
/// * [bowings] — the staff with every bar dimmed except those holding a cue
///   (see [cueBarsOf]).
/// * [dimmed] — the score all but hidden; the tray still works.
/// * [black] — the whole screen black at minimum brightness.
enum SupportLevel { full, letters, staff, bowings, dimmed, black }

/// The steps that look different from each other for this piece and these
/// settings, in order. A step that would look the same as the one above it is
/// left out, so every Fade changes something.
///
/// * [fullHasMore] — the player's view shows something besides note names
///   (fingerings, string colours, chords, coloured noteheads, a colour lane).
/// * [fullHasNames] — the player's view shows note names.
/// * [hasCues] — some bar has a cue, so [SupportLevel.bowings] has something
///   to leave lit.
/// * [namesHaveRoom] — the layout already has a row the names can use (the
///   fingering channel, or the chord row). Practice mode never re-lays the
///   piece out to make one, so without it there is no letters step.
List<SupportLevel> supportLadder({
  required bool fullHasMore,
  required bool fullHasNames,
  required bool hasCues,
  bool namesHaveRoom = true,
}) =>
    [
      if (fullHasMore) SupportLevel.full,
      // Letters is a step down from a view with more on it, and the player's
      // own view when names are all it has. Above a bare staff it would ADD a
      // support, so it is left out there.
      if (fullHasNames || (fullHasMore && namesHaveRoom)) SupportLevel.letters,
      SupportLevel.staff,
      if (hasCues) SupportLevel.bowings,
      SupportLevel.dimmed,
      SupportLevel.black,
    ];

/// [level] as a step of [ladder]: itself when it is one, otherwise the next
/// step with less help (a setting changed under it and removed its step).
SupportLevel snapToLadder(SupportLevel level, List<SupportLevel> ladder) {
  for (final l in ladder) {
    if (l.index >= level.index) return l;
  }
  return ladder.last;
}

/// One step less help than [level], or [level] at the bottom.
SupportLevel fewerSupports(SupportLevel level, List<SupportLevel> ladder) {
  final i = ladder.indexOf(snapToLadder(level, ladder));
  return ladder[(i + 1).clamp(0, ladder.length - 1)];
}

/// One step more help than [level], or [level] at the top.
SupportLevel moreSupports(SupportLevel level, List<SupportLevel> ladder) {
  final i = ladder.indexOf(snapToLadder(level, ladder));
  return ladder[(i - 1).clamp(0, ladder.length - 1)];
}

/// The bars [SupportLevel.bowings] leaves lit: those with a bow mark (up or
/// down) on any note. Kept a function of the bar alone so other marks
/// (dynamics, shifts) can join it later.
Set<int> cueBarsOf(ParsedPiece piece) => {
      for (final m in piece.measures)
        if (m.notes.any((n) => n.bowing != null)) m.number,
    };

/// Practice mode's state for the open piece.
class PracticeState {
  final bool active;
  final SupportLevel level;

  /// A peek (a tap that brought a support back) stopped the fading on each
  /// loop pass; the Fade button starts it again. Only ever set while the
  /// "keep fading after a peek" setting is off.
  final bool autoFadePaused;

  const PracticeState({
    required this.active,
    required this.level,
    this.autoFadePaused = false,
  });

  static const off = PracticeState(active: false, level: SupportLevel.full);

  PracticeState copyWith({bool? active, SupportLevel? level, bool? autoFadePaused}) =>
      PracticeState(
        active: active ?? this.active,
        level: level ?? this.level,
        autoFadePaused: autoFadePaused ?? this.autoFadePaused,
      );

  /// The Fade button: one step down, and automatic fading resumes.
  PracticeState fade(List<SupportLevel> ladder) =>
      copyWith(level: fewerSupports(level, ladder), autoFadePaused: false);

  /// A tap on the score: one step up. With [refadeAfterPeek] off and
  /// [autoFade] on, the automatic fading waits for the next Fade.
  PracticeState peek(List<SupportLevel> ladder,
      {required bool autoFade, required bool refadeAfterPeek}) {
    final up = moreSupports(level, ladder);
    if (up == snapToLadder(level, ladder)) return this;
    return copyWith(
        level: up,
        autoFadePaused: autoFadePaused || (autoFade && !refadeAfterPeek));
  }

  /// A looped passage came round: one step down if fading on each pass.
  PracticeState loopPassed(List<SupportLevel> ladder, {required bool autoFade}) =>
      !autoFade || autoFadePaused
          ? this
          : copyWith(level: fewerSupports(level, ladder));
}
