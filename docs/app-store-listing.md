# Stringlings — App Description

Source of truth for the App Store Connect and TestFlight fields. Last updated 2026-11-15; edit here, then `uv run scripts/push_listing.py` (offline preview), `--compare` (vs. live) and `--apply`.

## Name, subtitle and promotional text

| Field | Limit | Text | Length |
| --- | --- | --- | --- |
| App name | 30 | Stringlings | 11 |
| Subtitle | 30 | Violin practice help at home | 28 |
| Subtitle (alternative) | 30 | Practice violin with your kid | 29 |
| Promotional text | 170 | Snap a photo of violin music and get fingerings on every note. Hear any part aloud or record your teacher playing, all synced up. No signups or data collected. | 159 |

Promotional text can be changed at any time without a new build, so it can carry news later.

## Links and contact

| Field | Value |
| --- | --- |
| Support URL | https://stringlings.app/support.html |
| Privacy policy URL | https://stringlings.app/privacy.html |
| TestFlight feedback email | support@stringlings.app |

## Version details and App Review

| Field | Value |
| --- | --- |
| Copyright | 2026 James Howison |
| Primary category | MUSIC |
| Secondary category | EDUCATION |
| Content rights | USES_THIRD_PARTY_CONTENT |
| Age rating | None to every question (4+) |
| Review contact | James Howison |
| Sign-in required | No |

The review contact's phone and email come from 1Password (`review_phone`, `review_email`), never this file. App Privacy ("Data Not Collected") can't be set through the API; it's done on the web.

**Review notes**

No sign-in or account is needed.

The app comes with nine pieces already installed, so every feature can be tried without scanning anything. All nine are in the public domain: traditional songs, or works published before 1850. Each is our own notes-only encoding, not a copy of any published edition.

- Lightly Row (traditional German folk song)
- Song of the Wind (traditional German folk song)
- May Song (traditional German folk song)
- Long, Long Ago (Thomas Haynes Bayly, 1833)
- The Happy Farmer (Robert Schumann, 1848)
- Gavotte (François-Joseph Gossec, 1786)
- Minuet in G (Christian Petzold, c. 1725)
- The Wellerman (traditional, 19th century)
- Old Joe Clark (traditional American tune)

To try it: open any piece and the fingering appears above each note. Play it to hear it with each note highlighted, or select a few bars to play just those.

Scanning is optional: photographing any page of printed violin music adds it as a new piece, with fingerings.

Playback uses the GeneralUser GS soundfont under its free license. The microphone is used only for the tuner and for recording a teacher; the camera and photo library only to add music. The app collects no data.

## TestFlight beta app description

Stringlings helps with learning violin. Designed by and for parents helping their kids through the early stages.

- **Photo to fingerings.** Take a photo of a page of music. Stringlings reads it and writes the fingering above each note (or even without the notes, like A1, A3 ...)
- **Practice sections.** The piece can be reflowed into short sections that follow the music's own phrases, so you can work on one at a time.
- **Hear it played.** Play the music out loud, the whole piece or just a few bars. Each note lights up as it plays.
- **The teacher's recording.** Record your teacher playing the piece. Stringlings lines the recording up with the written music, so you can hear the teacher play just the section you've selected.
- **Numbered notation.** Show any piece in jianpu, where the numbers 1 to 7 stand for the notes of the scale. Handy if numbers are easier to follow than the staff.

Stringlings also has a tuner for getting strings in tune. It's an early version, so feedback on it is especially welcome.

This is a beta. Use the screenshot-and-feedback option in TestFlight, and tell us what you expected to see.

## What to Test (build 1.0.0+4)

Thank you for trying Stringlings. Please try these with music your child is actually learning:

1. Photograph a page of music. Are the notes right? Are the fingerings where you'd expect them?
2. Choose a short section and play it. Does the highlighting keep up with the sound?
3. Record your teacher playing a piece, then play a section of that recording. Does it start and stop on the right notes?
4. Anything confusing, slow or broken: send a screenshot from TestFlight and say what you were trying to do.

Also try the tuner. It's a first draft: does it settle on the note quickly, and does it agree with the tuner you normally use?

Also welcome feedback on additional features that could help.

## Screenshots

One set per device class: 6.9" iPhone (1320×2868) and 13" iPad (2064×2752),
captured on the `shots-iphone` and `shots-ipad` simulators. Each raw capture
gets its caption from this table (`uv run scripts/frame_screenshots.py`; README,
"App Store screenshots"). Upload by hand in App Store Connect, Media Manager.
Every piece in view must be a bundled public-domain one.

| # | Caption | Screen |
| --- | --- | --- |
| 1 | Fingerings on every note | Lightly Row, Annotated view, two bars a line, three bars selected |
| 2 | Hear your teacher play just this part | Same piece and selection, playing, the media picker open on "Teacher demo" and "Piano and Violin" |
| 3 | Snap a photo of your music | "Crop to Music" on a photo of a printed public-domain page |
| 4 | …and it's ready to practice | The piece that scan made, Annotated, laid out like the printed page |
| 5 | Tune up before you practice | The tuner, in the Playful look |

## App Store description and keywords

**Description**

Stringlings is a practice companion for violin, made for parents helping their kids through the first years of lessons.

You don't need to read music to help. Take a photo of the page your child is learning and Stringlings does the rest.

FINGERINGS ON EVERY NOTE
Stringlings reads the photo and writes the fingering above each note, so you can both see which finger goes where.

PRACTICE IN SECTIONS
The piece is reflowed into short sections that follow the music's own phrases. Work on one phrase at a time instead of the whole page.

HEAR HOW IT SHOULD SOUND
Play the music out loud: the whole piece, or just the section you've selected. Each note lights up as it plays, so it's easy to follow along.

YOUR TEACHER'S PLAYING, ON DEMAND
Record your teacher playing the piece at the lesson. Stringlings lines the recording up with the written music. Select a few bars at home and hear your teacher play exactly those bars, as many times as you like.

MUSIC AS NUMBERS
Show any piece in jianpu, the numbered notation sometimes used in China, where 1 to 7 stand for the notes of the scale. If the staff is hard to follow, the numbers may be easier.

A TUNER, TOO
A built-in tuner helps you get the strings in tune before you start.

PRIVATE BY DESIGN
Stringlings collects no data and has no accounts or sign-ups. Everything works on your device.

**Keywords** (98 of 100 characters; none repeat a word from the name or subtitle, since Apple combines words across all three)

```
music,family,beginner,learn,lessons,tuner,notes,finger chart,sheet,teacher,parent,jianpu,orchestra
```
