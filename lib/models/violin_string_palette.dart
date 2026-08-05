import 'package:flutter/painting.dart';

import 'chord_palette.dart';

/// One colour per violin string, in the convention beginner method books use
/// (and the one the user learned on): G green, D blue, A red, E yellow.
///
/// The colour is what makes the G/D/A/E letter redundant in the fingering
/// channel — a chip's fill says which string, so the label only has to carry the
/// finger. That is the whole reason the palette exists, so the four hues must
/// stay maximally distinguishable from each other; unlike [ChordPalette] they
/// carry no ordering or harmonic meaning, so there is nothing to derive them
/// from and the table is simply the convention.
///
/// Deliberately distinct from [ChordPalette]: both appear on the staff at once,
/// in adjacent lanes. The chord palette's yellow (`V`) and this E-string yellow
/// are the closest pair — they are told apart by lane, by shape (a wide bar
/// versus a small chip) and by content (`V (A)` versus `1`), which is what the
/// lane separation buys.
class ViolinStringPalette {
  ViolinStringPalette._();

  /// String name (`'G'`, `'D'`, `'A'`, `'E'`) → chip fill.
  static const byString = <String, Color>{
    'G': Color(0xFF1B5E20), // dark green
    'D': Color(0xFF1565C0), // blue
    'A': Color(0xFFC62828), // red
    'E': Color(0xFFFBC02D), // yellow
  };

  /// A note whose string we don't know (no `fingerString` in the lookup table).
  static const unknown = Color(0xFF9E9E9E);

  /// How many stagger steps above the channel's floor a string's rule (and its
  /// number) sits, in [StringColourStyle.underline]: G 0, D 1, A 2, E 3.
  ///
  /// Pitch order, so up on the page is up in pitch — the same convention the
  /// staff right below already uses. This is what makes the direction of a string
  /// CHANGE visible: colour alone says "different string" but not which way the
  /// hand went, and a step up or down at the join says it without being read.
  ///
  /// An unknown string shares G's level. It has no place in the order (it isn't
  /// a pitch), and the floor is the one level that never implies a crossing it
  /// can't support: a grey rule at the bottom reads as "no information", where a
  /// grey rule floating mid-stack would read as a string between D and A.
  static const stackOrder = <String, int>{'G': 0, 'D': 1, 'A': 2, 'E': 3};

  /// The tallest step in [stackOrder] — the vertical range the stagger needs, in
  /// steps. Derived rather than written down so the channel's budget can't drift
  /// out of step with the table.
  static final int maxStackOrder =
      stackOrder.values.reduce((a, b) => a > b ? a : b);

  /// [string]'s step in the stagger, or G's floor for anything off the four.
  static int stepOf(String? string) => stackOrder[string] ?? 0;

  /// Fill for [string], or [unknown] for anything off the four.
  static Color of(String? string) => byString[string] ?? unknown;

  /// Readable finger-number colour on a chip filled with [fill].
  ///
  /// Reuses [ChordPalette.inkOn] rather than tabling a text colour per string:
  /// the problem is identical (this palette also spans near-black green to bright
  /// yellow) and a second copy of the rule would be free to drift out of step
  /// with the chord lane sitting directly above.
  static Color inkOn(Color fill) => ChordPalette.inkOn(fill);

  /// [string]'s colour as a RULE drawn straight on the page — the underline
  /// style, which has no grey band behind it.
  ///
  /// A fill and a line need different colours from the same hue. The E-string
  /// yellow reads fine as a chip (it's a large area, and it takes dark text), but
  /// as a line on white it all but disappears, which is the one thing an
  /// underline cannot do. So a hue light enough to have needed dark ink is
  /// darkened here — the SAME luminance test [inkOn] uses, deliberately, because
  /// it's the same question asked twice: "is this colour too light to carry
  /// meaning on its own?"
  static Color rule(String? string) {
    final c = of(string);
    return c.computeLuminance() > 0.45 ? ChordPalette.dim(c) : c;
  }
}

/// How the string is expressed in the fingering channel.
///
/// Three styles rather than a switch because which one reads best is a question
/// about eyes and paper, not logic — they are here to be compared on real music.
enum StringColourStyle {
  /// The number sits in a chip filled with the string's colour. Colour is easy
  /// to identify (a big saturated area) but the number is reversed out of it,
  /// and at practice sizes white glyphs on saturated fills lose their strokes.
  chips,

  /// A near-black number over a coloured rule that runs for as long as the
  /// playing stays on that string. Maximum number legibility; the colour is a
  /// thinner cue, bought back by the length of the run and by the height it is
  /// drawn at — the four strings are staggered in pitch order (see [stackOrder]),
  /// so a string change steps up or down as well as changing colour.
  underline,

  /// No colour at all — neutral chips, with the G/D/A/E letter carried by the
  /// label instead (see [StringLabelStyle]).
  off,
}

/// Near-black for the numbers in [StringColourStyle.underline]. Matches
/// [ChordPalette.inkOn]'s dark ink, so a label reads the same whether it's on a
/// pale chip or on the page.
const fingeringInk = Color(0xFF1A1A1A);

/// The fingering channel itself — the light grey band the chips sit in.
///
/// Semi-transparent so a section background wash still reads through it: the
/// wash spans the full system band and losing a stripe of it to the channel
/// would break the "this whole passage is section B" read. Light enough that
/// every chip fill in [ViolinStringPalette] has contrast against it, which is
/// what the channel is for — the bare yellow chip on white page was the case
/// that needed it.
const fingeringChannelColor = Color(0xB3E8E8E8);

/// Chip fill when the string is NOT being shown as colour — the labels carry the
/// G/D/A/E letter instead, so the fill must not imply a string.
///
/// Still a fill rather than nothing: the chip's job in that mode is to separate
/// its label from the neighbouring ones and from the channel behind it, which a
/// bare glyph on grey wouldn't do. Light enough to take dark text, per
/// [ViolinStringPalette.inkOn].
const fingeringChipNeutral = Color(0xFFFAFAFA);

// ── Underline geometry ───────────────────────────────────────────────────────
//
// [StringColourStyle.underline] divides the channel's height four ways: the
// digits, a gap, the coloured rule, and the stagger the strings climb through.
// Everything is a FRACTION of the channel, so the whole assembly scales with the
// notes at every zoom (the same principle as the lane heights themselves).
//
// These live here rather than in the painter because they are the reason
// `EngravedScore.fingeringLaneHeightFraction` is the size it is — the channel is
// sized to hold exactly this stack — and a constraint spanning two files is one a
// test should be able to read.

/// The rule's thickness, as a fraction of the channel height.
///
/// Deliberately chunky. A hairline would be tidier, but the whole bargain of this
/// style is trading colour area for number legibility, and below about this weight
/// dark green and blue stop being tellable apart.
const underlineRuleFraction = 0.15;

/// Clear space between the digits and the rule under them.
const underlineRuleGapFraction = 0.06;

/// One string's worth of stagger: how far G→D→A→E lifts the rule AND its number
/// (see [ViolinStringPalette.stackOrder]).
///
/// Small on purpose — a couple of pixels at practice zoom, well under the rule's
/// own thickness. The step only has to be big enough that the JOIN between two
/// runs reads as a jog rather than a straight line; make it much bigger and the
/// numbers stop scanning as a row, which is the property the lane exists for.
const underlineStringStepFraction = 0.085;

/// The digits' share of the channel — what's left after the rule, its gap, and the
/// room the topmost string needs to rise into. So nothing collides and no level
/// pokes out of the band, however tight the squeeze gets.
double get underlineTextFraction =>
    1.0 -
    underlineRuleFraction -
    underlineRuleGapFraction -
    ViolinStringPalette.maxStackOrder * underlineStringStepFraction;
