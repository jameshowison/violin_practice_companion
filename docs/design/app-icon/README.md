# Stringlings app icon: design record

The app icon was designed in November 2026 through a series of comparison
pages, published as private claude.ai artifacts. The pages are also kept here,
so they can be opened in any browser even if the published links stop working.

| Page | Published | Local copy |
|---|---|---|
| Concept rounds 1–6: early directions, then the annotation-style stringlings | <https://claude.ai/artifact/FpUYWQwrDSptN92piGzJGn> | [`icon_concepts.html`](icon_concepts.html) |
| Tuner for the final design: note size, staff weight, stem, colours, every iOS size at once | <https://claude.ai/artifact/KNcZcBrQraYZ9WhuHtGufe> | [`icon_tuner.html`](icon_tuner.html) |

The published pages are private to the owner's claude.ai account. To open a
local copy, double-click it, or run `open docs/design/app-icon/icon_tuner.html`.
The copies load their fonts from Google Fonts, so they need a network connection
to look exactly right. Without one, they fall back to system fonts.

## How the design arrived

1. **Round 1:** six generic directions: the scroll, f-hole, finger tapes, bow on
   the staff, violin silhouette, and following along.
2. **Round 2:** the "Stringlings" name, a short form of "string fingerings".
   Six concepts drawn from the app's own fingering annotation: a finger number
   on a rule in the string's colour (G green, D blue, A red, E yellow).
3. **Round 3:** variations on the three-note phrase `3 · 2L · 1` and on a note
   drawn as a character.
4. **Round 4:** the label replaced by a stringling peeking over the fingering
   rule, fingers curled over the edge. **"Two peeking"** was chosen: a big one
   on the A string and a little one a step higher on the E string, standing for
   a teacher and pupil, or a parent and child.
5. **Round 5:** staff lines added under the notes.
6. **Round 6:** the bigger notes put on round 5's staff, which is looser than
   real notation but reads better at small sizes.
7. **Tuner:** final values chosen by eye: note size 73, staff firmness 59,
   stem nudge 2.5, stem start 11, Paper background, Auto ink.

## Where the real icon comes from

These pages are design history, not the source of the app's icon. The icon is
generated from [`scripts/app_icon/stringlings_icon.mjs`](../../../scripts/app_icon/stringlings_icon.mjs),
which holds the tuned values above. To change the icon, edit that file and run:

```bash
bash scripts/gen_app_icons.sh
```

That script regenerates the iOS app icon set, the Android legacy and adaptive
icons, and the launch-screen images. If you try new values in the tuner first,
copy its settings line into the constants at the top of
`stringlings_icon.mjs`.
