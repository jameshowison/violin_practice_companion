#!/usr/bin/env python3
"""Reduce a MusicXML score to the music itself, for bundling with the app.

Removes what an editor or a previous edition added on top of a public-domain
tune: fingerings, bowing marks (up-bow / down-bow), title-page credits, and the
encoder's <identification> block (software, source URL, rights). Keeps notes,
rhythms, key, meter, repeats, slurs, articulations, dynamics, tempo and
navigation words, and chord symbols. Writes a neutral <work-title> and,
optionally, the composer.

Line-based on purpose: the file's own formatting is preserved, so the app's
normalizer/beamer round-trip tests still see byte-identical input.

  python3 scripts/clean_musicxml.py IN.xml OUT.xml --title "Gavotte" --composer "F.-J. Gossec"

See CONTRIBUTING.md, "Content and copyright".
"""
import argparse
import re
import sys
from xml.sax.saxutils import escape


def block(tag):
    # A whole element, with its own leading indentation and trailing newline.
    return re.compile(rf'^[ \t]*<{tag}\b[^>]*?(?:/>|>.*?</{tag}>)[ \t]*\n', re.S | re.M)


def empty(tag):
    return re.compile(rf'^[ \t]*<{tag}>\s*</{tag}>[ \t]*\n', re.M)


def clean(xml, title, composer):
    for tag in ('identification', 'credit', 'work', 'movement-number', 'movement-title',
                'fingering', 'up-bow', 'down-bow'):
        xml = block(tag).sub('', xml)
    # Containers the removals may have emptied, innermost first.
    for tag in ('technical', 'articulations', 'notations'):
        xml = empty(tag).sub('', xml)

    m = re.search(r'^([ \t]*)<score-partwise\b[^>]*>[ \t]*\n', xml, re.M)
    if not m:
        sys.exit('not a <score-partwise> document')
    # Indent like the file's own first child.
    child = re.search(r'^([ \t]+)<', xml[m.end():], re.M)
    ind = child.group(1) if child else '  '
    head = f'{ind}<work>\n{ind}{ind}<work-title>{escape(title)}</work-title>\n{ind}</work>\n'
    if composer:
        head += (f'{ind}<identification>\n'
                 f'{ind}{ind}<creator type="composer">{escape(composer)}</creator>\n'
                 f'{ind}</identification>\n')
    return xml[:m.end()] + head + xml[m.end():]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('src')
    ap.add_argument('dst')
    ap.add_argument('--title', required=True)
    ap.add_argument('--composer')
    a = ap.parse_args()
    xml = open(a.src, encoding='utf-8').read()
    out = clean(xml, a.title, a.composer)
    open(a.dst, 'w', encoding='utf-8').write(out)
    for tag in ('fingering', 'up-bow', 'down-bow', 'credit', 'software', 'source'):
        n = len(re.findall(rf'<{tag}\b', out))
        if n:
            sys.exit(f'{a.dst}: {n} <{tag}> left')


if __name__ == '__main__':
    main()
