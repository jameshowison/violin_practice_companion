import '../models/duration_step.dart';
import '../models/key_signature.dart';
import '../models/note_event.dart';
import '../models/parsed_piece.dart';
import 'musicxml_parser.dart';

/// Renders a [ParsedPiece] back out as ABC notation — the text format the app
/// already *imports* (see `abc_converter_base.dart`), so a tune scanned or
/// edited here can be pasted into thesession.org, mailed to a teacher, or
/// re-imported somewhere else.
///
/// ## Why Dart, and not the JS round-trip
///
/// The import side runs abcjs in a JS engine because parsing ABC is genuinely
/// hard. Emitting it is not: [ParsedPiece] is already a flat list of measures of
/// notes with a key, a meter and repeat flags, which is very nearly ABC's own
/// data model. Bundling a second JS library (xml2abc) to walk back across the
/// same bridge would cost an asset, an engine warm-up and a platform split for a
/// few hundred lines of pure string building.
///
/// ## What survives the trip
///
/// Pitches (with octave marks), rests, note lengths including dots, stacked
/// chord notes (`[CEG]`), chord symbols (`"Am"`), forward/backward repeats, the
/// key signature with its mode, and the meter. What does NOT survive is anything
/// [MusicXmlParser] itself drops — slurs, ties, tuplets, grace notes, dynamics,
/// lyrics, voltas, and fingerings. This is a lossy export of the *tune*, not a
/// round-trip of the document, and [AbcExporter.lossyFeatureNote] says so in the
/// words the export dialog shows the user.
class AbcExporter {
  const AbcExporter._();

  /// Shown under the exported text so nobody is surprised when a re-import comes
  /// back plainer than it went out.
  static const String lossyFeatureNote =
      'Notes, chord symbols, repeats, key and time signature are exported. '
      'Slurs, ties, triplets, grace notes and fingerings are not.';

  /// The ABC document for [piece], titled [title].
  ///
  /// [measuresPerLine] controls line wrapping only — ABC treats a line break
  /// between bars as a system break hint, never as musical content.
  static String export(
    ParsedPiece piece, {
    required String title,
    int measuresPerLine = 4,
  }) {
    final unit = _unitUnits(piece);
    final buffer = StringBuffer()
      ..writeln('X: 1')
      ..writeln('T: ${_headerText(title)}')
      ..writeln('M: ${piece.beatsPerMeasure}/${piece.beatType}')
      ..writeln('L: 1/${32 ~/ unit}')
      ..writeln('K: ${MusicXmlParser.keyName(piece.keyFifths, piece.keyMode)}');

    final spelling = _Spelling.forPiece(piece);
    final beamUnits = _beamUnits(piece);
    final measures = piece.measures;
    final line = StringBuffer();

    void write(String token) {
      if (token.isEmpty) return;
      if (line.isNotEmpty) line.write(' ');
      line.write(token);
    }

    for (var i = 0; i < measures.length; i++) {
      final m = measures[i];
      var leading = _leadingBarline(
        isFirst: i == 0,
        previousRepeatEnd: i > 0 && measures[i - 1].repeatEnd,
        repeatStart: m.repeatStart,
      );
      if (i > 0 && i % measuresPerLine == 0) {
        // Wrapping splits the barline across the break: the part that closes
        // the bar above stays with it, and only a repeat-open leads the new
        // line. Writing the whole thing on either side would strand a `:|` at
        // the head of a line, reading as though it closed the bar below it.
        final (closing, opening) = switch (leading) {
          '::' => (':|', '|:'),
          '|:' => ('', '|:'),
          _ => (leading, ''),
        };
        write(closing);
        buffer.writeln(line.toString());
        line.clear();
        leading = opening;
      }
      write(leading);
      write(_measureBody(m, spelling, unit, beamUnits));
    }
    write(measures.isNotEmpty && measures.last.repeatEnd ? ':|' : '|]');
    if (line.isNotEmpty) buffer.writeln(line.toString());

    return buffer.toString();
  }

  /// The barline that *precedes* a measure, folding the previous bar's closing
  /// repeat into it.
  ///
  /// Barlines are emitted ahead of their measure rather than after it because a
  /// `|:` belongs to the bar it opens: emitting trailing barlines instead would
  /// produce `… | |: …` whenever a repeat starts mid-tune, and would have no
  /// place to collapse a back-to-back `:|` + `|:` into the conventional `::`.
  static String _leadingBarline({
    required bool isFirst,
    required bool previousRepeatEnd,
    required bool repeatStart,
  }) {
    if (isFirst) return repeatStart ? '|:' : '';
    if (previousRepeatEnd && repeatStart) return '::';
    if (previousRepeatEnd) return ':|';
    if (repeatStart) return '|:';
    return '|';
  }

  /// One measure's notes, beamed into beats.
  ///
  /// Whitespace is not decoration in ABC: notes written without a space between
  /// them are beamed together. Spacing every note apart would be legal and would
  /// engrave a bar of eighths as eight separate flagged notes, so the space goes
  /// in only where the beat changes — which is exactly how the tune would have
  /// been typed by hand.
  static String _measureBody(
      Measure measure, _Spelling spelling, int unit, int beamUnits) {
    // Accidental state is per-bar and, deliberately, per-LETTER rather than per
    // letter+octave. ABC readers disagree about whether an accidental carries to
    // the same note in another octave, so once a letter has been altered in a
    // bar every later note on that letter states its accidental outright. The
    // result is a few redundant signs and zero ambiguity.
    final altered = <String>{};
    final body = StringBuffer();
    var position = 0;
    var lastBeat = 0;

    for (var i = 0; i < measure.notes.length; i++) {
      final note = measure.notes[i];
      // A chord member belongs to the primary note before it; it was already
      // consumed by the group below.
      if (note.isChord && i > 0) continue;

      final group = <NoteEvent>[note];
      for (var j = i + 1; j < measure.notes.length; j++) {
        if (!measure.notes[j].isChord) break;
        group.add(measure.notes[j]);
      }

      final units = thirtySecondUnits(note.noteValue, note.dotted);
      final head = group.length == 1
          ? _noteToken(group.first, spelling, altered)
          : '[${group.map((n) => _noteToken(n, spelling, altered)).join()}]';

      final symbol = note.chordSymbol;
      final prefix =
          (symbol == null || symbol.isEmpty) ? '' : '"${symbol.replaceAll('"', '')}"';

      // Compare beat *indices* rather than testing for a zero remainder, so a
      // bar that goes off the grid (a dotted quarter in 4/4) still breaks at
      // every following beat instead of running together to the barline.
      final beat = position ~/ beamUnits;
      if (body.isNotEmpty && (beat != lastBeat || prefix.isNotEmpty)) {
        body.write(' ');
      }
      body.write('$prefix$head${_lengthToken(units, unit)}');
      lastBeat = beat;
      position += units;
    }
    return body.toString();
  }

  /// The span notes are beamed over, in 32nd-note units.
  ///
  /// One beat, except at the two extremes engravers don't actually follow:
  /// compound meters (3/8, 6/8, 9/8, 12/8) beam a whole dotted beat, and a beat
  /// longer than a quarter is subdivided — cut time is felt in two but nobody
  /// writes eight sixteenths under a single beam.
  static int _beamUnits(ParsedPiece piece) {
    final beat = 32 ~/ piece.beatType;
    if (piece.beatType == 8 && piece.beatsPerMeasure % 3 == 0) return beat * 3;
    return beat > 8 ? 8 : beat;
  }

  /// A single pitch (or `z` for a rest) with its accidental and octave marks,
  /// updating [altered] with any letter this note alters.
  static String _noteToken(
      NoteEvent note, _Spelling spelling, Set<String> altered) {
    if (note.isRest) return 'z';

    final letter = note.pitch[0].toUpperCase();
    final alter = spelling.alterOf(note, letter);
    final fromKey = spelling.keyAlterFor(letter);
    final needsSign = alter != fromKey || altered.contains(letter);
    if (alter != fromKey) altered.add(letter);

    return '${needsSign ? _accidental(alter) : ''}${_octaveMarks(letter, note.octave)}';
  }

  static String _accidental(int alter) => switch (alter) {
        0 => '=',
        1 => '^',
        2 => '^^',
        -1 => '_',
        -2 => '__',
        _ => alter > 0 ? '^' * alter : '_' * -alter,
      };

  /// ABC's octave convention: `C`–`B` is the middle-C octave (MusicXML octave
  /// 4), lowercase is the octave above, and `'` / `,` step further out.
  static String _octaveMarks(String letter, int octave) => octave >= 5
      ? letter.toLowerCase() + "'" * (octave - 5)
      : letter + ',' * (4 - octave);

  /// A note's length as a multiple of the unit note length (`L:`), omitted when
  /// it IS the unit — `A` rather than `A1`, which is what a human would write.
  static String _lengthToken(int units, int unit) {
    if (units == unit) return '';
    if (units % unit == 0) return '${units ~/ unit}';
    final g = _gcd(units, unit);
    final numerator = units ~/ g;
    final denominator = unit ~/ g;
    return numerator == 1 ? '/$denominator' : '$numerator/$denominator';
  }

  /// The unit note length, in 32nd-note units, that lets the most notes print as
  /// a bare letter.
  ///
  /// Taking the GCD of every duration is what picks 1/16 for a tune full of
  /// sixteenths and 1/8 for a plain one. It's rounded down to a power of two (a
  /// bar of nothing but dotted sixteenths gives a GCD of 3, which is not a note
  /// length) and capped at an eighth, since `L:` longer than 1/8 is unidiomatic
  /// and would only push every short note into a fraction.
  static int _unitUnits(ParsedPiece piece) {
    var g = 0;
    for (final measure in piece.measures) {
      for (final note in measure.notes) {
        if (note.isChord) continue;
        g = _gcd(g, thirtySecondUnits(note.noteValue, note.dotted));
      }
    }
    if (g == 0) return 4;
    var unit = 1;
    while (unit * 2 <= 4 && g % (unit * 2) == 0) {
      unit *= 2;
    }
    return unit;
  }

  static int _gcd(int a, int b) {
    while (b != 0) {
      final t = b;
      b = a % b;
      a = t;
    }
    return a.abs();
  }

  /// Header fields are line-oriented, so a title carrying a newline would turn
  /// the rest of itself into bogus ABC.
  static String _headerText(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Decides what alteration each note actually carries — the one genuinely
/// awkward part of the export, because the MusicXML this app ingests follows two
/// incompatible conventions.
///
/// A conforming file states the *sounding* pitch: an F♯ under a two-sharp
/// signature carries `<alter>1</alter>` even though no sharp is drawn. That is
/// what MuseScore and the OMR output do. The bundled abcjs converter (and hence
/// every tune imported from ABC) instead writes `<alter>` only where an
/// accidental is actually *drawn*, leaving key-signature sharps implicit — so
/// reading its `<alter>` literally turns every F♯ in Old Joe Clark into an F♮.
///
/// Neither convention can be detected from a single note, but it shows up
/// reliably across a piece: a drawing-led file only ever alters a pitch where it
/// also draws the sign, so an `<alter>` with **no** `<accidental>` beside it is
/// the fingerprint of a sounding-pitch file. Find one anywhere in the piece and
/// every `<alter>` can be trusted wholesale; find none and an unmarked note
/// follows the key signature instead.
///
/// (The tempting simpler test — "does any note restate the key signature?" —
/// looks equivalent and isn't. The Devil's Dream is written `BA^GB` in A major,
/// a redundant sharp on a note the signature already sharpens, which is enough
/// to make a drawing-led file look like a sounding-pitch one and turn every
/// other F♯ and C♯ in the reel natural.)
class _Spelling {
  _Spelling({required this.keyFifths, required this.trustAlter});

  /// The piece's key signature, as a MusicXML `<fifths>` count.
  final int keyFifths;

  /// Whether an unmarked note's `<alter>` states its sounding pitch.
  final bool trustAlter;

  factory _Spelling.forPiece(ParsedPiece piece) {
    var trust = false;
    outer:
    for (final measure in piece.measures) {
      for (final note in measure.notes) {
        if (note.isRest || note.displayAccidental != null) continue;
        if (_soundingAlter(note, note.pitch[0].toUpperCase()) != 0) {
          trust = true;
          break outer;
        }
      }
    }
    return _Spelling(keyFifths: piece.keyFifths, trustAlter: trust);
  }

  /// The alteration [letter] carries by default under this key signature.
  int keyAlterFor(String letter) =>
      KeySignature.defaultAlter(keyFifths, letter);

  /// This note's alteration, resolving the two conventions above. The drawn
  /// accidental wins where there is one: it's the only unambiguous statement
  /// either kind of file makes.
  int alterOf(NoteEvent note, String letter) {
    final drawn = _accidentalAlter[note.displayAccidental];
    if (drawn != null) return drawn;
    final sounding = _soundingAlter(note, letter);
    if (trustAlter) return sounding;
    // Drawing-led file, nothing drawn: the key signature governs. Only a
    // *missing* alteration is overridden this way — an explicit one (a ♭ in a
    // sharp key, say) is still real data even without an `<accidental>`.
    return sounding == 0 ? keyAlterFor(letter) : sounding;
  }

  /// Semitone alteration as encoded, derived from the MIDI number rather than
  /// the `#`/`b` suffix on [NoteEvent.pitch] — the suffix collapses double
  /// accidentals to a single character, the MIDI number doesn't.
  static int _soundingAlter(NoteEvent note, String letter) =>
      note.midiNumber - ((_naturalSemitone[letter] ?? 0) + (note.octave + 1) * 12);

  /// MusicXML `<accidental>` values, as [MusicXmlParser] stores them verbatim.
  /// Unlisted values (`quarter-sharp`, editorial variants) fall through to the
  /// encoded alteration rather than inventing a sign ABC has no spelling for.
  static const _accidentalAlter = {
    'natural': 0,
    'sharp': 1,
    'flat': -1,
    'double-sharp': 2,
    'sharp-sharp': 2,
    'double-flat': -2,
    'flat-flat': -2,
  };

  static const _naturalSemitone = {
    'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11,
  };
}
