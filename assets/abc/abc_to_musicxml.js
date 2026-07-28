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

  // Beam levels (flags) for a note type: eighth=1, 16th=2, 32nd=3, else 0.
  var BEAM_FLAGS = { eighth: 1, '16th': 2, '32nd': 3 };
  function beamFlags(type) { return BEAM_FLAGS[type] || 0; }

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

  function noteXml(el, warnings, beamXml) {
    beamXml = beamXml || '';
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
      '</duration><type>' + dur.type + '</type>' + dotsXml + accXml + beamXml + '</note>\n';
  }

  // abcjs attaches guitar chords (ABC `"A"`, `"Bm"`, `"E7"`) to a note as
  // el.chord = [{name, position}]; position 'default' is the chord (other
  // positions are ^/_/</> text annotations). Emit the first as MusicXML
  // <harmony> so it survives to Verovio (chord symbols) and the parser.
  function chordHarmonyXml(el) {
    if (!el.chord || !el.chord.length) return '';
    var name = null;
    for (var i = 0; i < el.chord.length; i++) {
      var c = el.chord[i];
      if (c.position === undefined || c.position === 'default') { name = c.name; break; }
    }
    if (name == null) return '';
    return chordToHarmony(String(name).split('\n')[0]);
  }

  // Maps an ABC chord-quality suffix to a MusicXML <kind> value. Kept in sync
  // with MusicXmlParser._kindSuffix so names round-trip (kind → suffix → name).
  function qualityToKind(q) {
    q = (q || '').trim();
    var l = q.toLowerCase();
    if (l === '') return 'major';
    if (l === 'm' || l === 'min' || l === '-') return 'minor';
    if (l === 'dim' || q === '°' || l === 'o') return 'diminished';
    if (l === 'aug' || q === '+') return 'augmented';
    if (l === '7') return 'dominant';
    if (l === 'maj7' || q === 'M7' || l === 'major7') return 'major-seventh';
    if (l === 'm7' || l === 'min7' || l === '-7') return 'minor-seventh';
    if (l === 'dim7' || q === '°7') return 'diminished-seventh';
    if (l === 'm7b5' || q === 'ø') return 'half-diminished';
    if (l === '6') return 'major-sixth';
    if (l === 'm6' || l === 'min6') return 'minor-sixth';
    if (l === '9') return 'dominant-ninth';
    if (l === 'sus4' || l === 'sus') return 'suspended-fourth';
    if (l === 'sus2') return 'suspended-second';
    if (l === '5') return 'power';
    if (l[0] === 'm' && l.substring(0, 3) !== 'maj') return 'minor';
    return 'major';
  }

  function chordToHarmony(name) {
    if (!name) return '';
    var m = /^([A-Ga-g])([#b]*)(.*)$/.exec(name.trim());
    if (!m) return '';
    var step = m[1].toUpperCase();
    var alter = 0, i;
    for (i = 0; i < m[2].length; i++) alter += m[2].charAt(i) === '#' ? 1 : -1;
    var rest = m[3], bass = null;
    var slash = rest.indexOf('/');
    if (slash >= 0) { bass = rest.substring(slash + 1); rest = rest.substring(0, slash); }
    var xml = '      <harmony>\n        <root><root-step>' + step + '</root-step>';
    if (alter !== 0) xml += '<root-alter>' + alter + '</root-alter>';
    xml += '</root>\n        <kind>' + qualityToKind(rest) + '</kind>\n';
    var bm = bass ? /^([A-Ga-g])([#b]*)/.exec(bass) : null;
    if (bm) {
      var bstep = bm[1].toUpperCase(), balter = 0, j;
      for (j = 0; j < bm[2].length; j++) balter += bm[2].charAt(j) === '#' ? 1 : -1;
      xml += '        <bass><bass-step>' + bstep + '</bass-step>';
      if (balter !== 0) xml += '<bass-alter>' + balter + '</bass-alter>';
      xml += '</bass>\n';
    }
    xml += '        </harmony>\n';
    return xml;
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
    // abcjs marks beam groups on note elements via startBeam/endBeam. Track an
    // open group and emit MusicXML <beam> begin/continue/end so beamed notes
    // (eighths and shorter) render with beams instead of individual flags.
    var inBeam = false;
    for (var ei = 0; ei < elements.length; ei++) {
      var el = elements[ei];
      if (el.el_type === 'note') {
        var isRest = el.rest || !el.pitches || !el.pitches.length;
        var fl = isRest ? 0 : beamFlags(durationToType(el.duration).type);
        var state = null;
        if (fl > 0) {
          if (el.startBeam && !el.endBeam) { state = 'begin'; inBeam = true; }
          else if (inBeam && el.endBeam) { state = 'end'; inBeam = false; }
          else if (inBeam && !el.startBeam) { state = 'continue'; }
          else { inBeam = false; } // standalone beamable note, or lone group
        } else {
          inBeam = false; // quarter+ or rest breaks any open beam
        }
        var beamXml = '';
        if (state) {
          for (var lv = 1; lv <= fl; lv++) beamXml += '<beam number="' + lv + '">' + state + '</beam>';
        }
        cur.notes += chordHarmonyXml(el) + noteXml(el, warnings, beamXml);
      } else if (el.el_type === 'bar') {
        inBeam = false; // beams never cross a barline
        var hasContent = cur.notes.length > 0;
        // bar_dbl_repeat (`::` / `:||:`) closes one strain and opens the next.
        if (el.type === 'bar_right_repeat' || el.type === 'bar_dbl_repeat') cur.repeatEnd = true;
        if (hasContent) flush();
        if (el.type === 'bar_left_repeat' || el.type === 'bar_dbl_repeat') pendingForwardRepeat = true;
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

  // abcjs treats a blank line as end-of-tune, so a blank line right after the
  // K: header — or between strains — silently drops the music (abcjs yields a
  // tune with no staff lines). Within a single tune (first K: up to the next
  // X: or end) strip whitespace-only lines so those common authoring quirks
  // don't truncate the import.
  function stripBodyBlankLines(abc) {
    var lines = String(abc).split(/\r?\n/);
    var out = [], inBody = false;
    for (var i = 0; i < lines.length; i++) {
      var ln = lines[i];
      if (!inBody) {
        out.push(ln);
        if (/^\s*K:/i.test(ln)) inBody = true;
        continue;
      }
      if (/^\s*X:/i.test(ln)) { inBody = false; out.push(ln); continue; }
      if (/^\s*$/.test(ln)) continue; // drop blank body line
      out.push(ln);
    }
    return out.join('\n');
  }

  function abcToMusicXml(abc) {
    try {
      if (typeof ABCJS === 'undefined' || !ABCJS.parseOnly) {
        return JSON.stringify({ ok: false, error: 'abcjs (ABCJS.parseOnly) not loaded', warnings: [] });
      }
      var tunes = ABCJS.parseOnly(stripBodyBlankLines(abc));
      if (!tunes || !tunes.length) return JSON.stringify({ ok: false, error: 'No tune found in the ABC input.', warnings: [] });
      var warnings = [];
      if (tunes.length > 1) warnings.push('multiple tunes found; only the first was imported');
      var res = convertTune(tunes[0]);
      // Never hand back a music-less score — the app would spin on an empty
      // piece. Fail loudly with a hint about the most common cause.
      if (!/<measure\b/.test(res.xml)) {
        return JSON.stringify({ ok: false, error: 'No notes found in the ABC. Check the header — a blank line right after the K: line can end the tune before the music.', warnings: res.warnings || [] });
      }
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
