import 'package:xml/xml.dart';

/// Controls which lyrics (`<lyric>`) reach the engraver.
///
/// Lyrics are engraved by the renderer itself — Verovio maps MusicXML
/// `<lyric>` to `<verse>`/`<syl>` and lays out the syllables, hyphens and
/// extenders under the staff; OSMD draws them natively too — so there is no
/// Flutter lane and no glyph stripping. Showing a verse is "leave that one in";
/// the rest is [selectVerse]. Mirrors `ChordXmlInjector.stripHarmony`.
class LyricXmlInjector {
  /// Keeps only verse [verse]'s `<lyric>`s, renumbered as verse 1 so the
  /// engraver draws a single line directly under the staff whichever verse it
  /// is. A null [verse] strips every lyric.
  ///
  /// Returns [musicXml] untouched when it has no lyrics at all, which is most
  /// pieces — no parse/serialise round trip for them.
  static String selectVerse(String musicXml, int? verse) {
    if (!musicXml.contains('<lyric')) return musicXml;
    final doc = XmlDocument.parse(musicXml);
    for (final l in doc.findAllElements('lyric').toList()) {
      final n = int.tryParse(l.getAttribute('number') ?? '1') ?? 1;
      if (verse != null && n == verse) {
        l.setAttribute('number', '1');
      } else {
        l.parent?.children.remove(l);
      }
    }
    return doc.toXmlString();
  }
}
