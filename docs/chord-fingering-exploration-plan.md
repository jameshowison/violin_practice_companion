# Exploration Plan — Chord Fingering Display

**Target:** iPad app for learning mandolin. Music is engraved with Verovio.

**Scope of this document:** the pathways worth exploring and the questions that decide between them. It deliberately does not prescribe implementation — the answers below should come from your own knowledge of the stack and from cheap experiments, not from assumptions baked into this plan.

---

## Background — what the user actually needs

The user is **learning mandolin**. This is the single most important fact for judgment calls this plan doesn't cover.

**Chord letter names alone are insufficient.** Seeing `Am` above the staff assumes you can already recall the shape. A learner can't. They need the *picture* of where the fingers go, and they need it at the moment of playing — not looked up beforehand and memorised.

**They equally need the strumming pattern.** Knowing which chord is only half the information; the other half is when and in which direction to strum. A chord symbol says *what*, and nothing says *when*. Both must be present.

**Reference model.** The user works from a beginner mandolin ebook whose page layout they like, and which this design is deliberately echoing:

- Standard notation over four-line mandolin tab (dual stave), with chord symbols above
- Down/up strum arrows printed beneath the staff, aligned to the notes
- A footer block labelled *"New chords and strum pattern"* containing chord grids **only for chords being introduced**, not repeated for every tune
- The strum pattern given as a small standalone system with a count row (1 2 3 4) under the arrows — taught as its own object rather than left to be inferred

Two economies worth preserving: diagrams appear on *introduction*, not on every occurrence; and the strum pattern is taught explicitly rather than implied.

**Design intent behind horizontal diagrams.** Conventional chord grids are vertical — strings drawn as vertical lines. The tab stave beneath is horizontal — strings drawn as horizontal lines. A learner reading both silently rotates 90° between them. The proposal is to draw diagrams **horizontally, in the same string order as the tab line**, ideally reusing the tab line's own geometry so a diagram reads as the tab stave *frozen* rather than as a separate widget floating nearby. Axis agreement is the point, not compactness.

**Why two modes.** One player cannot play the melody and strum the chords at the same time. So the score has two legitimate readings, and the interface should offer both: chord names and diagrams stay fixed in either mode, and only the middle layer changes — melody in one, chords-and-strumming in the other.

**Why this must go through Verovio rather than be drawn on top.** The melody tab already renders well, and spacing must stay correct as content changes and as the user switches modes. Anything drawn as a separate layer on top of the rendered score would have to re-derive that spacing independently and keep it in sync. That duplication is the reason the overlay approach was rejected — not that it wouldn't look right, but that it would own layout twice.

**Diagrams are an editorial decision, not a runtime heuristic.** Wide diagrams on a fast-changing tune will force the engraver to widen measures and spread systems out. That's a legitimate trade-off, and it belongs to whoever prepares a given arrangement — a per-score setting, not collision-detection logic in the app. Don't build the heuristic.

---

## The constraint that shapes everything

Because nothing is drawn on top afterwards, **the diagrams must already be present in whatever Verovio consumes, before it runs layout.**

That has one non-obvious consequence: there must be a point in the load path where the input can be modified before engraving. Finding or creating that hook is a prerequisite for pathway A and pathway C, and it is likely the single largest piece of engineering in this project. Establish early whether it exists cleanly, or whether it has to be manufactured.

---

## The three pathways

### A. Diagram as an embedded graphic anchored to the chord change

Chord shapes are drawn as small graphics and attached to the score at the position where each chord changes, so the engraver positions them and spaces around them.

- **Buys:** exactly what the user asked for — the shape, inline, at the right moment. Layout stays Verovio's responsibility.
- **Costs:** depends entirely on whether the engraver treats an embedded graphic as something occupying width, or as decoration stamped at a point. If the latter, this pathway is badly constrained.
- **Unknown:** see Q1 and Q2.

### B. Chord as stacked fret numbers in the tab line

Instead of a picture, the chord is written as a vertical stack of fret numbers on the tab lines — the same way a chord appears in ordinary tablature.

- **Buys:** native behaviour, near-zero new machinery, spacing handled automatically, perfect string alignment by construction. Costs the reader nothing new — same reading skill as the melody tab already on the page.
- **Costs:** it's numbers, not a shape. It tells you where fingers go but not what the hand looks like, and two very different hand positions can look equally compact as digits. This does not fully meet the stated need on its own.
- **Best use:** as the inline form, paired with proper grids in a footer block — inline answers "what do I press right now," footer answers "what is this shape." This is what the reference ebook does.

### C. Two modes — melody view and rhythm view

One source, two renderings. Chord names and diagrams fixed in both; the middle layer swaps between melody and chords-plus-strumming.

- **Buys:** makes the "you can't do both at once" fact structural rather than something the learner has to work out. Also resolves a conflict between A and B — a tab line already full of melody cannot also hold chord stacks, so B naturally belongs to rhythm mode.
- **Costs:** the two modes have different content, so the engraver will break systems differently and the page will jump under the user when they toggle. That's a real UX problem, not a cosmetic one.
- **Lowest technical risk of the three, highest UX risk.**

---

## Questions that decide between them

Answer Q1–Q4 before writing pipeline code. Each is cheap, each can redirect the plan.

**Q1 — Does the engraver reserve horizontal space for an embedded graphic?** ← primary gate

Attach a deliberately absurd, very wide graphic at one point in a single measure and compare against a control. Three outcomes: the measure widens (pathway A is viable as designed), the graphic overlaps its neighbours (A is constrained, go to fallbacks), or the graphic is clipped (worse — diagrams would be silently truncated).

If it does widen, measure the response curve at realistic diagram widths. You need cost-per-diagram before deciding how many a line can carry.

**Q2 — Can a graphic be anchored at a chord-change position at all, and can it sit together with the chord name as one object?**

Both halves matter. The reference layout has name and picture as a unit; if they can only be positioned independently they'll drift apart under different spacing.

**Q3 — Does chord fingering data present in the source file survive into what the engraver actually lays out?**

Source formats commonly carry fingering alongside the chord symbol, but converters frequently discard it. If it's dropped, the fingering has to be read from the original source separately and reattached — a second parse, and a change to the pipeline shape. Confirm rather than assume.

**Q4 — Can the tab line carry a stacked chord, and what happens if melody occupies the same moment?**

Expect a collision. Confirm it, because that collision is what justifies confining pathway B to rhythm mode rather than trying to show both at once.

Also confirm the four-course mandolin tuning renders correctly with stacked notes — worth checking explicitly rather than assuming it follows from the melody tab working.

**Q5 — Is the engraver's input stable if you feed its own output back in?**

If the modification hook works by taking the engraver's intermediate output, altering it, and re-loading, then that round trip must be lossless. Test it by round-tripping twice and diffing. Watch particularly for anything auto-generated being regenerated differently, and for tab configuration drifting.

If it isn't stable, the whole modify-then-reload approach is in question and you should consider doing the conversion ahead of time instead of at load.

**Q6 — What does the extra processing cost on device?**

Decide an acceptable score-open latency *before* measuring, so the number means something. Measure on real hardware with a realistic score, comparing today's single pass against the modified pipeline.

If it's over budget, the obvious move is to do the work once and persist the result, keyed by a hash of the source file plus a version number for the processing logic. Key on the input content rather than on anything derived from the source code, so refactoring doesn't silently invalidate every stored score.

**Q7 — Do the two modes break systems in the same places?**

Render both and compare. If they differ, test forcing identical breaks across both, computed from whichever mode is denser, and measure how badly that compromises the looser mode. Also verify you can preserve scroll position across a toggle — a jump here undoes the "one document, two views" effect the design depends on.

---

## Sequencing

1. **Establish a transfer harness.** You will explore fastest outside the app, using whatever standalone tooling Verovio offers. That's only safe if you first prove the same input produces the same output there as it does through your app's binding. Do this before anything else, or every finding afterwards is suspect.
2. **Pin the Verovio version** and record it with every result. Some of what you're relying on may be recent.
3. **Q1–Q4** — cheap, outside the app, hours not days.
4. **Q5–Q6** — require the real pipeline.
5. **Q7** — last, once there's something to toggle between.

---

## Decision gates

| After | If | Then |
|---|---|---|
| Q1 | Space is reserved | Pathway A primary — inline diagrams. |
| Q1 | Overlaps or clips | Pathway B primary — stacked numbers inline, grids in footer. |
| Q2 | Name and graphic can't be one object | Reconsider A; drift under spacing will look broken. |
| Q3 | Fingering survives | Read it directly. Simpler. |
| Q3 | Fingering dropped | Second parse of the original source to recover it. |
| Q4 | Melody collides with chord stacks | Confirms B belongs to rhythm mode. Pathway C becomes necessary, not optional. |
| Q5 | Round trip lossy | Escalate — consider processing ahead of time rather than at load. |
| Q6 | Over budget | Process once, persist, key on source content hash. |
| Q7 | Breaks differ between modes | Force shared breaks, accept the spacing compromise. |

---

## Fallbacks if Q1 fails

With drawing-on-top excluded, a bad Q1 result needs a plan. In order of preference:

1. **Pathway B becomes primary**, with proper chord grids in a footer block rendered outside the engraved score entirely. This still satisfies the user's core requirement — the shape is still shown, just not inline — and it's exactly what the reference ebook does. The footer isn't an overlay because it isn't positioned against the score.
2. **Inline diagrams without width reservation, enabled per-score.** Accept that they can collide, and only switch them on for arrangements with slow chord changes. This was already the intended editorial behaviour; the fallback just makes it load-bearing.
3. **Force width artificially** by inserting an invisible placeholder at the same position. Fragile, may not survive version upgrades, test before relying on it.

---

## Standing risks

- **Tablature support in Verovio is comparatively recent**, while chord-symbol support is long-established. Two of the three pathways lean on the newer code. Verify current maturity, and track the project's tablature issues rather than assuming stability.
- **The modification hook is the critical path.** If there's no clean point to alter the engraver's input before layout, pathways A and C both stall. Probe this first among the engineering questions.
- **Nothing in this document about Verovio's internal behaviour should be treated as established.** Q1–Q5 exist precisely because the answers weren't confirmable in advance.
