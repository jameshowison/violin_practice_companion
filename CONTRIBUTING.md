# Contributing

Contributions are welcome. See the README's "Contributing" section for what is
most useful right now, `docs/explore.md` for how the app got to where it is,
and `docs/plan.md` for the roadmap.

This is a solo project with no CI or review gate, so the checks that matter run
locally on every `flutter test`. Please read the next section before adding any
music, image, recording or document to the repo.

## Content and copyright

The code is GPL-3.0. Much of the **music around it is not ours**. Beginner
repertoire is mostly public-domain melody, but the editions people learn from
are under copyright: their engraving, fingerings, bowings, accompaniments,
recordings, and the method's own compositions. The app is designed around that
line. It reads a copy you already own and generates its own notation, so the
repo never needs to carry an edition.

**Never commit:**

- scans, photos or PDFs of printed music or of pages from a published book;
- recordings you didn't make or don't have permission to share (commercial
  CDs, accompaniment tracks, archive recordings);
- scores downloaded from score-sharing sites, unless the site states a licence
  that allows redistribution (record it in the catalog);
- lyrics still under copyright, in a fixture, a test assertion or a code
  comment;
- a method's or publisher's name or numbering in bundled content ("Book 1, No.
  16"). Naming a method in prose to say what the app is compatible with is fine.

If you need material like that to develop or test against, keep it outside the
repo (see "Restricted test material" below) and commit only what you learned:
the numbers, the bug, the fix.

### Where things live

```
assets/engine/        the app's machinery: converters, OSMD, lookup tables;
                      soundfont and OMR models are fetched, not committed
assets/library/       the bundled pieces, one folder each, listed in
                      catalog.json with their source and licence
test/fixtures/        public test data: our own ABC, its conversions,
                      engravings of bundled pieces, OMR readings (notes only)
                      of public-domain pieces
test/support/         test helpers, including restricted_fixtures.dart
dev/                  dev-only entrypoints and experiments; never imported by lib/
scripts/              dev tooling (device, sync, content, omr_eval)
docs/                 prose, our own ABC sources, screenshots of the app
```

Everything under `assets/` is bundled into the app. Nothing else is.

### Adding a bundled piece

1. Use a public-domain or openly licensed source. Prefer writing the tune in
   ABC yourself and importing it through the app, as `docs/wellerman.abc` was.
   If you start from an existing MusicXML file, strip it to the music:
   ```bash
   python3 scripts/clean_musicxml.py in.xml assets/library/<id>/score.musicxml \
     --title "Title" --composer "Composer"
   ```
   This removes fingerings, bowing marks, title-page credits and the encoder's
   header. The app generates its own fingerings.
2. Add `assets/library/<id>/sections.json`.
3. Add an entry to `assets/library/catalog.json`: `id`, `title`, `composer`,
   `score`, `sections`, a `source` saying where the music comes from, a
   `license` (`public-domain`, `cc0`, `cc-by`, `cc-by-sa`, `project`), and
   `fingerings: "app"`.
4. Add `- assets/library/<id>/` to `pubspec.yaml`'s asset list. Flutter does
   not bundle subfolders.
5. Run `flutter test`. `test/release_content_test.dart` fails if any of the
   above is missing or out of step.

Play-along tracks go in `assets/library/<folder>/audio/` (gitignored: they are
supplied, not committed), with an `audio` block in the catalog entry and their
own pubspec line. Tracks licensed `internal-testing-only` may go into test
builds for known testers. `VPC_PUBLIC_RELEASE=1 flutter test` refuses them, so
run that before any public release.

### The two guards

- `test/release_content_test.dart` covers what ships. The library, the catalog
  and pubspec must agree file for file. Every entry needs a source and an
  allowed licence. Bundled scores may carry no credits, source URLs, rights,
  edition fingerings or bowings, and no method names.
- `test/repo_content_policy_test.dart` covers what may be committed at all.
  Images, PDFs, audio and models are allowed only in the platform icon folders
  and `docs/images/`. Score files are allowed only in the library,
  `test/fixtures/` and `docs/`. Local-only folders (`lyrics_eval/`,
  `docs/photos_no_share/`) are never committed.

If a guard is in your way, the fix is almost always to move the file out of
the repo, not to widen the guard.

### Restricted test material

Some tests are worth running against material that can't be public, such as a
song with in-copyright lyrics or a third-party recording. Those tests read it
from a private checkout beside this one, through
`test/support/restricted_fixtures.dart`:

```dart
test('…', skip: skipUnlessRestricted(kGundagaiLyrics), () {
  final xml = readRestricted(kGundagaiLyrics);
  …
});
```

The checkout is found at `$VPC_RESTRICTED_DIR`, or else
`../violin_practice_restricted`. Without it these tests **skip**, so a fresh
public clone runs the suite green. The maintainer keeps a private companion
repo for this. If you have your own material, point `VPC_RESTRICTED_DIR` at a
folder laid out the same way. Never copy it into this repo.

Files you only keep locally can go in `docs/photos_no_share/` or
`lyrics_eval/` (both gitignored), or in a pattern in your own
`.git/info/exclude`.

### OMR testing

Testing the scanner against real book photos is very useful. **Report the
results, not the photos**: which piece and edition, what came out wrong, and
the scanner's MusicXML output if the piece is public domain. Keep the images
themselves local.
