# UX Improvements Plan

Issues raised after first real-device testing (iPhone SE 2022, Dynamic Island landscape work).
Split into three independent tracks ordered by payoff/dependency.

---

## Track A — Auto-scroll to active measure

**Problem:** During playback, the highlighted measure can be off-screen. The user has to scroll manually to follow along.

**Current state:** `JianpuView` and `FingeringView` both use a bare `SingleChildScrollView` with no `ScrollController`. Active-note state is per-note via `ValueNotifier<int?>` returned by `notifierForMeasure(measureNumber)`. The playback service already exposes `service.currentMeasureNotifier` (`ValueListenable<int?>`) used by `MeasureSelector`.

**Proposed approach — calculated-position scroll (no GlobalKeys needed):**

1. Add `ValueListenable<int?>? currentMeasureNotifier` parameter to `JianpuView` (and `FingeringView`).
2. Create a `ScrollController` inside the view's `LayoutBuilder`/`StatefulWidget`.
3. Add a listener on `currentMeasureNotifier`; when it fires with a non-null measure number:
   - Find which row index contains that measure: `layout.rows.indexWhere((r) => r.any((m) => m.number == activeMeasure))`
   - Calculate that row's Y offset: `rowIndex * rowHeightPx` where `rowHeightPx = (NotationLayout.rowHeight + labelHeight) * scale + 8` (8 = vertical padding × 2).
   - Call `scrollController.animateTo(offset, duration: 200ms, curve: Curves.easeOut)`, clamped to max scroll extent.
4. Wire up: in `piece_detail_screen.dart → _buildNotationView`, pass `service.currentMeasureNotifier` to both views.

**Experiments to try (in order):**
- A1: Basic scroll-to-row-top when measure changes.
- A2: Scroll to keep row *centred* in the viewport (offset - viewportHeight/2).
- A3: Only scroll if the row is already outside the viewport (avoid jarring scroll when it's already visible).

A3 is the target UX. Start with A1 to validate the position calculation, then refine.

**Files:** `lib/widgets/jianpu_view.dart`, `lib/widgets/fingering_view.dart`, `lib/screens/piece_detail_screen.dart`

---

## Track B — iPhone SE compact layout (more music, less chrome)

**Problem:** On the SE (375×667pt, smallest current iPhone), the non-music chrome consumes ~90pt at rest before even opening controls:
- AppBar: ~56pt
- `_CompactModeSwitcher` tab bar: 36pt
- Bottom sheet pill + mini-bar: 54pt

That leaves only ~520pt of music height in portrait. The user wants to prioritise the score.

**Sub-tasks (implement in order — each is independent):**

### B1 — Shrink the AppBar title
Use a compact AppBar with `toolbarHeight: 36` and a smaller title font (`fontSize: 14`). The back arrow and settings icon scale automatically. Saves ~20pt.

File: `lib/screens/piece_detail_screen.dart` — the `AppBar(...)` widget in `PieceDetailScreen.build`.

### B2 — Move the viz selector into the bottom sheet
Remove `_CompactModeSwitcher` from the top of the body and add it as the first row inside the bottom sheet (above or below the drag handle). The selector is only needed when the user opens controls — during practice they've already chosen a view.

This saves 36pt of music height. The `_CompactModeSwitcher` widget is self-contained and can move without changes to its internals.

File: `lib/screens/piece_detail_screen.dart` — `_CompactPieceLayoutState.build()` around lines 358–395 (mode bar) and 398–490 (bottom sheet column).

### B3 — Bottom sheet defaults to pill-only (no mini-bar at rest)
Currently the bottom sheet always shows a 44pt mini-bar (play/pause + section label + Controls button). Change the rest state to show **only** the drag-handle pill (8pt + 4pt + 4pt ≈ 16pt). The mini-bar slides up when:
- The user drags up (existing gesture), OR
- Playback starts (auto-peek the mini-bar for ~2s to teach the gesture, then retract).

The `_sheetOpen` bool becomes a tri-state or a second bool `_miniBarVisible` is added.

File: `lib/screens/piece_detail_screen.dart` — `_CompactPieceLayoutState`.

---

## Track C — Measure selection UX

**Problem:** Two issues:
1. **Discoverability** — there's no visual cue that measures are tappable/selectable.
2. **Range selection** — tapping sets `startMeasure == endMeasure` (single measure). The user needs to be able to select a contiguous range (start…end).

**Current state:** `MeasureSelection` already holds `startMeasure` + `endMeasure` (inclusive). `SectionBar` can set a multi-measure range. `_toggleMeasure` in `piece_detail_screen.dart` only ever creates single-measure selections. Tap handlers exist in `_JianpuMeasure` and `_FingeringMeasure`.

### C1 — Discoverability: subtle tap affordance
Add a very light grey background (`Colors.grey.shade100`) to each measure container permanently (currently background is null/transparent when unselected). On tap, the measure briefly flashes the `primaryContainer` colour before settling into the selected highlight. This signals "these are interactive."

### C2 — Range selection interaction
New tap logic in `_toggleMeasure`:

```
No selection       → tap M  → select {M..M}  (single, as today)
{S..S} selected    → tap M (M != S) → extend to {min(S,M)..max(S,M)}
{S..E} range sel.  → tap M inside range → clear
{S..E} range sel.  → tap M outside range → start new {M..M}
```

Visual hint: when exactly one measure is selected, show a small "drag to extend" label or arrow icon at the right edge of the selected measure. This can be a simple `Text('→', style: TextStyle(fontSize: 9, color: Colors.blueGrey))` overlay.

Files: `lib/screens/piece_detail_screen.dart` (`_toggleMeasure`), `lib/widgets/jianpu_view.dart` and `lib/widgets/fingering_view.dart` (measure container background).

---

## Suggested implementation order

| Order | Track | Reason |
|-------|-------|--------|
| 1 | A3 (auto-scroll) | Core playback feature; independent of layout changes |
| 2 | B1 (shrink AppBar) | Tiny change, immediate win |
| 3 | B3 (pill-only rest state) | Biggest music-area gain; do before B2 |
| 4 | B2 (viz selector to bottom) | Depends on B3 sheet structure being settled |
| 5 | C1 (tap affordance) | Quick visual polish |
| 6 | C2 (range selection) | Needs C1 visual feedback in place to feel right |
