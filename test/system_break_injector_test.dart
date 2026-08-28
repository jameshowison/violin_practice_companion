import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:violin_practice_companion/models/section.dart';
import 'package:violin_practice_companion/services/system_break_injector.dart';

/// divisions=1, 4/4 ⇒ a full measure is 4 duration units. G-clef/2 sharps so
/// the hidden-preamble tests have something distinctive to check was carried.
const _attributes =
    '<attributes><divisions>1</divisions>'
    '<key><fifths>2</fifths></key>'
    '<time><beats>4</beats><beat-type>4</beat-type></time>'
    '<clef><sign>G</sign><line>2</line></clef></attributes>';

/// A single-note measure. [duration] < 4 is a pickup (short of a full bar);
/// [duration] == 4 is an ordinary full measure. [attributes] carries
/// divisions/time and belongs on the piece's first measure only (MusicXML
/// doesn't restate it unless it changes).
String _measure(String number, int duration, {bool attributes = false}) =>
    '<measure number="$number">'
    '${attributes ? _attributes : ''}'
    '<note><pitch><step>C</step><octave>4</octave></pitch>'
    '<duration>$duration</duration><type>quarter</type></note>'
    '</measure>';

String _score(List<String> measuresXml) =>
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<score-partwise version="3.1">'
    '<part-list><score-part id="P1"><part-name/></score-part></part-list>'
    '<part id="P1">${measuresXml.join()}</part>'
    '</score-partwise>';

/// The `<attributes>` element of `<measure number="$number">` in [xml], or
/// null if that measure has none.
XmlElement? _attributesOf(String xml, String number) {
  final measure = XmlDocument.parse(xml).findAllElements('measure').firstWhere(
        (m) => m.getAttribute('number') == number,
      );
  return measure.findElements('attributes').firstOrNull;
}

/// Measure numbers (in document order) that carry a leading
/// `<print new-system="yes"/>`.
List<String> _brokenMeasures(String xml) {
  final doc = XmlDocument.parse(xml);
  return [
    for (final m in doc.findAllElements('measure'))
      if (m.children.any((n) =>
          n is XmlElement &&
          n.name.local == 'print' &&
          n.getAttribute('new-system') == 'yes'))
        m.getAttribute('number')!,
  ];
}

void main() {
  test('no sections: breaks land every N measures, not on measure 1', () {
    final xml = _score([
      _measure('1', 4, attributes: true),
      for (var n = 2; n <= 10; n++) _measure('$n', 4),
    ]);
    final out = insertSystemBreaks(xml, measuresPerLine: 4, sections: const []);

    expect(_brokenMeasures(out), ['5', '9']);
  });

  test('an ordinary (non-pickup) full-duration first measure counts normally',
      () {
    final xml = _score([
      _measure('1', 4, attributes: true),
      for (var n = 2; n <= 5; n++) _measure('$n', 4),
    ]);
    final out = insertSystemBreaks(xml, measuresPerLine: 4, sections: const []);

    expect(_brokenMeasures(out), ['5']);
  });

  test('a short first measure rides free, regardless of implicit', () {
    final xml = _score([
      _measure('1', 1, attributes: true), // 1 of 4 — a pickup, no attribute
      for (var n = 2; n <= 9; n++) _measure('$n', 4),
    ]);
    final out = insertSystemBreaks(xml, measuresPerLine: 4, sections: const []);

    // Pickup(1) + 2,3,4,5 free on line 1, then 6,7,8,9.
    expect(_brokenMeasures(out), ['6']);
  });

  test('a short measure mid-piece also rides free, deferring the budget break',
      () {
    final xml = _score([
      _measure('1', 4, attributes: true),
      _measure('2', 4),
      _measure('3', 4),
      _measure('4', 4),
      _measure('5', 1), // budget hits exactly here — must not isolate it
      _measure('6', 4),
    ]);
    final out = insertSystemBreaks(xml, measuresPerLine: 4, sections: const []);

    // Line 1 keeps 1,2,3,4 plus the free measure 5; the break lands on 6.
    expect(_brokenMeasures(out), ['6']);
  });

  test('a section start forces a break even onto a short measure', () {
    final xml = _score([
      _measure('1', 4, attributes: true),
      _measure('2', 4),
      _measure('3', 4),
      _measure('4', 4),
      _measure('5', 1), // section B's pickup — still forces its own line
      _measure('6', 4),
      _measure('7', 4),
      _measure('8', 4),
    ]);
    const sections = [
      Section(label: 'A', startMeasure: 1),
      Section(label: 'B', startMeasure: 5),
    ];
    final out =
        insertSystemBreaks(xml, measuresPerLine: 4, sections: sections);

    expect(_brokenMeasures(out), ['5']);
  });

  test(
      'Old Joe Clark\'s actual shape: pickups at 1, 10 and 18, section at 10, '
      'no orphan line', () {
    final xml = _score([
      _measure('1', 1, attributes: true), // pickup: opening the piece
      for (var n = 2; n <= 9; n++) _measure('$n', 4),
      _measure('10', 1), // pickup: opening section B, NOT flagged implicit
      for (var n = 11; n <= 17; n++) _measure('$n', 4),
      _measure('18', 3), // the complementary partial bar closing the repeat
    ]);
    const sections = [
      Section(label: 'A', startMeasure: 1),
      Section(label: 'B', startMeasure: 10),
    ];

    final out =
        insertSystemBreaks(xml, measuresPerLine: 4, sections: sections);

    // {1(free),2,3,4,5} / {6,7,8,9} / {10(free),11,12,13,14} / {15,16,17,18(free)}
    // — no line is ever a single stranded measure.
    expect(_brokenMeasures(out), ['6', '10', '15']);
  });

  test('every part gets the same break points', () {
    final measuresXml = [
      _measure('1', 4, attributes: true),
      for (var n = 2; n <= 5; n++) _measure('$n', 4),
    ];
    final doc = XmlDocument.parse(_score(measuresXml));
    final partList = doc.findAllElements('part-list').first;
    partList.children.add(
      XmlDocument.parse('<score-part id="P2"><part-name/></score-part>')
          .rootElement
          .copy(),
    );
    final secondPart =
        XmlDocument.parse(_score(measuresXml)).findAllElements('part').first
            .copy()
          ..setAttribute('id', 'P2');
    doc.rootElement.children.add(secondPart);
    final xml = doc.toXmlString();

    final out = insertSystemBreaks(xml, measuresPerLine: 4, sections: const []);
    final parts = XmlDocument.parse(out).findAllElements('part');
    for (final part in parts) {
      final brokenInPart = [
        for (final m in part.findElements('measure'))
          if (m.children.any((n) =>
              n is XmlElement &&
              n.name.local == 'print' &&
              n.getAttribute('new-system') == 'yes'))
            m.getAttribute('number')!,
      ];
      expect(brokenInPart, ['5']);
    }
  });

  test('inserts exactly one <print> per break point, none elsewhere', () {
    final xml = _score([
      _measure('1', 4, attributes: true),
      for (var n = 2; n <= 5; n++) _measure('$n', 4),
    ]);
    final out = insertSystemBreaks(xml, measuresPerLine: 4, sections: const []);
    final doc = XmlDocument.parse(out);

    expect(doc.findAllElements('print').length, 1);
  });

  group('hidden preamble at each break', () {
    test('a break-forced measure with no attributes gets a hidden '
        'clef/key/time block carrying the inherited values', () {
      final xml = _score([
        _measure('1', 4, attributes: true),
        for (var n = 2; n <= 10; n++) _measure('$n', 4),
      ]);
      final out =
          insertSystemBreaks(xml, measuresPerLine: 4, sections: const []);

      for (final number in ['5', '9']) {
        final attributes = _attributesOf(out, number)!;
        final clef = attributes.findElements('clef').single;
        final key = attributes.findElements('key').single;
        final time = attributes.findElements('time').single;
        expect(clef.getAttribute('print-object'), 'no');
        expect(clef.findElements('sign').single.innerText, 'G');
        expect(clef.findElements('line').single.innerText, '2');
        expect(key.getAttribute('print-object'), 'no');
        expect(key.findElements('fifths').single.innerText, '2');
        expect(time.getAttribute('print-object'), 'no');
        expect(time.findElements('beats').single.innerText, '4');
      }
    });

    test('a genuine meter change at a break stays visible; only clef/key '
        'get hidden', () {
      final xml = _score([
        _measure('1', 4, attributes: true),
        _measure('2', 4),
        _measure('3', 4),
        _measure('4', 4),
        // Measure 5 is the natural break point AND states its own real time
        // change — this must stay visible, unlike an injected one.
        '<measure number="5">'
            '<attributes><time><beats>3</beats><beat-type>4</beat-type>'
            '</time></attributes>'
            '<note><pitch><step>C</step><octave>4</octave></pitch>'
            '<duration>3</duration><type>quarter</type></note>'
            '</measure>',
      ]);
      final out =
          insertSystemBreaks(xml, measuresPerLine: 4, sections: const []);

      final attributes = _attributesOf(out, '5')!;
      final time = attributes.findElements('time').single;
      expect(time.getAttribute('print-object'), isNull,
          reason: 'a real meter change must stay visible');
      expect(time.findElements('beats').single.innerText, '3');
      final clef = attributes.findElements('clef').single;
      final key = attributes.findElements('key').single;
      expect(clef.getAttribute('print-object'), 'no');
      expect(key.getAttribute('print-object'), 'no');
    });

    test('no spurious attributes block on non-break measures', () {
      final xml = _score([
        _measure('1', 4, attributes: true),
        for (var n = 2; n <= 5; n++) _measure('$n', 4),
      ]);
      final out =
          insertSystemBreaks(xml, measuresPerLine: 4, sections: const []);

      for (final number in ['2', '3', '4']) {
        expect(_attributesOf(out, number), isNull);
      }
    });
  });

  group('freezeSystemBreaks (auto mode)', () {
    test('inserts breaks only at the given measure numbers, with a hidden '
        'preamble carrying the inherited values', () {
      final xml = _score([
        _measure('1', 4, attributes: true),
        for (var n = 2; n <= 9; n++) _measure('$n', 4),
      ]);
      final out = freezeSystemBreaks(xml, {5, 8});

      expect(_brokenMeasures(out), ['5', '8']);
      for (final number in ['5', '8']) {
        final attributes = _attributesOf(out, number)!;
        expect(attributes.findElements('clef').single.getAttribute('print-object'), 'no');
        expect(attributes.findElements('key').single.getAttribute('print-object'), 'no');
        expect(attributes.findElements('time').single.getAttribute('print-object'), 'no');
      }
      for (final number in ['2', '3', '4', '6', '7', '9']) {
        expect(_attributesOf(out, number), isNull);
      }
    });

    test('never breaks at the piece\'s own first measure even if requested',
        () {
      final xml = _score([
        _measure('1', 4, attributes: true),
        _measure('2', 4),
        _measure('3', 4),
      ]);
      final out = freezeSystemBreaks(xml, {1, 3});

      expect(_brokenMeasures(out), ['3']);
    });

    test('an empty set of break numbers is a no-op', () {
      final xml = _score([
        _measure('1', 4, attributes: true),
        _measure('2', 4),
      ]);
      final out = freezeSystemBreaks(xml, const {});

      expect(_brokenMeasures(out), isEmpty);
      expect(XmlDocument.parse(out).findAllElements('print'), isEmpty);
    });

    test('every part gets the same frozen break points', () {
      final measuresXml = [
        _measure('1', 4, attributes: true),
        for (var n = 2; n <= 5; n++) _measure('$n', 4),
      ];
      final doc = XmlDocument.parse(_score(measuresXml));
      final partList = doc.findAllElements('part-list').first;
      partList.children.add(
        XmlDocument.parse('<score-part id="P2"><part-name/></score-part>')
            .rootElement
            .copy(),
      );
      final secondPart =
          XmlDocument.parse(_score(measuresXml)).findAllElements('part').first
              .copy()
            ..setAttribute('id', 'P2');
      doc.rootElement.children.add(secondPart);

      final out = freezeSystemBreaks(doc.toXmlString(), {4});
      final parts = XmlDocument.parse(out).findAllElements('part');
      for (final part in parts) {
        final broken = [
          for (final m in part.findElements('measure'))
            if (m.children.any((n) =>
                n is XmlElement &&
                n.name.local == 'print' &&
                n.getAttribute('new-system') == 'yes'))
              m.getAttribute('number')!,
        ];
        expect(broken, ['4']);
      }
    });
  });
}
