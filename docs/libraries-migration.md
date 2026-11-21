# Moving code into libraries: how each step is done

Status: step 0 done (2026-11-20). The plan itself, meaning which libraries,
what goes in each and in what order, is [`family/libraries.md`](family/libraries.md).
This page covers how a step is carried out, so that Stringlings keeps
building, passing its tests and shipping at every commit.

## The workspace

The repo is a **Dart pub workspace**:

- The root `pubspec.yaml` is the app, and it lists its libraries under
  `workspace:`.
- Each library is a directory under `packages/` whose pubspec says
  `resolution: workspace`.
- There is one resolution and one `pubspec.lock`, at the root.
- `flutter pub get` at the root resolves everything.

Rules that follow from it:

- **A library's dependencies must resolve together with the app's.** The
  first `pub get` failed for this reason: the libraries' `test` dev
  dependency could not coexist with the Flutter SDK's pinned `test_api` while
  the unused `riverpod_generator` held `analyzer` at ^7. Those code-generation
  dependencies were removed. If a library dependency clashes again, change
  the library's constraint first, and the app's only after that.
- **`packages/jovial_svg` is not a member.** It is vendored third-party code
  with an old SDK floor, so it stays a plain path dependency.
- **The `homr_flutter` override works unchanged.**
  `pubspec_overrides.yaml.off` sits at the workspace root, which is where pub
  reads overrides. With it moved into place, `pubspec.lock` records the path;
  with it moved back and `pub get` re-run, the lock is restored byte for
  byte. Checked 2026-11-20.
- **Nothing runs a library's tests except the library**, because the root
  `flutter test` only runs `test/`. Use the script, which runs the app's
  tests and then `dart test` in every member:
  ```bash
  bash scripts/test_all.sh
  VPC_RESTRICTED_DIR=/nonexistent bash scripts/test_all.sh   # as a clone would
  ```
- **A member needs a README, a CHANGELOG and a LICENSE.** The libraries are
  GPL-3.0, except `string_tuner`/`pitch_tuner`, which is BSD-3-Clause. A
  member also needs `publish_to: none` until the pub.dev decision is
  revisited, and an `analysis_options.yaml` that includes
  `package:lints/recommended.yaml`.

## The four commits of an extraction

1. **Safety net.** Before anything moves, pin today's behaviour in a snapshot
   test. For musicxml_tools, that is every bundled piece parsed, plus its
   fingerings and the output of each repair or injector. For score_sync, it is
   the synthetic alignment anchors. Each of the next three commits must leave
   the snapshot identical.
2. **Seam, in the app.** Cut whatever stops the files from being a library,
   without moving them:
   - a Flutter import
   - a `rootBundle` read (the data becomes a parameter, and the app does the
     loading)
   - an app field on a library type
3. **Move.** `git mv` the files into `packages/<lib>/lib/src/` and leave a
   one-line re-export shim at each old path, so this commit is a pure rename
   (`git log --follow` must show it as one). The tests that move switch from
   `flutter_test` to `package:test`.
   - Tests that need app files or bundled assets stay in the app as
     integration tests.
   - Tests that need the restricted checkout must skip without it, as they do
     in the app today.
4. **Import rewrite.** Point the app's imports at the library's barrel file
   and delete the shims. This is a mechanical substitution. Never use
   `dart format`: this repo isn't formatted, and a formatter turns a
   three-line change into hundreds (CLAUDE.md smell #5).

## Branches and merging

- **Each step is a short branch in the main checkout.** When a step is green,
  it is fast-forwarded into main and the branch is deleted. Every step is
  useful to Stringlings alone, so nothing waits for the rest.
- **If main has moved, rebase the step.** The branch is rebased onto main,
  `scripts/test_all.sh` is run again, and then the branch is merged.
- **Use a worktree only when another session holds the main checkout.** It
  then lands with a fast-forward push to `origin/main`, and the main checkout
  catches up with `git pull --ff-only`.
- **Family-only work goes on `next_gen`.** That is the work no use to
  Stringlings alone: the second app, the woodwind prototype, and the move of
  the app to `apps/`. `next_gen` is rebased onto main after each step lands.

## Checklist for every step

- [ ] `bash scripts/test_all.sh`, and again with `VPC_RESTRICTED_DIR=/nonexistent`
- [ ] the snapshot test is unchanged
- [ ] `flutter analyze` at the root has no new issues (it covers the members too)
- [ ] the CLAUDE.md smell check, especially #5: compare
      `git diff --shortstat` with `git diff -w --shortstat`
- [ ] for a step that changes behaviour (not a pure move): on `dev-iphone-se`
      with the stamp verified, open a piece, edit a bar, scan, play with a
      count-in, align a recording (check the anchor span); then `dev-android`

## Progress

| Step | What | State |
|---|---|---|
| 0 | Workspace root, `scripts/test_all.sh`, unused codegen dependencies removed | done |
| 1a | `musicxml_tools`: snapshot, `NoteAnnotation` seam, move | next |
| 1b | `score_sync`: `ScoreTimeline` + `AlignmentProfile` seams, move, then an isolate | |
| 2 | `InstrumentProfile`, viola, Annotate | |
| 3 | `pitch_tuner` (chromatic, transposition, drone mode), `<transpose>` | |
| 4 | `score_view` | |
| 5 | `audio_decoder`, `practice_core`, `apps/` | |
| 6 | parts, staves, voices | |
