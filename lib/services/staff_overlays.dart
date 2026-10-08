import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chord_palette.dart';
import '../models/engraved_measure_map.dart';
import '../models/note_event.dart';
import '../models/parsed_piece.dart';
import '../models/section.dart';
import '../models/section_palette.dart';
import '../models/violin_string_palette.dart';
import 'fingering_annotation_builder.dart';
import 'providers.dart';

/// Everything the native staff draws over the engraving, from the piece's
/// display settings: the engraved measure map those regions are addressed in,
/// the section washes, the chord lane, the fingering chips and the underline's
/// string track.
typedef StaffOverlays = ({
  EngravedMeasureMap measureMap,
  List<SectionTintRegion> sectionTints,
  List<ChordRunRegion> chordRuns,
  List<FingeringAnnotation> annotations,
  List<StringRunRegion> stringRuns,
  StringColourStyle colourStyle,
});

/// Reads a provider — `ref.watch` on screen, `ref.read` for a one-off print.
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// The overlays for [mode], built the one way both the screen
/// (`_NotationView`) and print (`score_printer.dart`) need them, so a page
/// can't disagree with the view it was printed from.
///
/// * [bySection] — whether the xml was split at section lead-ins, which adds
///   engraved slices the map must count (see `staffMeasureMapFor`).
/// * [colourStyle] — overrides the piece's [stringColourStyleProvider]; print's
///   greyscale passes [StringColourStyle.off], which puts the string letter
///   back in every label in place of the colour.
StaffOverlays staffOverlaysFor(
  ProviderReader read, {
  required ParsedPiece? parsed,
  required DisplayMode mode,
  required List<Section> sections,
  required Map<String, Color> sectionColors,
  required bool bySection,
  StringColourStyle? colourStyle,
}) {
  final measureMap = parsed == null
      ? EngravedMeasureMap.empty
      : mode == DisplayMode.tab
          ? EngravedMeasureMap.identity(parsed.measures.map((m) => m.number))
          : staffMeasureMapFor(parsed.measures, sections, bySection: bySection);
  // Per-section background wash (note-level edges so a mid-measure section
  // start/end splits the boundary measure). Empty without sections.
  final sectionTints = (parsed == null || sections.isEmpty)
      ? const <SectionTintRegion>[]
      : sectionTintRegions(
          measureMap, sections, sectionColors, parsed.measures);
  // Chord runs as labelled bars in a lane above the staff — the native renderer
  // owns the chord label now (the XML providers strip `<harmony>` for it), so
  // this list is the only thing that puts chords on the score.
  final chordRuns = (parsed == null || !read(showChordsProvider))
      ? const <ChordRunRegion>[]
      : chordRunRegions(measureMap, parsed);
  // Fingering labels as chips in a channel between the notes and the chord
  // lane. Built for the annotation view only, and — like the chord runs — this
  // list is now the ONLY thing that puts fingerings on the score: the XML
  // provider strips them so Verovio engraves none.
  final StringColourStyle style =
      colourStyle ?? read<StringColourStyle>(stringColourStyleProvider);
  final annotations = (parsed == null || mode != DisplayMode.staffFingering)
      ? const <FingeringAnnotation>[]
      : fingeringAnnotations(
          measureMap,
          parsed,
          density: read(fingeringDensityProvider),
          policy: read(fingeringDensityPolicyProvider),
          colourByString: style != StringColourStyle.off,
          stringLabelStyle: read(stringLabelStyleProvider),
          numberMode: read(noteNumberModeProvider),
          fretStyle: read(fretStyleProvider),
        );
  // The underline's string track spans every note, so it needs its own pass
  // over the piece — and only that style has any use for it.
  final stringRuns = (parsed == null ||
          mode != DisplayMode.staffFingering ||
          style != StringColourStyle.underline)
      ? const <StringRunRegion>[]
      : stringRunRegions(
          measureMap,
          parsed,
          numberMode: read(noteNumberModeProvider),
          fretStyle: read(fretStyleProvider),
        );
  return (
    measureMap: measureMap,
    sectionTints: sectionTints,
    chordRuns: chordRuns,
    annotations: annotations,
    stringRuns: stringRuns,
    colourStyle: style,
  );
}
