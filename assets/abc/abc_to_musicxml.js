// abc_to_musicxml.js — DOM-free ABC -> MusicXML converter.
//
// Parses ABC with abcjs (ABCJS.parseOnly) and emits MusicXML (score-partwise).
// Engine-agnostic: no DOM, no browser APIs. Expects a global `ABCJS`.
// Exposes globalThis.abcToMusicXml(abcString) -> JSON string:
//   { ok: true, xml, title, warnings:[...] } | { ok:false, error, warnings:[...] }
(function (root) {
  'use strict';

  var STEPS = ['C', 'D', 'E', 'F', 'G', 'A', 'B'];

  // abcjs pitch: 0 = middle C (C4). Each unit is one diatonic step.
  function pitchToStepOctave(p) {
    var idx = ((p % 7) + 7) % 7;
    var octave = 4 + Math.floor(p / 7);
    return { step: STEPS[idx], octave: octave };
  }

  var ACC_ALTER = { dblflat: -2, flat: -1, natural: 0, sharp: 1, dblsharp: 2 };
  var ACC_NAME = { dblflat: 'double-flat', flat: 'flat', natural: 'natural', sharp: 'sharp', dblsharp: 'double-sharp' };

  // duration is a fraction of a whole note. Map to (type, dots).
  var DUR_TABLE = [
    [1, 'whole', 0], [0.75, 'half', 1], [0.5, 'half', 0], [0.375, 'quarter', 1],
    [0.25, 'quarter', 0], [0.1875, 'eighth', 1], [0.125, 'eighth', 0],
    [0.09375, '16th', 1], [0.0625, '16th', 0], [0.046875, '32nd', 1], [0.03125, '32nd', 0]
  ];
  function durationToType(f) {
    for (var i = 0; i < DUR_TABLE.length; i++) {
      if (Math.abs(f - DUR_TABLE[i][0]) < 1e-6) return { type: DUR_TABLE[i][1], dots: DUR_TABLE[i][2], exact: true };
    }
    // Non-standard (e.g. tuplet): pick nearest power-of-two note value.
    var nearest = DUR_TABLE[0], best = Infinity;
    for (var j = 0; j < DUR_TABLE.length; j++) {
      if (DUR_TABLE[j][2] !== 0) continue;
      var d = Math.abs(Math.log(f) - Math.log(DUR_TABLE[j][0]));
      if (d < best) { best = d; nearest = DUR_TABLE[j]; }
    }
    return { type: nearest[1], dots: 0, exact: false };
  }

  var DIVISIONS = 96; // per quarter note; whole note = 4 * DIVISIONS
  function xmlEscape(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  function keyToFifthsMode(key, warnings) {
    var fifths = 0;
    if (key && key.accidentals && key.accidentals.length) {
      var sharps = 0, flats = 0;
      for (var i = 0; i < key.accidentals.length; i++) {
        if (key.accidentals[i].acc === 'sharp') sharps++;
        else if (key.accidentals[i].acc === 'flat') flats++;
      }
      fifths = sharps > 0 ? sharps : -flats;
    }
    var m = (key && key.mode ? key.mode : '').toLowerCase();
    var mode = 'major';
    if (m === 'm' || m.indexOf('min') === 0 || m.indexOf('aeo') === 0) mode = 'minor';
    else if (m && m !== 'maj' && m.indexOf('ion') !== 0) {
      // Modal key (dorian/mixolydian/...): fifths from accidentals is still
      // correct; the app only renders major/minor, so approximate.
      warnings.push('modal key "' + m + '" rendered as major/minor');
    }
    return { fifths: fifths, mode: mode };
  }

  function meterToTime(meter) {
    if (!meter) return { beats: 4, beatType: 4 };
    if (meter.type === 'common_time') return { beats: 4, beatType: 4 };
    if (meter.type === 'cut_time') return { beats: 2, beatType: 2 };
    if (meter.type === 'specified' && meter.value && meter.value[0]) {
      return { beats: parseInt(meter.value[0].num, 10) || 4, beatType: parseInt(meter.value[0].den, 10) || 4 };
    }
    return { beats: 4, beatType: 4 };
  }

  function noteXml(el, warnings) {
    var dur = durationToType(el.duration);
    if (!dur.exact) warnings.push('non-standard duration ' + el.duration + ' approximated as ' + dur.type + ' (e.g. a tuplet; timing may be off)');
    var divisions = Math.round(el.duration * 4 * DIVISIONS);
    var dotsXml = '';
    for (var d = 0; d < dur.dots; d++) dotsXml += '<dot/>';

    var isRest = el.rest || !el.pitches || !el.pitches.length;
    if (isRest) {
      return '      <note><rest/><duration>' + divisions + '</duration><type>' + dur.type + '</type>' + dotsXml + '</note>\n';
    }
    // Chord/double-stop: emit the first pitch only (model is monophonic).
    if (el.pitches.length > 1) warnings.push('chord/double-stop reduced to a single note');
    var p = el.pitches[0];
    var so = pitchToStepOctave(p.pitch);
    var pitchXml = '<step>' + so.step + '</step>';
    var accXml = '';
    if (p.accidental && ACC_ALTER.hasOwnProperty(p.accidental)) {
      var alter = ACC_ALTER[p.accidental];
      if (alter !== 0) pitchXml += '<alter>' + alter + '</alter>';
      accXml = '<accidental>' + ACC_NAME[p.accidental] + '</accidental>';
    }
    pitchXml += '<octave>' + so.octave + '</octave>';
    return '      <note><pitch>' + pitchXml + '</pitch><duration>' + divisions +
      '</duration><type>' + dur.type + '</type>' + dotsXml + accXml + '</note>\n';
  }

  function convertTune(tune) {
    var warnings = [];
    var key = null, meter = null, sawMultiVoice = false;
    var elements = [];
    for (var li = 0; li < tune.lines.length; li++) {
      var staffArr = tune.lines[li].staff;
      if (!staffArr) continue;
      if (staffArr.length > 1) sawMultiVoice = true;
      var staff = staffArr[0];
      if (staff.key && !key) key = staff.key;
      if (staff.meter && !meter) meter = staff.meter;
      if (staff.voices) {
        if (staff.voices.length > 1) sawMultiVoice = true;
        if (staff.voices[0]) elements = elements.concat(staff.voices[0]);
      }
    }
    if (sawMultiVoice) warnings.push('multiple voices/staves; only the first is used');

    var km = keyToFifthsMode(key, warnings);
    var time = meterToTime(meter);

    // Split the element stream into measures on bar elements; carry repeats.
    var measures = [];
    var cur = { notes: '', repeatStart: false, repeatEnd: false };
    var pendingForwardRepeat = false;
    function flush() {
      cur.repeatStart = cur.repeatStart || pendingForwardRepeat;
      pendingForwardRepeat = false;
      measures.push(cur);
      cur = { notes: '', repeatStart: false, repeatEnd: false };
    }
    for (var ei = 0; ei < elements.length; ei++) {
      var el = elements[ei];
      if (el.el_type === 'note') {
        cur.notes += noteXml(el, warnings);
      } else if (el.el_type === 'bar') {
        var hasContent = cur.notes.length > 0;
        if (el.type === 'bar_right_repeat') cur.repeatEnd = true;
        if (hasContent) flush();
        if (el.type === 'bar_left_repeat') pendingForwardRepeat = true;
      }
      // ignore non-note/bar elements (chord symbols live on notes already)
    }
    if (cur.notes.length > 0) flush();

    // Build MusicXML. First (anacrusis) measure is numbered 1 and may be short;
    // the app treats a short first measure as a pickup.
    var out = '<?xml version="1.0" encoding="UTF-8"?>\n';
    out += '<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 3.1 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">\n';
    out += '<score-partwise version="3.1">\n';
    if (tune.metaText && tune.metaText.title) {
      out += '  <work><work-title>' + xmlEscape(tune.metaText.title) + '</work-title></work>\n';
    }
    out += '  <part-list><score-part id="P1"><part-name>Violin</part-name></score-part></part-list>\n';
    out += '  <part id="P1">\n';
    for (var mi = 0; mi < measures.length; mi++) {
      var m = measures[mi];
      var implicit = (mi === 0 && isShort(m, time)) ? ' implicit="yes"' : '';
      out += '    <measure number="' + (mi + 1) + '"' + implicit + '>\n';
      if (mi === 0) {
        out += '      <attributes>\n';
        out += '        <divisions>' + DIVISIONS + '</divisions>\n';
        out += '        <key><fifths>' + km.fifths + '</fifths><mode>' + km.mode + '</mode></key>\n';
        out += '        <time><beats>' + time.beats + '</beats><beat-type>' + time.beatType + '</beat-type></time>\n';
        out += '        <clef><sign>G</sign><line>2</line></clef>\n';
        out += '      </attributes>\n';
      }
      if (m.repeatStart) out += '      <barline location="left"><bar-style>heavy-light</bar-style><repeat direction="forward"/></barline>\n';
      out += m.notes;
      if (m.repeatEnd) out += '      <barline location="right"><bar-style>light-heavy</bar-style><repeat direction="backward"/></barline>\n';
      out += '    </measure>\n';
    }
    out += '  </part>\n</score-partwise>\n';
    return { xml: out, title: (tune.metaText && tune.metaText.title) || null, warnings: warnings };
  }

  // crude duration sum to detect a short pickup measure
  function isShort(measure, time) {
    var m = measure.notes.match(/<duration>(\d+)<\/duration>/g) || [];
    var total = 0;
    for (var i = 0; i < m.length; i++) total += parseInt(m[i].replace(/\D/g, ''), 10);
    var full = time.beats * (4 * DIVISIONS) / time.beatType;
    return total < full;
  }

  function abcToMusicXml(abc) {
    try {
      if (typeof ABCJS === 'undefined' || !ABCJS.parseOnly) {
        return JSON.stringify({ ok: false, error: 'abcjs (ABCJS.parseOnly) not loaded', warnings: [] });
      }
      var tunes = ABCJS.parseOnly(abc);
      if (!tunes || !tunes.length) return JSON.stringify({ ok: false, error: 'No tune found in the ABC input.', warnings: [] });
      var warnings = [];
      if (tunes.length > 1) warnings.push('multiple tunes found; only the first was imported');
      var res = convertTune(tunes[0]);
      warnings = warnings.concat(res.warnings);
      // de-dup warnings
      var seen = {}, uniq = [];
      for (var i = 0; i < warnings.length; i++) { if (!seen[warnings[i]]) { seen[warnings[i]] = 1; uniq.push(warnings[i]); } }
      return JSON.stringify({ ok: true, xml: res.xml, title: res.title, warnings: uniq });
    } catch (e) {
      return JSON.stringify({ ok: false, error: String(e && e.stack ? e.stack : e), warnings: [] });
    }
  }

  root.abcToMusicXml = abcToMusicXml;
})(typeof globalThis !== 'undefined' ? globalThis : this);
