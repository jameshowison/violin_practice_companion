/// What the piece list shows and filters on beyond a piece's title: its key,
/// time signature and composer.
///
/// Read from the score's HEADER only — the first `<key>`, `<time>` and
/// `<creator type="composer">` — with plain pattern matching over the text
/// before the first note, never a DOM parse. The list needs this for every
/// piece at once, and [MusicXmlParser.parse] is a full parse sized for the one
/// piece that is open.
library;

import '../services/musicxml_parser.dart';
import 'note_event.dart';

class PieceMeta {
  /// Short key name as [MusicXmlParser.keyName] spells it: `A`, `Dm`, `Gmix`.
  final String keyShort;

  /// Display key name: `A major`, `D minor`, `G mixolydian`.
  final String keyName;

  /// Signature as the child sees it on the staff: `3♯`, `1♭`, `no ♯/♭`.
  final String signature;

  /// `4/4`, `6/8`. Null when the score has no `<time>`.
  final String? time;

  /// From the score's `<creator type="composer">`, else the catalog's. Null
  /// when neither says.
  final String? composer;

  const PieceMeta({
    required this.keyShort,
    required this.keyName,
    required this.signature,
    this.time,
    this.composer,
  });

  /// Everything defaults rather than throws: a score with no `<key>` is C major
  /// (MusicXML's own default), one with no `<time>` has no time shown.
  /// [fallbackComposer] fills in when the score names none.
  factory PieceMeta.fromHeader(String xml, {String? fallbackComposer}) {
    final noteAt = xml.indexOf('<note');
    final head = noteAt < 0 ? xml : xml.substring(0, noteAt);

    final keyBlock = _first(head, _keyRe);
    final fifths = int.tryParse(_first(keyBlock ?? '', _fifthsRe) ?? '') ?? 0;
    final mode = MusicXmlParser.parseKeyMode(_first(keyBlock ?? '', _modeRe));

    final timeBlock = _first(head, _timeRe);
    final beats = _first(timeBlock ?? '', _beatsRe);
    final beatType = _first(timeBlock ?? '', _beatTypeRe);

    final composer = _first(head, _composerRe)?.trim();

    final short = MusicXmlParser.keyName(fifths, mode);
    return PieceMeta(
      keyShort: short,
      keyName: _longKeyName(short, mode),
      signature: signatureLabel(fifths),
      time: beats != null && beatType != null
          ? '${beats.trim()}/${beatType.trim()}'
          : null,
      composer: (composer != null && composer.isNotEmpty)
          ? _unescape(composer)
          : (fallbackComposer?.trim().isEmpty ?? true)
              ? null
              : fallbackComposer!.trim(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PieceMeta &&
      other.keyShort == keyShort &&
      other.keyName == keyName &&
      other.signature == signature &&
      other.time == time &&
      other.composer == composer;

  @override
  int get hashCode => Object.hash(keyShort, keyName, signature, time, composer);
}

/// What a Playful card's key chip says: the signature and the key, the mode
/// abbreviated (`3♯ A maj.`, `1♭ D min.`, `2♯ E dor.`); a key with no sharps
/// or flats just by name (`C maj.`).
String cardKeyLabel(PieceMeta m) {
  final [tonic, mode] = m.keyName.split(' ');
  final short = switch (mode) {
    'major' => 'maj.',
    'minor' => 'min.',
    _ => '${mode.substring(0, 3)}.',
  };
  final key = '$tonic $short';
  return m.signature.startsWith('no') ? key : '${m.signature} $key';
}

/// `3♯`, `1♭`, `no ♯/♭`.
String signatureLabel(int fifths) => fifths == 0
    ? 'no ♯/♭'
    : fifths > 0
        ? '$fifths♯'
        : '${-fifths}♭';

final _keyRe = RegExp(r'<key\b[^>]*>([\s\S]*?)</key>');
final _fifthsRe = RegExp(r'<fifths>\s*(-?\d+)\s*</fifths>');
final _modeRe = RegExp(r'<mode>([^<]*)</mode>');
final _timeRe = RegExp(r'<time\b[^>]*>([\s\S]*?)</time>');
final _beatsRe = RegExp(r'<beats>([^<]*)</beats>');
final _beatTypeRe = RegExp(r'<beat-type>([^<]*)</beat-type>');
final _composerRe =
    RegExp(r'''<creator\b[^>]*type\s*=\s*["']composer["'][^>]*>([^<]*)</creator>''');

String? _first(String text, RegExp re) => re.firstMatch(text)?.group(1);

const _modeWords = [
  'major', 'dorian', 'phrygian', 'lydian', 'mixolydian', 'minor', 'locrian',
];

/// `Am` + minor → `A minor`. The tonic is [short] with the mode suffix
/// stripped; [MusicXmlParser.keyName] appends at most a three-letter suffix
/// (or `m`) after a one- or two-character tonic.
String _longKeyName(String short, KeyMode mode) {
  final tonicLen =
      short.length > 1 && (short[1] == 'b' || short[1] == '#') ? 2 : 1;
  final tonic = short.substring(0, tonicLen.clamp(0, short.length))
      .replaceAll('#', '♯')
      .replaceAll('b', '♭');
  return '$tonic ${_modeWords[mode.index]}';
}

String _unescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'");
