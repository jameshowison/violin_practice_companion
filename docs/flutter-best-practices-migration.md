# Flutter Best-Practices Migration Plan

Produced by reviewing the codebase against the `flutter-all` plugin's flutter-patterns skill (widget, performance, testing, security, animation pattern files). Priorities reflect risk/effort ratio for this solo vibe-coding project.

---

## Priority 1 — Performance quick wins ✅ DONE

| Item | File | Status |
|------|------|--------|
| `_buildNotationView` helper method → `_NotationView` ConsumerWidget | `screens/piece_detail_screen.dart` | Done |
| Duplicate `ValueListenableBuilder + MeasureSelector` → `_ActiveMeasureSelector` widget | `screens/piece_detail_screen.dart` | Done |
| `const` scan on static widgets | `screens/piece_detail_screen.dart`, `widgets/fingering_view.dart`, `widgets/jianpu_view.dart` | Done (files already well const-ified; dynamic scale/color values block remaining candidates) |
| `_CompactPieceLayoutState.initState` writes provider directly → deferred with `addPostFrameCallback` | `screens/piece_detail_screen.dart` | Done (was crashing Happy Farmer) |

---

## Priority 2 — Material 3 widget upgrades

### `_StringLabelPicker`: Radio + GestureDetector → SegmentedButton
**File:** `screens/piece_detail_screen.dart` (class `_StringLabelPicker`)  
**Pattern:** Replace the manual `Radio<StringLabelStyle>` + `GestureDetector` row with `SegmentedButton<StringLabelStyle>`. Analyzer also flags the `Radio` API as deprecated since Flutter 3.32.  
**Plugin ref:** Widget Patterns → `SegmentedButton (Material 3)`

### `_CompactModeSwitcher` / `_ModeTab`: hand-rolled tabs → TabBar or NavigationBar
**File:** `screens/piece_detail_screen.dart` (classes `_CompactModeSwitcher`, `_ModeTab`)  
**Pattern:** The 5-mode switcher uses bare `InkWell` + manual bottom-border underline. Replace with `TabBar`/`Tab` (already available, zero new deps) or Material 3 `NavigationBar`. `TabBar` is the lower-effort swap and keeps the icon+label compact form.

### Settings drawer title: hardcoded `TextStyle` → theme token
**File:** `screens/piece_detail_screen.dart`, `endDrawer` builder (~line 86)  
**Pattern:** `Text('Settings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))` → `Text('Settings', style: Theme.of(context).textTheme.titleLarge)`

---

## Priority 3 — State management modernization

### `StateNotifier` → `Notifier` (Riverpod v2)
**File:** `services/providers.dart` — `StringLabelStyleNotifier extends StateNotifier<StringLabelStyle>`  
`StateNotifier` is deprecated in Riverpod v2. Migrate to:
```dart
class StringLabelStyleNotifier extends Notifier<StringLabelStyle> {
  @override
  StringLabelStyle build() => StringLabelStyle.always;
  void set(StringLabelStyle v) => state = v;
}
// Provider becomes:
final stringLabelStyleProvider = NotifierProvider<StringLabelStyleNotifier, StringLabelStyle>(
  StringLabelStyleNotifier.new,
);
```

### Move `MeasureSelection` to its own model file
**File:** `services/providers.dart` (~line 130) — `MeasureSelection` is a plain value type, not a provider concern.  
**Action:** Create `models/measure_selection.dart`, move class there, update imports in `providers.dart`, `screens/piece_detail_screen.dart`, `widgets/measure_selector.dart`.

### `_hasPeeked` static bool on private State class
**File:** `screens/piece_detail_screen.dart` — `_CompactPieceLayoutState._hasPeeked`  
Shared across all instances via static. Works but is surprising. Low priority — leave unless it causes a bug.

---

## Priority 4 — Testing (zero tests currently)

Start with pure-Dart unit tests (no Flutter framework needed):

| Test target | File to test | Notes |
|-------------|-------------|-------|
| `MusicXmlParser.parse()` | `services/musicxml_parser.dart` | Feed sample MusicXML strings, assert `ParsedPiece` fields |
| `FingeringMapper.map()` | `services/fingering_mapper.dart` | Assert fingering assignments on known notes |
| `JianpuConverter.convert()` | `services/jianpu_converter.dart` | Assert jianpu numbers/octave dots |
| `PieceLayout.compute()` | `models/piece_layout.dart` | Assert row grouping for given measures-per-row |

Then provider tests using `ProviderContainer` with a mocked `PieceRepository`:
- `parsedPieceProvider` chain (select piece → parse → layout)
- `measureSelectionProvider` toggle logic

Then widget tests:
- `MeasureSelector` — tap/drag selection, active measure highlight
- `SectionBar` — section tap fires callback
- `PlaybackControls` — play/pause/stop button state

**Plugin ref:** Testing Patterns → Unit Test Templates, Riverpod testing patterns

---

## Priority 5 — Multi-platform smell check (mostly clean)

The codebase already uses the conditional-import pattern correctly (`staff_view_io.dart`/`staff_view_web.dart`, `playback_service_io.dart`/`playback_service_web.dart`).

One item to verify before the first mobile build:
- `SchedulerBinding` usage in `piece_detail_screen.dart` — confirm it's from `package:flutter/scheduler.dart` (cross-platform), not a platform-specific import. ✅ Already imported correctly.

The mobile build milestone (commit `ios/Podfile`, `macos/Podfile`, `Pods-Runner.*.xcconfig` includes) should happen at feature freeze per CLAUDE.md — not speculatively.

---

## Reference

- Plugin patterns location: `~/.claude/plugins/cache/flutter-claude-code/flutter-all/1.0.0/skills/flutter-patterns/patterns/`
- Plugin agents available: `flutter-all:flutter-architect`, `flutter-all:flutter-state-management`, `flutter-all:flutter-testing`, `flutter-all:flutter-performance-optimizer`
