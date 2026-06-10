'use strict';
const { JSDOM } = require('jsdom');
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');

// Set up DOM before loading OSMD
const dom = new JSDOM(
  '<!DOCTYPE html><html><body><div id="before"></div><div id="after"></div></body></html>',
  { pretendToBeVisual: true }
);
const { window } = dom;

global.window   = window;
global.document = window.document;
global.HTMLElement    = window.HTMLElement;
global.Element        = window.Element;
global.Node           = window.Node;
global.Event          = window.Event;
global.CustomEvent    = window.CustomEvent;
global.MutationObserver = window.MutationObserver;
global.DOMParser        = window.DOMParser;
global.XMLSerializer    = window.XMLSerializer;
global.requestAnimationFrame  = (cb) => setTimeout(cb, 16);
global.cancelAnimationFrame   = clearTimeout;

const { OpenSheetMusicDisplay } = require('opensheetmusicdisplay');

const xml = fs.readFileSync(
  path.join(root, 'assets/fixtures/lightly_row_musescore.xml'), 'utf8'
);

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
  if (applyTight) osmd.EngravingRules.MinSkyBottomDistBetweenSystems = 1.0;

  await osmd.load(xml);
  osmd.render();

  const svg = container.querySelector('svg');
  if (!svg) throw new Error(`No SVG found in #${containerId}`);
  return svg.outerHTML;
}

(async () => {
  try {
    console.log('Rendering before...');
    const beforeSvg = await renderOne('before', false);
    console.log('Rendering after...');
    const afterSvg  = await renderOne('after',  true);

    const html = `<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>OSMD Spacing Comparison</title>
  <style>
    * { box-sizing: border-box; }
    body { margin: 0; font-family: sans-serif; background: #ddd; }
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
    <div class="label">Before <em>(default)</em></div>
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
    fs.writeFileSync(outPath, html);
    console.log('Written:', outPath);
  } catch (e) {
    console.error('Error:', e.message);
    console.error(e.stack);
    process.exit(1);
  }
})();
