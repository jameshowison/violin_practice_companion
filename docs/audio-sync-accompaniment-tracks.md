# Audio sync: piano-accompaniment and play-along tracks (exploration)

Status: exploration only, nothing implemented. Written 2026-11-03 after the Suzuki Book 1
teacher tracks were added to the dev library (`media/<pieceId>/teacher_vp` and
`teacher_piano`).

## The problem

`AudioScoreAutoAligner.alignChroma` (`lib/services/audio_score_auto_aligner.dart`)
builds its chroma reference from the **score's notes only**
(`ScoreChromaReferenceBuilder`). The score is the violin line, so:

- **Violin + piano**: the melody dominates the chroma, and alignment is good.
- **Piano only, with the melody in the right hand**: the harmony adds pitch classes the
  reference doesn't have, so every frame costs more and the path is less certain. It
  still aligns, but less well. Measured headlessly, the piano tracks' average DTW cost
  ran 0.25–0.37 against 0.13–0.31 for their violin+piano twins. Allegro and O Come,
  Little Children (piano) came back with `hasCompressedAnchors = true`, and their twins
  did not.
- **Play-alongs with no melody at all**: the reference matches nothing in the audio, so
  DTW output is essentially arbitrary.

## Option A: sync to a twin recording (for tracks that have one)

Every Suzuki piano track has a violin+piano twin with the same arrangement, and probably
the same piano performance or a close one (durations differ by 0.1–3 s). The idea:

1. Align the twin to the score as now. That alignment is good.
2. Align the piano track's chroma **to the twin's chroma** (audio to audio). The piano
   part is common to both, so this is a near-identical match.
   `DtwAligner.align(reference, target, openBegin:, openEnd:)`
   (`lib/services/dtw_align.dart`) already takes any two chroma sequences.
3. Map each of the twin's anchors (`audioSec`) through that path to piano-track time.
   Cache the result under the piano track's own `alignmentKey`.

Pieces needed:
- A new optional `PieceMedia` field, e.g. `timingFrom: <sibling media id>`. It sits
  beside `contentStartSeconds` / `contentEndSeconds`, as a fact about the recording that
  survives a realign.
- A branch in `MediaPlaybackService._alignmentFor` / `_runAlignment`
  (`lib/services/media_playback_service.dart`) that loads the sibling's alignment, which
  may mean computing it first, and then warps it.
- When the sibling is realigned, its dependents' cached alignments are cleared.
- UI: a "Match timing to…" picker next to the content-window control in
  `lib/widgets/media_controls.dart`. For the dev library, set the field directly in
  `state.json` on the 7 `teacher_piano` rows. The pull and push scripts copy rows
  whole, so they need no change. The app's media-row parser
  (`PieceMedia.fromJson`) does: it must read the new field.

To verify, compare twin-warped anchors with the current direct anchors on the 7 piano
tracks. Then spot-check the ones that disagree by ear.

This doesn't help a play-along with no twin.

## Option B: steady tempo + start (play-alongs, no twin, no melody)

Play-along tracks are usually strict tempo, often with a count-in. Given where the tune
starts (the existing `contentStartSeconds` control) and a tempo, the anchors are just
evenly spaced bar onsets. Tempo could be detected from the onset envelope
(`AudioEnergyEnvelopeExtractor.detectOnsetTimes`) or typed in. The approach is cheap and
exact for metronomic tracks. It is wrong for rubato or ritardando: Suzuki's Allegro has
fermatas, for example.

## Option C: tap-along

The user listens once and taps each downbeat (or each beat), and the taps become the
anchors. This works for any recording, but costs a full listen per track. It could also
be the way to correct option B where a track drifts.

## Not viable

- **Adding harmony to the reference.** The scores are melody-only. A few pieces have
  `<harmony>` chord symbols (see the Verovio chord notes) that could add chord pitch
  classes to the reference, but most don't.

## Open decision

The user has not yet chosen between B, C, or both for play-alongs. Option A is the
clear first step for the Suzuki tracks.
