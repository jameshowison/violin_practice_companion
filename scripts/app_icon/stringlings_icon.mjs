// Stringlings app icon — the source of truth for every launcher icon.
//
// Two stringlings peek over a red A-string and a yellow E-string fingering rule
// (the app's underline annotation style, G green / D blue / A red / E yellow),
// above a three-note phrase on a staff: D5 on the 4th line, C5 in the space
// below, F#5 on the top line. The heads are deliberately bigger than a staff
// space — looser than real notation, but it reads at 29 pt.
//
// Tuned by eye in the icon-tuner page on 2026-11-12:
//   note size 73 · staff firmness 59 · stem nudge 2.5 · stem start 11 ·
//   background paper · ink auto
//
// Usage: node scripts/app_icon/stringlings_icon.mjs <full|fg|bg> > out.html
//   full — the whole icon on its paper background (iOS, Android legacy)
//   fg   — Android adaptive foreground: notes and stringlings on transparent,
//          shrunk into the 66 dp safe zone of the 108 dp layer
//   bg   — Android adaptive background: paper plus the staff lines, edge to edge
// Prints an HTML page holding a 1024×1024 SVG; scripts/gen_app_icons.sh
// screenshots it with headless Chrome. No SVG/PNG is committed outside the
// platform icon folders (test/repo_content_policy_test.dart).

const P = {
  size: 73, firm: 59, nudge: 2.5, top: 11,
  bg1: '#FFF9EE', bg2: '#F2E5CE', ink: '#2B2340', eyeWhite: '#FFFFFF',
  ruleA: '#C62828', ruleE: '#C9961C', // E yellow darkened for a light ground
};
const STAFF = [500, 596, 692, 788, 884];
const HEADS = [[235, 596], [505, 644], [790, 500]];

let uid = 0;
const rule = (x1, x2, y, h, c) =>
  `<rect x="${x1}" y="${y - h / 2}" width="${x2 - x1}" height="${h}" rx="${h / 2}" fill="${c}"/>`;

function note(x, y, r, stemLen) {
  const rx = r * 1.32, sw = Math.max(10, r * 0.27), sx = x - rx * 0.9 + P.nudge;
  const y0 = y + r * (P.top / 100);
  return `<ellipse cx="${x}" cy="${y}" rx="${rx}" ry="${r}" transform="rotate(-20 ${x} ${y})" fill="${P.ink}"/>
    <rect x="${sx - sw / 2}" y="${y0}" width="${sw}" height="${stemLen + (y + r * 0.2 - y0)}" rx="${sw / 2}" fill="${P.ink}"/>`;
}

// Every eye drawn, recorded so the app's launch splash can blink them
// (variant `dart`). With drawEyes off they are recorded but not drawn.
const EYES = [];
let drawEyes = true;
function eyes(cx, dx, ey, ew, eh, rx, pr) {
  let out = '';
  for (const sx of [cx - dx, cx + dx]) {
    const px = sx + rx * 0.03, py = ey + eh * 0.42;
    EYES.push({ cx: sx, cy: ey, rx: ew, ry: eh, px, py, pr });
    if (drawEyes) out += `<ellipse cx="${sx}" cy="${ey}" rx="${ew}" ry="${eh}" fill="${P.eyeWhite}"/><circle cx="${px}" cy="${py}" r="${pr}" fill="${P.ink}"/>`;
  }
  return out;
}

function peeker(cx, ruleY, h, rx, ry, ruleC, x1, x2) {
  const id = 'c' + (uid++), top = ruleY - h / 2, cy = ruleY - ry * 0.45;
  const ey = cy - ry * 0.22, dx = rx * 0.34, ew = rx * 0.22, eh = ry * 0.3, pr = rx * 0.12;
  const fw = Math.max(14, rx * 0.12), fingers = [];
  for (const hx of [cx - rx * 0.78, cx + rx * 0.78])
    for (const k of [-1, 0, 1])
      fingers.push(`<rect x="${hx + k * fw * 1.15 - fw / 2}" y="${top - fw * 0.55}" width="${fw}" height="${h * 0.75 + fw * 0.55}" rx="${fw / 2}" fill="${P.ink}"/>`);
  return `<clipPath id="${id}"><rect x="0" y="-100" width="1024" height="${top + 101}"/></clipPath>
    <g clip-path="url(#${id})"><ellipse cx="${cx}" cy="${cy}" rx="${rx}" ry="${ry}" fill="${P.ink}"/>
      ${eyes(cx, dx, ey, ew, eh, rx, pr)}</g>
    ${rule(x1, x2, ruleY, h, ruleC)}${fingers.join('')}`;
}

const background = () =>
  `<defs><linearGradient id="paper" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${P.bg1}"/><stop offset="1" stop-color="${P.bg2}"/></linearGradient></defs>
  <rect width="1024" height="1024" fill="url(#paper)"/>`;

// Firmness 0–100 → line opacity 0.05–0.87 and width 8–22 (as in the tuner).
// Lines run past both edges so any mask or scaling leaves no gap.
function staffLines(ys, x1 = -200, x2 = 1224) {
  const op = 0.05 + P.firm / 100 * 0.82, lw = 8 + P.firm / 100 * 14;
  return `<g stroke="${P.ink}" stroke-width="${lw.toFixed(1)}" opacity="${op.toFixed(2)}">${ys
    .map(y => `<line x1="${x1}" y1="${y}" x2="${x2}" y2="${y}"/>`).join('')}</g>`;
}

function figures() {
  const stem = Math.round(240 * P.size / 64);
  return `${peeker(370, 400, 40, 140, 122, P.ruleA, 130, 610)}
    ${peeker(795, 318, 34, 92, 80, P.ruleE, 680, 910)}
    ${HEADS.map(([x, y]) => note(x, y, P.size, stem)).join('')}`;
}

// Android's adaptive layers are 108 dp, of which a launcher may show as little
// as the central 66 dp circle. The art spans ~x 130–910, so it is shrunk about
// the centre until that span fits inside the safe circle.
const ANDROID_SCALE = 0.68;
const scaled = (inner) =>
  `<g transform="translate(512 512) scale(${ANDROID_SCALE}) translate(-512 -512)">${inner}</g>`;

const variant = process.argv[2] || 'full';
const svg = (body, size = 1024) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 1024 1024">${body}</svg>`;
const page = (inner, extraCss = '') => `<!doctype html><meta charset="utf-8">
<style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}svg{display:block}${extraCss}</style>
${inner}
`;
const fullBody = () => background() + staffLines(STAFF) + figures();

// The launch screen shows the icon at LAUNCH_PT points, as a rounded tile with a
// soft shadow, centred in a LAUNCH_BOX-point image. lib/ui/splash/launch_splash.dart
// draws the same tile at the same size so the hand-over to Flutter doesn't jump.
const LAUNCH_PT = 160, LAUNCH_BOX = 200;

if (variant === 'full') process.stdout.write(page(svg(fullBody())));
else if (variant === 'fg') process.stdout.write(page(svg(scaled(figures()))));
// Scaled with the foreground so line weight and spacing match; drawn long enough
// to still reach both edges after the shrink.
else if (variant === 'bg') process.stdout.write(page(svg(background() + scaled(staffLines(STAFF, -1200, 2224)))));
else if (variant === 'launch') process.stdout.write(page(
  `<div class="tile">${svg(fullBody(), LAUNCH_PT)}</div>`,
  `html,body{width:${LAUNCH_BOX}px;height:${LAUNCH_BOX}px}
   .tile{position:absolute;left:${(LAUNCH_BOX - LAUNCH_PT) / 2}px;top:${(LAUNCH_BOX - LAUNCH_PT) / 2}px;width:${LAUNCH_PT}px;height:${LAUNCH_PT}px;
     border-radius:22.37%;overflow:hidden;box-shadow:0 6px 18px rgba(43,35,64,.18)}`));
else if (variant === 'dart') {
  drawEyes = false;
  const base = svg(fullBody());
  const r = (n) => +n.toFixed(2);
  const hex = (c) => '0xFF' + c.slice(1).toUpperCase();
  process.stdout.write(`// GENERATED by scripts/gen_app_icons.sh from scripts/app_icon/stringlings_icon.mjs.
// Do not edit by hand: change the .mjs and regenerate.

import 'dart:ui' show Color;

/// The app icon without its eyes, as SVG in a 1024×1024 viewBox.
const kStringlingsIconSvg = r'''${base}''';

/// Size of the launch tile, in logical pixels, matching the native launch image.
const double kLaunchTileSize = ${LAUNCH_PT};

const kStringlingsEyeWhite = Color(${hex(P.eyeWhite)});
const kStringlingsPupil = Color(${hex(P.ink)});

/// The eyes, in the same 1024 space: (eye cx, cy, rx, ry, pupil cx, cy, r).
/// The first two belong to the big stringling, the last two to the little one.
const kStringlingsEyes = <List<double>>[
${EYES.map(e => `  [${[e.cx, e.cy, e.rx, e.ry, e.px, e.py, e.pr].map(r).join(', ')}],`).join('\n')}
];
`);
}
else { console.error(`unknown variant ${variant}`); process.exit(2); }
