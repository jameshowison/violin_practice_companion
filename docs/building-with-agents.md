# How this app was built: notes on agentic coding

Violin Practice Companion was built between May and October 2026 by one person
working almost entirely through coding agents. There are 203 commits, about 170
of them co-authored by six successive Claude models, from Sonnet 4.6 to Opus 5.5.
The repo holds no PR process, CI or reviewer, so the history in
`git log`, `docs/explore.md`, `docs/plan.md` and `CLAUDE.md` is the main record
of how the work went.

**From phases to conversation.** The first week followed a waterfall-shaped plan:
"Implement Phase 1", "Phase 2A", with PHASE1–4 documents written up front.
Those documents were later folded into `explore.md` (a history of forks and
decisions) and `plan.md` (open work only, pruned as items land). Commit messages
changed in the same way, from feature labels to plain sentences about the
behaviour ("Ask where the tune is, instead of inferring it") with long bodies
saying what was measured and what was rejected. The specification stopped being
something written before the code. It came out of the work, mostly in commit
messages, and was written down after the fact.

**Discovery by measurement.** Most big decisions were settled by experiment
rather than argument. Optical music recognition engines were benchmarked note by
note: Oemer was rejected for a structural flaw found by grepping its source,
Audiveris on licence grounds, and Homr passed. Its Python orchestration was then
ported to Dart as a sibling package. A short spike replaced the OSMD WebView with
Verovio, and found that the hard part was the SVG renderer, not the engraving
engine. Audio-to-score alignment took three design write-ups on DTW edge cases
before it worked well enough to use.

**Wrong turns.** Several were cheap to make and cheap to undo:
- An AI-generated blueprint for headless OSMD was rejected once someone read it
  closely.
- `flutter_svg` drew nothing and was swapped for `jovial_svg`.
- An auto-capture scanner mode was tried and reverted.
- Binarisation was declared "required, not optional" in June and retired in
  October, once a grey photocopy showed the real fault was image resizing.
- Anchor smoothing in the alignment turned out to be hiding a wrong score, so it
  became a warning shown to the user.
- A heuristic that guessed where a recording's tune starts gave way to simply
  asking the user.

The pattern is that a confident fix later turned out to be covering up the real
problem.

**Learning to work with agents.** `CLAUDE.md` grew to about 370 lines. Most of
it is not about the app. It records the environment and how agents fail in it:
- run `flutter run` as a long-lived server fed through a fifo;
- stamp each build and read the stamp back off the device, because a stale build
  once cost 40 minutes and two false bug reports;
- don't trust the simulator's orientation menu;
- start a screenshot burst *before* tapping, because a count-in finishes faster
  than the gap between two tool calls;
- don't run the formatter, since it once turned a 3-line edit into 180 lines of
  churn.

One plugin was turned off because its device tool kept getting chosen despite
written instructions not to use it. That was a case of changing the environment
when instructions didn't work. Agents were also given ways to see for
themselves: Marionette for the UI, simctl for screenshots, headless Verovio for
layout questions, and scripts for steps that need native iOS dialogs, which
agents can't tap. Much of the human's skill went into this scaffolding, and into
judging when a result could be trusted.

**Domain knowledge stays human.** The rules that matter most come from violin
teaching: fingering labels like `A2L` must never be "tidied" into ♭/♯, lookup
tables are kept in JSON so a teacher can edit them, and a recording must be
played in its real order (D.C., Fine, repeats). The owner stated these and wrote
them down as rules, because an agent left to its defaults would "clean them up".

## Questions this experience could help answer

1. When specification comes out of the work instead of preceding it, what is the
   real record of intent: plan documents, commit messages, `CLAUDE.md`, or the
   conversations, which are lost?
2. Is the main skill now *environment design*: making a system that agents can
   observe, check and not be fooled by? How is that skill learned and passed on?
3. How should trust be calibrated when an agent reports success? This history
   has stale builds, simulators that misreport state, and plausible fixes that
   hid the real problem. What verification habits generalise?
4. Did cheap code change which wrong turns get taken? Spikes and reversals cost
   little here. Does that encourage useful exploration, or more confident
   over-engineering, as with the binarisation threshold and the anchor
   smoothing?
5. Where does domain expertise sit when one non-specialist plus agents can build
   OMR, DTW alignment and engraving integration? What still depends on the human
   (taste, pedagogy, knowing when to ask the user), and what will?
6. What happens to code ownership and maintainability when most commits are
   co-authored by six model versions with no human review? Can someone (or
   something) other than the owner pick this project up?
7. How do knowledge and memory work across sessions? Each lesson in `CLAUDE.md`
   was paid for once. Is that file the team's shared memory, and how does it
   decay or bloat?
8. Which parts of this generalise beyond a solo "vibe coding" project to teams
   with review, CI and shared codebases, and which depend on having one person
   who holds all the context?
