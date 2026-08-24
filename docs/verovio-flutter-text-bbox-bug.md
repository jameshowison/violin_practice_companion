# verovio_flutter: hit-map bounding box for `<text>` is placed below the baseline

**Package:** `verovio_flutter` 0.3.1 (also present in 0.3.3 as far as the source shows)
**File:** `lib/src/hit_map/walker.dart`, `_handleText`
**Severity:** wrong geometry, silently — no exception, no warning
**Affects:** any `captureClasses` entry whose element contains a `<text>`, which
in Verovio's output means `harm`, `fing`, `dir`, `dynam`, `tempo`, `mNum`,
`label`, and every ancestor that unions them (`measure`, `staff`, `system`)

## Summary

`_handleText` builds the box as

```dart
final double x = _parseDouble(_attrValue(event.attributes, 'x'));
final double y = _parseDouble(_attrValue(event.attributes, 'y'));
final double rawFontSize = _parseDouble(_attrValue(event.attributes, 'font-size'));
final double fontSize = rawFontSize > 0.0 ? rawFontSize : 16.0;
final double estimatedWidth = _parseDouble(_attrValue(event.attributes, 'textLength'));
final double width = estimatedWidth > 0.0 ? estimatedWidth : fontSize;

_leafBuf[0] = x;
_leafBuf[1] = y;              // <- baseline used as the box's TOP
_leafBuf[2] = x + width;
_leafBuf[3] = y + fontSize;   // <- box extends DOWNWARD from the baseline
```

Two independent problems:

1. **`y` on `<text>` is the baseline, not the top edge.** Glyphs extend *upward*
   from the baseline by the ascent and only slightly below it by the descent. The
   box should be roughly `[y - ascent, y + descent]`; it is currently
   `[y, y + fontSize]`, i.e. almost entirely in the wrong place.

2. **`font-size` is read from the wrong element.** Verovio writes
   `font-size="0px"` on the `<text>` and puts the real size on a nested
   `<tspan>`. `rawFontSize` is therefore 0, so every text box falls back to
   `16.0` — in Verovio's `definition-scale` units, where a fingering digit is
   ~270 units tall and a chord symbol ~366. The fallback is roughly 20x too
   small.

## Reproduction

Verovio 6.2.0 emits its own bounding boxes when you set `svgBoundingBoxes: true`,
so its answer and the hit map's can be compared directly on one render. Engraving
`old_joe_clark.xml` with a `<fingering>` placeholder on every pitched note
(scale 76, `pageWidth` 1037, `spacingSystem` 4, `pageMarginTop` 50) gives, for a
fingering:

```xml
<g id="t1k6injx" class="fing">
  <text x="3433" y="665" text-anchor="middle" font-size="0px">
    <tspan id="u1msg082" class="text">
      <g id="bbox-u1msg082" class="text bounding-box">
        <rect x="3357" y="460" height="270" width="152" fill="transparent"/>
      </g>
      <tspan font-size="303px">0</tspan>
    </tspan>
  </text>
</g>
```

Verovio says the glyph occupies `y` 460..730 — 205 units **above** the baseline
of 665 and 65 below it. `_handleText` produces 665..681.

Driving `HitMapParser.parseSync` over the same page (bounding-box groups stripped
first, so the hit map sees what it normally sees) and comparing the union of
`measure` boxes per system against Verovio's own leaf boxes:

| system | Verovio's extent | hit map `measure` union | error at the top |
|--------|------------------|-------------------------|------------------|
| 0 | 38.0 .. 173.9 | 58.8 .. 165.4 | **+20.7 px** |
| 1 | 220.3 .. 355.5 | 240.8 .. 351.3 | **+20.6 px** |
| 2 | 401.8 .. 537.1 | 422.3 .. 535.1 | **+20.5 px** |

(viewBox px; one staff space is 13.94 here, so the error is **1.5 staff
spaces**.) The union's top lands exactly on the chord symbol's baseline, which is
the bug: the symbol's ink is a space and a half above that, and the union does
not contain it.

## Why it matters downstream

We use the `measure` union to work out how much vertical room sits between one
system's ink and the next system's annotations, in order to draw our own chord
and fingering rows in that gap. Because the measurement was short, the app
shrank those rows and then bought the space back by raising `spacingSystem`,
which added ~2 staff spaces of whitespace to every system on the page — 13% of
the page height on an iPad in portrait. Vertical space is the scarce resource
when the score is on a music stand.

We have worked around it by taking the extent from Verovio's own
`svgBoundingBoxes` output and stripping those groups before rendering
(`VerovioEngraver.systemInkBoxes`). That is a fine workaround but it doubles the
SVG size through the worker, and it does not help anyone using the hit map for
hit-testing an annotation — a tap lands 1.5 staff spaces below the glyph.

## Suggested fix

Resolve the font size from the nearest descendant `<tspan>` that carries one
(falling back to the CSS/`font-family` default rather than 16), and place the box
around the baseline instead of below it. Even a crude split — 0.75 of the size
above the baseline, 0.25 below — would be far closer than the current placement.
Better still, the `<tspan class="text">` subtree is where the real extent lives,
so walking into it and using Verovio's own numbers when
`svgBoundingBoxes` is on would be exact.

A smaller, separate nicety: `text-anchor="middle"` (which Verovio uses for
fingerings) is ignored, so the box is placed as if the anchor were `start` and is
horizontally off by half its width.

## Also worth knowing

Verovio only emits bounding boxes for **leaf** elements. The container groups
(`system`, `measure`, `layer`, and `harm`/`fing` themselves) are emitted as
empty `<g/>`. A consumer wanting a container's extent has to union the leaves
inside it. Verovio also emits no box for slurs or ties, so a union of leaves
understates the extent of a system carrying them.

---

*Measured with Verovio 6.2.0-43f8060 via `verovio-toolkit-wasm.js` and with
`verovio_flutter` 0.3.1's own `HitMapParser`, on Flutter 3.x / iOS simulator
(iPad Pro 11-inch M5, iPhone 17).*
