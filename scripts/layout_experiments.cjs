#!/usr/bin/env node
// Section-aware line-break experiments, headless (no simulator).
//
// Renders one MusicXML under several line-break / pickup treatments with the
// bundled Verovio toolkit and writes a single comparison HTML page, so a
// layout choice can be made by eye before any of it is built into the app.
//
//   node scripts/layout_experiments.cjs <piece.musicxml> <sections.json> <out.html> [notes.html]
//
// The XML transforms here mirror what the app does before an engrave
// (hide the opening clef/time, hide the clef/time Verovio would repeat at a
// break, `<print new-system>` at each break) and add the candidates under
// test. Staff size per variant is solved the way `staff_zoom.dart` does it:
// measure each bar's natural width from a one-line probe at scale 40, then
// pick the largest scale at which the widest planned line fits the width.
// Headless layout is only indicative (see CLAUDE.md) — confirm finalists on
// a device.

const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');
const vrv = require(path.join(__dirname, '..', 'web/verovio/verovio-toolkit-wasm.js'));

const [, , xmlPath, sectionsPath, outPath, notesPath] = process.argv;
if (!xmlPath || !sectionsPath || !outPath) {
  console.error('usage: layout_experiments.cjs <piece.musicxml> <sections.json> <out.html>');
  process.exit(2);
}

const { window } = new JSDOM('');
const parseXml = (s) => new window.DOMParser().parseFromString(s, 'application/xml');
const serialize = (d) => new window.XMLSerializer().serializeToString(d);

// ── Constants copied from lib/services/staff_zoom.dart ──────────────────────
const PROBE_SCALE = 40;
const FIT_SLACK = 1.05;
const MARGIN_UNITS = 100; // Verovio's default left + right page margins (50 each)
const minStaffScale = (shortestSidePx) => {
  const tablet = shortestSidePx >= 600;
  const mm = tablet ? 3.5 : 2.9;
  const ppi = tablet ? 132 : 153;
  return (mm / 25.4) * ppi * 100 / 72;
};
const WIDTHS = [
  { name: 'dev-iphone landscape', px: 706, shortest: 402 },
  { name: 'dev-iphone portrait', px: 358, shortest: 402 },
];

// ── XML helpers ─────────────────────────────────────────────────────────────
const kids = (el, name) => [...el.children].filter((c) => !name || c.tagName === name);
const kid = (el, name) => kids(el, name)[0];
const el = (doc, name, attrs = {}, children = []) => {
  const e = doc.createElement(name);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
  for (const c of children) e.appendChild(typeof c === 'string' ? doc.createTextNode(c) : c);
  return e;
};
const noteDur = (n) =>
  kid(n, 'chord') || kid(n, 'grace') ? 0 : Number(kid(n, 'duration')?.textContent ?? 0);
const measureDur = (m) => kids(m, 'note').reduce((s, n) => s + noteDur(n), 0);

function attrState(doc) {
  const first = kid(kid(doc.documentElement, 'part'), 'measure');
  const a = kid(first, 'attributes');
  const t = kid(a, 'time');
  const c = kid(a, 'clef');
  return {
    divisions: Number(kid(a, 'divisions').textContent),
    beats: Number(kid(t, 'beats').textContent),
    beatType: Number(kid(t, 'beat-type').textContent),
    sign: kid(c, 'sign').textContent,
    line: kid(c, 'line').textContent,
  };
}

/** `print-object="no"` on the opening clef/time — `hideFirstSystemPreamble`. */
function hideOpeningPreamble(doc) {
  const a = kid(kid(kid(doc.documentElement, 'part'), 'measure'), 'attributes');
  for (const name of ['clef', 'time']) kid(a, name)?.setAttribute('print-object', 'no');
}

/** `<print new-system>` + hidden clef/time at [m] — `_insertPrintBreak`/`_hidePreamble`. */
function breakBefore(doc, m, st) {
  m.insertBefore(el(doc, 'print', { 'new-system': 'yes' }), m.firstChild);
  let a = kid(m, 'attributes');
  if (!a) {
    a = el(doc, 'attributes');
    m.insertBefore(a, kid(m, 'print').nextSibling);
  }
  if (!kid(a, 'time'))
    a.appendChild(el(doc, 'time', { 'print-object': 'no' }, [
      el(doc, 'beats', {}, [String(st.beats)]),
      el(doc, 'beat-type', {}, [String(st.beatType)]),
    ]));
  if (!kid(a, 'clef'))
    a.appendChild(el(doc, 'clef', { 'print-object': 'no' }, [
      el(doc, 'sign', {}, [st.sign]),
      el(doc, 'line', {}, [st.line]),
    ]));
}

function stripLyrics(doc) {
  for (const l of [...doc.getElementsByTagName('lyric')]) l.remove();
}

/**
 * Splits measure [m] before its [noteIndex]-th note (rests counted, chord
 * members not). Non-note children (harmony, direction) go with the note that
 * follows them. The first half keeps the number; the second is `<n>b`,
 * implicit. A beam open across the split is closed/reopened; a lyric
 * extender in the first half's last note is dropped (Verovio would otherwise
 * run it on to the end of the piece). Returns the second half.
 */
function splitMeasure(doc, m, noteIndex, barStyle) {
  const second = el(doc, 'measure', { number: `${m.getAttribute('number')}b`, implicit: 'yes' });
  let seen = -1;
  let moving = false;
  for (const c of [...m.children]) {
    if (c.tagName === 'note' && !kid(c, 'chord')) seen++;
    if (!moving && seen === noteIndex) moving = true;
    if (moving) second.appendChild(c);
  }
  // Harmony/direction immediately preceding the split note belong to it.
  let prev = m.lastElementChild;
  while (prev && prev.tagName !== 'note') {
    const p = prev.previousElementSibling;
    second.insertBefore(prev, second.firstChild);
    prev = p;
  }
  const lastA = [...kids(m, 'note')].pop();
  const firstB = kid(second, 'note');
  const fixBeam = (n, v) => {
    const b = kid(n, 'beam');
    if (b && b.textContent === 'continue') b.textContent = v;
    if (b && v === 'end' && b.textContent === 'begin') b.remove();
    if (b && v === 'begin' && b.textContent === 'end') b.remove();
  };
  if (lastA) fixBeam(lastA, 'end');
  if (firstB) fixBeam(firstB, 'begin');
  for (const ext of lastA ? [...lastA.getElementsByTagName('extend')] : []) ext.remove();
  if (barStyle) {
    m.appendChild(el(doc, 'barline', { location: 'right' }, [el(doc, 'bar-style', {}, [barStyle])]));
  }
  m.parentNode.insertBefore(second, m.nextSibling);
  return second;
}

// ── Variants ────────────────────────────────────────────────────────────────
// A plan is a list of LINES; each line lists the measure numbers it holds
// (strings, since split halves are "9b"). Built from the section starts.

function sectionBars(doc, sections) {
  const st = attrState(doc);
  const full = (st.divisions * st.beats * 4) / st.beatType;
  const ms = kids(kid(doc.documentElement, 'part'), 'measure');
  const nums = ms.map((m) => Number(m.getAttribute('number')));
  const starts = [...sections].sort((a, b) => a.startMeasure - b.startMeasure);
  const lead = nums.filter((n) => n < starts[0].startMeasure);
  const secs = starts.map((s, i) => {
    const end = i + 1 < starts.length ? starts[i + 1].startMeasure : Infinity;
    return { label: s.label, bars: nums.filter((n) => n >= s.startMeasure && n < end) };
  });
  // Opening pickup duration → how much of each section's last bar is a lead-in.
  const openDur = measureDur(ms[0]) < full ? measureDur(ms[0]) : 0;
  return { lead, secs, openDur, full, ms, st };
}

/** Balanced split of [bars] into [k] lines, longer lines first. */
function balanced(bars, k) {
  const lines = [];
  let i = 0;
  for (let j = 0; j < k; j++) {
    const n = Math.ceil((bars.length - i) / (k - j));
    lines.push(bars.slice(i, i + n));
    i += n;
  }
  return lines.filter((l) => l.length);
}

/** Note index at which the trailing [dur] of measure [m] starts (−1 if none). */
function leadInIndex(m, dur) {
  if (!dur) return -1;
  const notes = kids(m, 'note').filter((n) => !kid(n, 'chord'));
  let t = measureDur(m);
  for (let i = notes.length - 1; i >= 0; i--) {
    t -= noteDur(notes[i]);
    if (measureDur(m) - t === dur) {
      // Skip a leading rest: the lead-in starts at the first sounding note.
      let j = i;
      while (j < notes.length && kid(notes[j], 'rest')) j++;
      return j < notes.length ? j : -1;
    }
    if (measureDur(m) - t > dur) return -1;
  }
  return -1;
}

function buildVariant(srcXml, sections, opts) {
  const doc = parseXml(srcXml);
  if (opts.noLyrics) stripLyrics(doc);
  for (const t of ['part-name', 'part-abbreviation'])
    for (const e of [...doc.getElementsByTagName(t)]) { e.textContent = ''; e.setAttribute('print-object', 'no'); }
  hideOpeningPreamble(doc);
  const { lead, secs, openDur, full, ms, st } = sectionBars(doc, sections);
  const byNum = new Map(ms.map((m) => [m.getAttribute('number'), m]));
  let breaks = []; // measure numbers (string) that start a new line
  let lineList = [];

  if (opts.kind === 'auto') {
    return { xml: serialize(doc), breaks: 'auto', lines: null };
  }
  if (opts.kind === 'tile') {
    // Today's locked mode: every section start breaks, then N per line —
    // so the opening pickup sits alone on line 1 (the bug being fixed).
    lineList = secs.flatMap((s) =>
      balanced(s.bars, Math.ceil(s.bars.length / opts.n)).map((l) => l.map(String)));
    if (lead.length) lineList.unshift(lead.map(String));
  } else {
    // Section-aware: k balanced lines per section; opening pickup joins line 1.
    for (const s of secs) {
      const ls = balanced(s.bars, opts.k);
      // Shift `opts.shift` bars from each line onto the start of the next.
      for (let j = 0; j + 1 < ls.length; j++)
        for (let t = 0; t < (opts.shift ?? 0); t++) ls[j + 1].unshift(ls[j].pop());
      lineList.push(...ls.map((l) => l.map(String)));
    }
    lineList[0] = [...lead.map(String), ...lineList[0]];
    if (opts.kind === 'split') {
      // Move each section's lead-in (the tail of the bar before it that
      // matches the opening pickup's length) onto the section's first line.
      for (let i = 1; i < secs.length; i++) {
        const prevLast = String(secs[i - 1].bars.at(-1));
        const m = byNum.get(prevLast);
        const idx = leadInIndex(m, openDur);
        if (idx <= 0) continue;
        splitMeasure(doc, m, idx, opts.barStyle);
        const firstLineOfSec = lineList.findIndex((l) => l.includes(String(secs[i].bars[0])));
        lineList[firstLineOfSec].unshift(`${prevLast}b`);
      }
    }
  }
  const allMs = kids(kid(doc.documentElement, 'part'), 'measure');
  const msByNum = new Map(allMs.map((m) => [m.getAttribute('number'), m]));
  for (const line of lineList.slice(1)) {
    breaks.push(line[0]);
    breakBefore(doc, msByNum.get(line[0]), st);
  }
  return { xml: serialize(doc), breaks: 'encoded', lines: lineList };
}

// ── Verovio ─────────────────────────────────────────────────────────────────
function ready() {
  return new Promise((r) => {
    const t = setInterval(() => {
      try {
        if (vrv.module.calledRun && vrv.module.cwrap('vrvToolkit_getVersion', 'string', [])) {
          clearInterval(t);
          r();
        }
      } catch (_) {}
    }, 20);
  });
}

let tk;
function render(xml, options) {
  tk.resetOptions(); // options are cumulative otherwise
  tk.setOptions({
    footer: 'none', header: 'none', svgViewBox: true, adjustPageHeight: true,
    pageHeight: 60000, mnumInterval: 0, ...options,
  });
  tk.loadData(xml);
  return tk.renderToSVG(1);
}

/** Natural width (MEI units at scale 100) of every measure, from a one-line probe. */
function measureWidths(xml) {
  const svg = render(xml.replace(/<print new-system="yes"\/>/g, ''), {
    scale: PROBE_SCALE, pageWidth: 100000, breaks: 'none',
  });
  // Each measure group draws its own five staff lines: "M x1 y L x2 y".
  const out = [];
  const re = /<g id="[^"]+" class="measure">[\s\S]*?<g id="[^"]+" class="staff">\s*<path d="M(\d+) \d+ L(\d+) \d+"/g;
  let m;
  while ((m = re.exec(svg))) out.push((Number(m[2]) - Number(m[1])) / 10); // SVG coords are 10× MEI units
  return out;
}

function solveScale(lines, widths, order, widthPx) {
  if (!lines) return null;
  const idx = new Map(order.map((n, i) => [n, i]));
  const widest = Math.max(...lines.map((l) => l.reduce((s, n) => s + widths[idx.get(n)], 0)));
  return Math.min(220, (widthPx * 100) / (widest * FIT_SLACK + MARGIN_UNITS));
}

// ── Main ────────────────────────────────────────────────────────────────────
(async () => {
  await ready();
  tk = new vrv.toolkit();
  const src = fs.readFileSync(xmlPath, 'utf8');
  const sections = JSON.parse(fs.readFileSync(sectionsPath, 'utf8')).sections;

  const variants = [
    { id: 'V3b-k2-shift', title: 'V3b · split bar, no barline, 2 lines per section, one bar moved from each first line to the second', kind: 'split', k: 2, shift: 1, barStyle: 'none' },
    { id: 'V3b-k2', title: 'V3b · split bar, no barline, 2 lines per section (balanced)', kind: 'split', k: 2, barStyle: 'none' },
    { id: 'V3b-k1', title: 'V3b · split bar, no barline, 1 line per section', kind: 'split', k: 1, barStyle: 'none' },
    { id: 'V3a-k1', title: 'V3a · split bar, dashed barline, 1 line per section', kind: 'split', k: 1, barStyle: 'dashed' },
    { id: 'V3a-k2', title: 'V3a · split bar, dashed barline, 2 lines per section', kind: 'split', k: 2, barStyle: 'dashed' },
    { id: 'V3c-k2', title: 'V3c · split bar, normal barline, 2 lines per section', kind: 'split', k: 2, barStyle: null },
    { id: 'V1-k1', title: 'V1 · downbeat lines, 1 line per section (pickup joins line 1)', kind: 'section', k: 1 },
    { id: 'V1-k2', title: 'V1 · downbeat lines, 2 lines per section', kind: 'section', k: 2 },
    { id: 'V1-k3', title: 'V1 · downbeat lines, 3 lines per section (3+3+2)', kind: 'section', k: 3 },
    { id: 'V0-auto', title: 'V0 · today, Auto (Verovio picks breaks)', kind: 'auto' },
    { id: 'V0-lock4', title: 'V0 · today, Locked at 4 (pickup m1 alone on line 1)', kind: 'tile', n: 4 },
  ];

  const blocks = [];
  for (const v of variants) {
    for (const lyrics of [true, false]) {
      const built = buildVariant(src, sections, { ...v, noLyrics: !lyrics });
      const order = kids(kid(parseXml(built.xml).documentElement, 'part'), 'measure')
        .map((m) => m.getAttribute('number'));
      const widths = measureWidths(built.xml);
      for (const w of WIDTHS) {
        let scale = solveScale(built.lines, widths, order, w.px);
        const minScale = minStaffScale(w.shortest);
        // Auto: the app's floor is the min staff size; use the probe scale's
        // fit at 4 bars as a stand-in for its solve.
        if (scale == null) scale = Math.max(minScale, (w.px * 100) / (4 * (widths.reduce((a, b) => a + b, 0) / widths.length) * FIT_SLACK + MARGIN_UNITS));
        const svg = render(built.xml, {
          scale: Math.round(scale),
          pageWidth: Math.round((w.px * 100) / scale),
          breaks: built.breaks,
        });
        const lineSummary = built.lines
          ? built.lines.map((l) => `${l[0]}–${l.at(-1)}`).join(' | ')
          : '(Verovio)';
        const tooSmall = scale < minScale;
        blocks.push({ v, lyrics, w, scale, minScale, tooSmall, svg, lineSummary });
        console.log(`${v.id.padEnd(8)} ${lyrics ? 'lyr' : '   '} ${w.name.padEnd(22)} scale=${scale.toFixed(1)}${tooSmall ? ' (< min ' + minScale.toFixed(1) + ')' : ''}  ${lineSummary}`);
      }
    }
  }

  const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  const notes = notesPath ? fs.readFileSync(notesPath, 'utf8') : '';
  const card = (b) => `<figure class="render">
<figcaption>${esc(b.w.name)} · ${b.w.px} pt · staff scale ${b.scale.toFixed(0)}${b.tooSmall ? ` <span class="warn">below the ${b.minScale.toFixed(0)} minimum</span>` : ''}</figcaption>
<div class="paper" style="max-width:${b.w.px}px">${b.svg.replace(/<svg ([^>]*?)width="[^"]*" height="[^"]*"/, '<svg $1').replace(/<svg /, '<svg class="score" ')}</div></figure>`;
  // Artifact-ready fragment: the publish step supplies doctype/head/body.
  const html = `<title>Gundagai Line Breaks</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=EB+Garamond:wght@500;600&family=IBM+Plex+Sans:wght@400;500&family=IBM+Plex+Mono&display=swap">
<style>
/* Layout: one reading column; each variant is a labelled band of engraved
   renders on paper cards, side by side where the screen allows. */
:root{
  --bg:#f3f4f1; --fg:#1f2321; --muted:#5e6661; --rule:#d5d9d3; --accent:#2f6b6e; --warn:#a4462c;
  --paper:#ffffff; --ink:#000000;
  --display:"EB Garamond",Garamond,"Times New Roman",serif;
  --body:"IBM Plex Sans",system-ui,-apple-system,sans-serif;
  --mono:"IBM Plex Mono",ui-monospace,Menlo,monospace;
}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
  --bg:#161a19; --fg:#e6e9e5; --muted:#9aa49e; --rule:#323a37; --accent:#7cb8bb; --warn:#e0896d; color-scheme:dark}}
:root[data-theme="dark"]{--bg:#161a19; --fg:#e6e9e5; --muted:#9aa49e; --rule:#323a37; --accent:#7cb8bb; --warn:#e0896d; color-scheme:dark}
body{background:var(--bg);color:var(--fg);font:15px/1.55 var(--body);padding-inline:16px;padding-block:24px 48px}
main{max-width:1180px;margin:0 auto;display:grid;gap:8px}
h1{font:600 2rem/1.15 var(--display);margin:0;text-wrap:balance}
h2{font:600 1.35rem/1.2 var(--display);margin:0;text-wrap:balance}
.lede{color:var(--muted);max-width:68ch;margin:0}
.notes{max-width:72ch}
.notes h3{font:600 .78rem/1 var(--body);letter-spacing:.08em;text-transform:uppercase;color:var(--accent);margin:20px 0 6px}
.notes p,.notes li{margin:0 0 6px}
code,.mono{font-family:var(--mono);font-size:.88em}
.toolbar{position:sticky;top:env(safe-area-inset-top,0px);z-index:2;background:var(--bg);border-bottom:1px solid var(--rule);
  padding-block:10px;display:flex;flex-wrap:wrap;gap:8px 14px;align-items:center}
.toolbar a{color:var(--accent);text-decoration:none;font:500 .82rem var(--mono)}
.toolbar a:hover,.toolbar a:focus-visible{text-decoration:underline}
.toolbar label{font-weight:500;display:flex;gap:6px;align-items:center;margin-right:8px}
.variant{border-top:1px solid var(--rule);padding-block:28px 8px;display:grid;gap:10px;scroll-margin-top:56px}
.tag{font:500 .8rem var(--mono);color:var(--accent);letter-spacing:.04em}
.lines{font:400 .82rem var(--mono);color:var(--muted);overflow-wrap:anywhere}
.renders{display:flex;flex-wrap:wrap;gap:20px;align-items:flex-start}
.render{margin:0;display:grid;gap:6px;min-width:0;flex:1 1 360px}
.render:first-child{flex-basis:600px}
figcaption{font-size:.8rem;color:var(--muted)}
.warn{color:var(--warn);font-weight:500}
.paper{background:var(--paper);border:1px solid var(--rule);border-radius:4px;padding:10px 6px}
.score{display:block;width:100%;height:auto;color:var(--ink)}
body.nolyr .lyr{display:none} body:not(.nolyr) .nol{display:none}
</style>
<main>
<h1>Along the Road to Gundagai: line breaks by section</h1>
<p class="lede">${esc(path.basename(xmlPath))} · sections ${sections.map((s) => s.label + ' at m' + s.startMeasure).join(', ')}. Each render solves its own staff size so the widest planned line fills the width, the way the app's auto zoom does. Rendered headlessly with the app's bundled Verovio: which bars share a line is exact, fine spacing may differ slightly on the device.</p>
<div class="notes">${notes}</div>
<nav class="toolbar" aria-label="Variants">
<label for="lyr"><input type="checkbox" id="lyr" checked> Lyrics</label>
${variants.map((v) => `<a href="#${v.id}">${v.id}</a>`).join('')}
</nav>
${variants.map((v) => `<section class="variant" id="${v.id}">
<div class="tag">${v.id}</div>
<h2>${esc(v.title.replace(/^V\w+ · /, ''))}</h2>
${[true, false].map((lyr) => `<div class="${lyr ? 'lyr' : 'nol'}">
<p class="lines">lines: ${esc(blocks.find((b) => b.v === v && b.lyrics === lyr).lineSummary)}</p>
<div class="renders">${blocks.filter((b) => b.v === v && b.lyrics === lyr).map(card).join('')}</div></div>`).join('')}
</section>`).join('')}
</main>
<script>
const cb=document.getElementById('lyr');
cb.addEventListener('change',()=>document.body.classList.toggle('nolyr',!cb.checked));
</script>`;
  fs.writeFileSync(outPath, html);
  console.log(`wrote ${outPath} (${(html.length / 1e6).toFixed(1)} MB)`);
})();
