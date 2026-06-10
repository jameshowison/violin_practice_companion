import { JSDOM } from 'jsdom';
import { readFileSync, writeFileSync } from 'fs';
import { createRequire } from 'module';
import { fileURLToPath } from 'url';
import path from 'path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, '..');

// --- Set up DOM globals BEFORE loading OSMD ---
const dom = new JSDOM('<!DOCTYPE html><html><body><div id="before"></div><div id="after"></div></body></html>', {
  pretendToBeVisual: true,
});
const { window } = dom;

// Patch every global OSMD touches
for (const key of [
  'window', 'document', 'HTMLElement', 'Element', 'Node',
  'Event', 'CustomEvent', 'MutationObserver', 'NodeList',
  'SVGElement', 'Image', 'XMLSerializer',
  'requestAnimationFrame', 'cancelAnimationFrame',
  'getComputedStyle', 'URL',
]) {
  const val = window[key];
  if (val !== undefined && !(key in global)) {
    try { global[key] = val; } catch (_) {}
  }
}
global.window = window;
global.document = window.document;
global.requestAnimationFrame = (cb) => setTimeout(cb, 16);
global.cancelAnimationFrame = clearTimeout;

// --- Now load OSMD (it will use the globals above) ---
const require = createRequire(import.meta.url);
const { OpenSheetMusicDisplay } = require('opensheetmusicdisplay');

const xml = readFileSync(path.join(root, 'assets/fixtures/lightly_row_musescore.xml'), 'utf8');

async function renderOne(containerId, applyTight) {
  const container = window.document.getElementById(containerId);
  container.innerHTML = '';

  const osmd = new OpenSheetMusicDisplay(container, {
    autoResize: false,
    drawTitle: false,
    drawSubtitle: false,
    drawPartNames: false,
    drawMeasureNumbers: false,
    newSystemFromXML: true,
    stretchLastSystemLine: true,
    backend: 'svg',
  });
  osmd.EngravingRules.RenderClefsAtBeginningOfStaffline = false;
  if (applyTight) {
    osmd.EngravingRules.MinSkyBottomDistBetweenSystems = 1.0;
  }

  await osmd.load(xml);
  osmd.render();

  const svg = container.querySelector('svg');
  if (!svg) throw new Error(`No SVG in #${containerId}`);
  return svg.outerHTML;
}

const beforeSvg = await renderOne('before', false);
const afterSvg  = await renderOne('after',  true);

const html = `<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>OSMD Spacing Comparison</title>
  <style>
    * { box-sizing: border-box; }
    body { margin: 0; font-family: sans-serif; background: #eee; }
    h1 { text-align: center; font-size: 14px; padding: 8px; margin: 0; background: #222; color: #fff; }
    .cols { display: flex; gap: 2px; }
    .col { flex: 1; background: #fff; overflow: hidden; }
    .label { padding: 6px 12px; background: #444; color: #fff; font-size: 12px; font-weight: bold; }
    .label em { font-weight: normal; opacity: .7; font-style: normal; }
    svg { width: 100% !important; height: auto !important; display: block; }
  </style>
</head>
<body>
<h1>OSMD Inter-Staff Spacing — Before vs After (Lightly Row)</h1>
<div class="cols">
  <div class="col">
    <div class="label">Before <em>(default — no MinSkyBottomDistBetweenSystems)</em></div>
    ${beforeSvg}
  </div>
  <div class="col">
    <div class="label">After <em>(MinSkyBottomDistBetweenSystems = 1.0)</em></div>
    ${afterSvg}
  </div>
</div>
</body>
</html>`;

const outPath = path.join(root, 'assets/osmd/spacing_comparison_rendered.html');
writeFileSync(outPath, html);
console.log('Written:', outPath);
