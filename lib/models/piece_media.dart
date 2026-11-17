/// Everything a piece can be played *by*, in one shape — the synthesized
/// score, a bundled backing track, a file the user imported, or a demo they
/// recorded on the device.
///
/// This exists because those four used to be three unrelated code paths that
/// happened to do the same job. Bundled tracks were looked up in a hardcoded
/// asset map and aligned through `AudioSyncAnchorsStore`; a recorded demo
/// stored absolute file paths and anchors in a second store with the same
/// anchor JSON; the synthesized score wasn't "media" at all, it was the `else`
/// branch of two mutually-exclusive mode booleans. Each of the three carried
/// its own playback service and its own bottom tray, and two of those were
/// near-verbatim copies of each other.
///
/// One consequence of that split was a real bug: only the *asset-backed* path
/// had a notion of "where the bytes live" that survived the app moving, so
/// recorded demos persisted absolute container paths and stopped existing
/// whenever iOS relocated the data container. [MediaRef] is the fix, and it is
/// a fix by construction rather than by patch — see its doc comment.
library;

/// Where a medium's bytes live, and hence how [MediaRef.path] is read.
enum MediaStorage {
  /// A `rootBundle` asset key, e.g. `assets/library/lightly_row/audio/melody.mp3`.
  /// Stable for the life of the build; never needs resolving.
  asset,

  /// A path **relative to the app's documents directory**, e.g.
  /// `media/galopede/audio.wav`. Resolved against the *current* documents
  /// directory every time it is read (see `media_paths.dart`).
  appFile,
}

/// A pointer to one file, stored in a form that survives the app moving.
///
/// The `appFile` case deliberately stores a RELATIVE path. iOS does not
/// guarantee that an app's data-container path is stable across updates,
/// restores, or a `flutter run` reinstall, so an absolute
/// `.../Application/<UUID>/Documents/...` string is a path that can outlive
/// the location it names. That is not hypothetical: a reinstall relocated the
/// container mid-session (`15C986F6-…` → `72FD5DA5-…`) while the stored path
/// still named the old one, and playback threw `PathNotFoundException`.
///
/// `PieceStorage` had already reached the same conclusion for MusicXML and
/// says so at `piece_storage_io.dart:32-34` — *"the piece's id is its
/// filename, and its path is recomputed on every load"*. This is that policy,
/// applied to the one kind of file that had not got it.
class MediaRef {
  final MediaStorage storage;

  /// An asset key, or a documents-relative path — never an absolute path.
  final String path;

  const MediaRef.asset(this.path) : storage = MediaStorage.asset;
  const MediaRef.appFile(this.path) : storage = MediaStorage.appFile;

  const MediaRef._(this.storage, this.path);

  bool get isAsset => storage == MediaStorage.asset;

  /// The file extension, lowercased and without the dot (`'wav'`, `'mp3'`).
  /// Empty when the path has none.
  String get extension {
    final dot = path.lastIndexOf('.');
    final slash = path.lastIndexOf('/');
    if (dot <= slash + 1) return '';
    return path.substring(dot + 1).toLowerCase();
  }

  /// WAV decodes in pure Dart via `package:wav` with no platform round trip
  /// (see [AudioChromaExtractor.extractFromWavBytes]); everything else needs
  /// the native decoder. Callers use this only to pick the cheaper route, not
  /// to decide whether analysis is possible at all.
  bool get isWav => extension == 'wav';

  Map<String, dynamic> toJson() => {'storage': storage.name, 'path': path};

  /// Returns null rather than throwing on anything unrecognized — the stores
  /// above this treat an unparseable entry as "this medium is gone", which is
  /// recoverable (re-import, re-record), where a throw would take out the
  /// whole piece's media list.
  static MediaRef? fromJson(Object? json) {
    if (json is! Map) return null;
    final path = json['path'];
    if (path is! String || path.isEmpty) return null;
    final name = json['storage'];
    final storage = MediaStorage.values.where((s) => s.name == name).firstOrNull;
    if (storage == null) return null;
    // An absolute path can only have come from a pre-[MediaRef] build; it is
    // repaired on the way in rather than being allowed to propagate. See
    // `MediaMigration.relativizeLegacyPath`.
    return MediaRef._(storage, path);
  }

  @override
  bool operator ==(Object other) =>
      other is MediaRef && other.storage == storage && other.path == path;

  @override
  int get hashCode => Object.hash(storage, path);

  @override
  String toString() => '${storage.name}:$path';
}

/// Where a medium came from. Affects presentation and what may be deleted —
/// NOT how it is played, which is the whole point of this file.
enum MediaKind {
  /// The score itself, played by the soundfont/metronome engine. Carries no
  /// files and needs no alignment: the score IS the timeline.
  ///
  /// It is in this enum, rather than being the absence of media, because the
  /// picker should offer it as one choice among the rest. Two mutually
  /// exclusive mode flags with the synthesized engine as their shared `else`
  /// branch is the same information modelled worse, and it had already gone
  /// wrong once — the exclusivity was maintained by hand at each call site.
  synthesized,

  /// A backing track shipped in `assets/library/<folder>/audio/`. Read-only.
  bundled,

  /// An audio or video file the user picked from the device.
  imported,

  /// A demo captured in-app by [TeacherRecordingCapture].
  recorded,
}

/// How well a medium's alignment followed the recording, as someone who
/// listened judged it.
enum AlignmentVerdict { good, bitOff, wrong }

/// Someone's rating of a medium's alignment: a verdict on the whole
/// recording, and optionally the bars where it was off.
///
/// One tap on Good is a complete rating; the bars are extra. It is evidence
/// for `scripts/alignment_diff.py`, which grades every alignment change by it
/// (an unrated alignment counts as presumed good), so it outlives a realign:
/// [anchorsHash] says which alignment was rated, and a different one now is
/// shown as "rated before realigning" rather than thrown away.
class AlignmentRating {
  final AlignmentVerdict verdict;

  /// Inclusive measure-number ranges marked off, in the order marked.
  final List<(int, int)> offSpans;

  /// [anchorsFingerprint] of the alignment that was rated; null if none
  /// was loaded.
  final String? anchorsHash;
  final DateTime ratedAt;

  const AlignmentRating({
    required this.verdict,
    this.offSpans = const [],
    this.anchorsHash,
    required this.ratedAt,
  });

  /// [offSpans] in the words a person would use: "bars 3-5 and 9".
  String get spansLabel {
    String one((int, int) s) => s.$1 == s.$2 ? '${s.$1}' : '${s.$1}–${s.$2}';
    if (offSpans.isEmpty) return '';
    final parts = offSpans.map(one).toList();
    final joined = parts.length == 1
        ? parts.first
        : '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
    final plural = offSpans.length > 1 || offSpans.first.$1 != offSpans.first.$2;
    return '${plural ? 'bars' : 'bar'} $joined';
  }

  String get verdictLabel => switch (verdict) {
        AlignmentVerdict.good => 'Good',
        AlignmentVerdict.bitOff => 'A bit off',
        AlignmentVerdict.wrong => 'Wrong',
      };

  Map<String, dynamic> toJson() => {
        'verdict': verdict.name,
        if (offSpans.isNotEmpty)
          'offSpans': [
            for (final (a, b) in offSpans) [a, b]
          ],
        if (anchorsHash != null) 'anchorsHash': anchorsHash,
        'ratedAt': ratedAt.toUtc().toIso8601String(),
      };

  static AlignmentRating? fromJson(Object? json) {
    if (json is! Map) return null;
    final verdict = AlignmentVerdict.values
        .where((v) => v.name == json['verdict'])
        .firstOrNull;
    final at = DateTime.tryParse(json['ratedAt'] as String? ?? '');
    if (verdict == null || at == null) return null;
    final spans = <(int, int)>[
      for (final s in (json['offSpans'] as List?) ?? const [])
        if (s is List && s.length == 2 && s[0] is int && s[1] is int)
          (s[0] as int, s[1] as int),
    ];
    return AlignmentRating(
      verdict: verdict,
      offSpans: spans,
      anchorsHash: json['anchorsHash'] as String?,
      ratedAt: at,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AlignmentRating &&
      other.verdict == verdict &&
      _sameSpans(other.offSpans, offSpans) &&
      other.anchorsHash == anchorsHash &&
      other.ratedAt == ratedAt;

  static bool _sameSpans(List<(int, int)> a, List<(int, int)> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(verdict, Object.hashAll(offSpans), anchorsHash, ratedAt);
}

/// A short, stable fingerprint of an alignment's anchors (pairs of score ms
/// and audio seconds), so a rating can tell whether the alignment it judged
/// is still the one in use. Rounded to the millisecond so a re-encode of the
/// same numbers matches.
String anchorsFingerprint(Iterable<(double, double)> anchors) {
  var h = 0x811c9dc5; // FNV-1a, 32-bit
  for (final (score, audio) in anchors) {
    for (final v in [score.round(), (audio * 1000).round()]) {
      for (var shift = 0; shift < 64; shift += 8) {
        h ^= (v >> shift) & 0xff;
        h = (h * 0x01000193) & 0xffffffff;
      }
    }
  }
  return h.toRadixString(16).padLeft(8, '0');
}

/// One playable medium attached to a piece.
///
/// Immutable and purely descriptive: it says what the files are and how they
/// relate, and nothing about how to play them. `MediaPlaybackService` is the
/// one thing that reads it.
class PieceMedia {
  /// Unique within a piece. Bundled ids are the variant name (`mix`); user
  /// media get a generated id that also names their folder on disk.
  final String id;

  final String label;
  final MediaKind kind;

  /// What is actually heard. Null only for [MediaKind.synthesized].
  final MediaRef? audio;

  /// What DTW reads to align this medium to the score. Usually the same file
  /// as [audio]; for bundled tracks it is always `melody.mp3`, the closest
  /// match to the score's own notes and so the best-conditioned reference,
  /// whichever track is being listened to.
  ///
  /// Null means this medium cannot be aligned, and so plays without driving
  /// the score highlight. [MediaKind.synthesized] is the ordinary case;
  /// anything else with a null here is a medium the decoder could not read.
  final MediaRef? analysis;

  /// Shown in the floating video window while this medium plays. Null for
  /// audio-only media.
  final MediaRef? video;

  /// Milliseconds the video's start leads the audio's, measured at capture
  /// time. [TeacherRecordingCapture] starts the camera and the microphone back
  /// to back rather than atomically, so this is the measured gap, not an
  /// assumed zero. Always 0 when audio and video are the same file.
  final int avOffsetMs;

  /// Where the tune itself starts and ends inside [analysis], in seconds of
  /// that file — the user's answer to a question the aligner otherwise has to
  /// guess at. Null (the default, and the only possibility for a bundled
  /// track, which has nobody to ask) means "work it out from the audio".
  ///
  /// This lives here, on the medium, and NOT on `MediaAlignment`, because it is
  /// a fact about the recording rather than about one run of DTW over it: a
  /// realign clears the alignment row, and the answer to "when does the tune
  /// start" must survive that — it is the input to the next run, not an output
  /// of the last.
  ///
  /// Both are hints, not hard edges; see `AudioScoreAutoAligner.alignChroma`
  /// for what the aligner does with them.
  final double? contentStartSeconds;
  final double? contentEndSeconds;

  /// The key this medium's anchors are cached under.
  ///
  /// Deliberately not the media id: a piece's `mix`/`melody`/`chords` are
  /// three mixes of ONE recording session and share a single timeline, so they
  /// share one alignment and the user only ever waits for it once. Every other
  /// kind of medium has a timeline of its own and so gets its own key.
  final String alignmentKey;

  /// Someone's verdict on how well this medium's alignment followed it; see
  /// [AlignmentRating]. Like the content window, a fact a person supplied,
  /// so it lives on the medium and survives a realign.
  final AlignmentRating? alignmentRating;

  const PieceMedia({
    required this.id,
    required this.label,
    required this.kind,
    required this.alignmentKey,
    this.audio,
    this.analysis,
    this.video,
    this.avOffsetMs = 0,
    this.contentStartSeconds,
    this.contentEndSeconds,
    this.alignmentRating,
  });

  /// The score played by the app's own soundfont engine. Always first in a
  /// piece's media list, and the only entry every piece is guaranteed to have.
  ///
  /// `const` and piece-independent: it carries no files and no alignment, so
  /// there is nothing about it that varies per piece.
  static const PieceMedia synthesized = PieceMedia(
    id: 'synthesized',
    label: 'Simulated',
    kind: MediaKind.synthesized,
    alignmentKey: '',
  );

  /// The synthesized score with its sound off: the cursor, count-off and loop
  /// run on, so a player can play along with nothing but the highlight.
  /// Offered in the picker as a track of its own, since "what do I hear" is
  /// the question the picker already answers.
  static const PieceMedia silent = PieceMedia(
    id: 'silent',
    label: 'Silent',
    kind: MediaKind.synthesized,
    alignmentKey: '',
  );

  /// True for [synthesized] and [silent] alike: both are played by the
  /// soundfont engine, from the score's own timeline.
  bool get isSynthesized => kind == MediaKind.synthesized;

  bool get isSilent => id == silent.id;

  /// Whether this medium can drive the score highlight. False for the
  /// synthesized score (which drives it directly, without anchors) and for an
  /// imported file the decoder could not read.
  bool get canAlign => analysis != null;

  /// User media owns files under the documents directory and can be removed;
  /// bundled tracks and the synthesized score cannot.
  bool get isRemovable =>
      kind == MediaKind.imported || kind == MediaKind.recorded;

  PieceMedia copyWith({String? label, MediaRef? analysis}) => PieceMedia(
        id: id,
        label: label ?? this.label,
        kind: kind,
        alignmentKey: alignmentKey,
        audio: audio,
        analysis: analysis ?? this.analysis,
        video: video,
        avOffsetMs: avOffsetMs,
        contentStartSeconds: contentStartSeconds,
        contentEndSeconds: contentEndSeconds,
        alignmentRating: alignmentRating,
      );

  /// Sets [contentStartSeconds]/[contentEndSeconds] verbatim — a null ARGUMENT
  /// clears the field rather than leaving it alone.
  ///
  /// Deliberately not folded into [copyWith], where null already means "keep
  /// what's there". Clearing the window back to "work it out from the audio" is
  /// the thing a user does when their first guess made the alignment worse, so
  /// it has to be expressible.
  PieceMedia withContentWindow({double? startSeconds, double? endSeconds}) =>
      PieceMedia(
        id: id,
        label: label,
        kind: kind,
        alignmentKey: alignmentKey,
        audio: audio,
        analysis: analysis,
        video: video,
        avOffsetMs: avOffsetMs,
        contentStartSeconds: startSeconds,
        contentEndSeconds: endSeconds,
        alignmentRating: alignmentRating,
      );

  /// This medium with [rating] in place of its current one; null clears it.
  PieceMedia withAlignmentRating(AlignmentRating? rating) => PieceMedia(
        id: id,
        label: label,
        kind: kind,
        alignmentKey: alignmentKey,
        audio: audio,
        analysis: analysis,
        video: video,
        avOffsetMs: avOffsetMs,
        contentStartSeconds: contentStartSeconds,
        contentEndSeconds: contentEndSeconds,
        alignmentRating: rating,
      );

  /// Every one of [audio], [analysis] and [video] that names [from], pointed
  /// at [to] instead, for when a medium's file is replaced by a smaller copy
  /// of itself (see `video_shrinker_io.dart`). An imported video is all three
  /// at once; a recorded demo's video is only [video].
  ///
  /// The [alignmentKey] is kept: the replacement carries the same audio, so
  /// the cached anchors still describe it.
  PieceMedia withFileReplaced(MediaRef from, MediaRef to) {
    MediaRef? swap(MediaRef? ref) => ref == from ? to : ref;
    return PieceMedia(
      id: id,
      label: label,
      kind: kind,
      alignmentKey: alignmentKey,
      audio: swap(audio),
      analysis: swap(analysis),
      video: swap(video),
      avOffsetMs: avOffsetMs,
      contentStartSeconds: contentStartSeconds,
      contentEndSeconds: contentEndSeconds,
      alignmentRating: alignmentRating,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'kind': kind.name,
        'alignmentKey': alignmentKey,
        if (audio != null) 'audio': audio!.toJson(),
        if (analysis != null) 'analysis': analysis!.toJson(),
        if (video != null) 'video': video!.toJson(),
        'avOffsetMs': avOffsetMs,
        // Omitted when unset, so an entry written by a build that had never
        // heard of a content window and one the user has never annotated are
        // the same bytes on disk.
        if (contentStartSeconds != null)
          'contentStartSeconds': contentStartSeconds,
        if (contentEndSeconds != null) 'contentEndSeconds': contentEndSeconds,
        if (alignmentRating != null)
          'alignmentRating': alignmentRating!.toJson(),
      };

  /// Null for anything that doesn't parse, so one corrupt entry costs its own
  /// medium and not the whole list. See [MediaRef.fromJson].
  static PieceMedia? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final label = json['label'];
    if (id is! String || id.isEmpty || label is! String) return null;
    final kind =
        MediaKind.values.where((k) => k.name == json['kind']).firstOrNull;
    if (kind == null) return null;
    final alignmentKey = json['alignmentKey'];
    if (alignmentKey is! String) return null;
    return PieceMedia(
      id: id,
      label: label,
      kind: kind,
      alignmentKey: alignmentKey,
      audio: MediaRef.fromJson(json['audio']),
      analysis: MediaRef.fromJson(json['analysis']),
      video: MediaRef.fromJson(json['video']),
      avOffsetMs: (json['avOffsetMs'] as num?)?.toInt() ?? 0,
      // Absent in everything written before content windows existed, and
      // absent for anything the user hasn't annotated — both read as null,
      // which is the "infer it" default, so no schema version is needed.
      contentStartSeconds: (json['contentStartSeconds'] as num?)?.toDouble(),
      contentEndSeconds: (json['contentEndSeconds'] as num?)?.toDouble(),
      alignmentRating: AlignmentRating.fromJson(json['alignmentRating']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PieceMedia &&
      other.id == id &&
      other.label == label &&
      other.kind == kind &&
      other.alignmentKey == alignmentKey &&
      other.audio == audio &&
      other.analysis == analysis &&
      other.video == video &&
      other.avOffsetMs == avOffsetMs &&
      other.contentStartSeconds == contentStartSeconds &&
      other.contentEndSeconds == contentEndSeconds &&
      other.alignmentRating == alignmentRating;

  @override
  int get hashCode => Object.hash(id, label, kind, alignmentKey, audio,
      analysis, video, avOffsetMs, contentStartSeconds, contentEndSeconds,
      alignmentRating);

  @override
  String toString() => 'PieceMedia($id, ${kind.name}, "$label")';
}
