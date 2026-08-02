/// The user's view OF their pieces, as distinct from the pieces themselves:
/// which collections exist and what is in them, which pieces are hidden from
/// the everyday list, and what the user renamed them to.
///
/// Nothing here is stored on [Piece]. A `Piece` is content — it has no `==`, so
/// identity comparison can drive re-engraving — and hanging mutable library
/// state off it would rebuild the notation every time a chip was tapped.
///
/// Piece IDs are the only linkage. No path, no title, no list position is ever
/// stored as a key; see `piece_storage_base.dart` for why anything
/// location-derived is the bug this codebase already fixed once. IDs naming
/// pieces that no longer exist are inert — skipped on read, pruned on load —
/// so a stale library can never hide or reorder the wrong song.
library;

import 'piece.dart';
import '../services/piece_storage_base.dart' show slugifyTitle;

/// One user-defined collection: "Suzuki 1", "This week", "Learned".
///
/// [pieceIds] is BOTH the membership set and the hand-set order — deliberately
/// one structure, not two. A separate order map could disagree with the
/// membership (an ordered ID that is not a member, a member with no slot), and
/// every read would have to reconcile them. Here a piece is in the collection
/// iff it is in this list, and its position is where it is.
class Collection {
  /// Stable across renames, so a selected filter (and any persisted reference)
  /// survives one, and two collections may share a name without colliding.
  final String id;

  /// Display only. Never a key.
  final String name;

  final List<String> pieceIds;

  const Collection({
    required this.id,
    required this.name,
    this.pieceIds = const [],
  });

  /// Null when [json] isn't a usable collection row, so a corrupt library
  /// costs the user a chip rather than throwing away the whole file.
  static Collection? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.isEmpty || name is! String) return null;
    final ids = json['pieceIds'];
    return Collection(
      id: id,
      name: name,
      pieceIds: ids is List ? [for (final e in ids) if (e is String) e] : const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'pieceIds': pieceIds,
      };

  Collection copyWith({String? name, List<String>? pieceIds}) => Collection(
        id: id,
        name: name ?? this.name,
        pieceIds: pieceIds ?? this.pieceIds,
      );

  @override
  bool operator ==(Object other) =>
      other is Collection &&
      other.id == id &&
      other.name == name &&
      _listEq(other.pieceIds, pieceIds);

  @override
  int get hashCode => Object.hash(id, name, Object.hashAll(pieceIds));
}

/// A collection's stable identity: a slug of the name it was created with plus
/// the creation timestamp — the same shape as `scannedPieceId`, and stable for
/// the same reason. Renaming does not change it.
String collectionId(String name, {required int createdAtMillis}) =>
    '${slugifyTitle(name)}_$createdAtMillis';

/// The whole library, as one immutable value. Every helper below takes one and
/// returns a new one; nothing mutates in place.
class PieceLibrary {
  static const schemaVersion = 1;

  /// Chip-row display order.
  final List<Collection> collections;

  /// Pieces kept out of the everyday list. Bundled fixtures can only ever be
  /// hidden — their MusicXML ships inside the app bundle — but a user piece can
  /// be hidden too.
  final Set<String> hiddenIds;

  /// Piece ID → the title the user chose. Wins over [Piece.title] in
  /// [applyLibrary]; clearing the entry reverts to whatever the score or the
  /// fixture record says.
  final Map<String, String> titleOverrides;

  /// The highest [seedLibrary] step already applied. 0 = never seeded.
  final int seedVersion;

  const PieceLibrary({
    this.collections = const [],
    this.hiddenIds = const {},
    this.titleOverrides = const {},
    this.seedVersion = 0,
  });

  static const empty = PieceLibrary();

  /// Tolerant by design, in the spirit of `Section.fromJson`: every field
  /// defaults, an unrecognised `version` still decodes what it recognises, and
  /// a malformed collection row is skipped rather than thrown on. A corrupt
  /// library must lose chips, not songs.
  factory PieceLibrary.fromJson(Map<String, dynamic> json) {
    final rawCollections = json['collections'];
    final rawHidden = json['hidden'];
    final rawTitles = json['titles'];
    return PieceLibrary(
      collections: rawCollections is List
          ? [
              for (final e in rawCollections) ?Collection.tryFromJson(e)
            ]
          : const [],
      hiddenIds: rawHidden is List
          ? {for (final e in rawHidden) if (e is String) e}
          : const {},
      titleOverrides: rawTitles is Map
          ? {
              for (final entry in rawTitles.entries)
                if (entry.key is String && entry.value is String)
                  entry.key as String: entry.value as String
            }
          : const {},
      seedVersion: json['seedVersion'] is int ? json['seedVersion'] as int : 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': schemaVersion,
        'collections': [for (final c in collections) c.toJson()],
        // Sorted so the blob is stable between saves that changed nothing else.
        'hidden': hiddenIds.toList()..sort(),
        'titles': titleOverrides,
        'seedVersion': seedVersion,
      };

  PieceLibrary copyWith({
    List<Collection>? collections,
    Set<String>? hiddenIds,
    Map<String, String>? titleOverrides,
    int? seedVersion,
  }) =>
      PieceLibrary(
        collections: collections ?? this.collections,
        hiddenIds: hiddenIds ?? this.hiddenIds,
        titleOverrides: titleOverrides ?? this.titleOverrides,
        seedVersion: seedVersion ?? this.seedVersion,
      );

  Collection? collectionById(String id) {
    for (final c in collections) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Value equality (deep) so a no-op mutation neither rebuilds the UI nor
  /// writes to storage.
  @override
  bool operator ==(Object other) =>
      other is PieceLibrary &&
      other.seedVersion == seedVersion &&
      _listEq(other.collections, collections) &&
      _setEq(other.hiddenIds, hiddenIds) &&
      _mapEq(other.titleOverrides, titleOverrides);

  @override
  int get hashCode => Object.hash(
        Object.hashAll(collections),
        Object.hashAllUnordered(hiddenIds),
        Object.hashAllUnordered(titleOverrides.entries.map((e) => e.key)),
        seedVersion,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Collections
// ─────────────────────────────────────────────────────────────────────────────

/// Appends a collection named [name]. Blank names are rejected (returns [lib]
/// unchanged). Duplicate names are allowed — collections are keyed by ID — but
/// the generated ID is nudged forward until it is free, so creating two in the
/// same millisecond can't collide.
PieceLibrary addCollection(
  PieceLibrary lib, {
  required String name,
  required int nowMillis,
}) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return lib;
  var millis = nowMillis;
  var id = collectionId(trimmed, createdAtMillis: millis);
  while (lib.collectionById(id) != null) {
    id = collectionId(trimmed, createdAtMillis: ++millis);
  }
  return lib.copyWith(collections: [
    ...lib.collections,
    Collection(id: id, name: trimmed),
  ]);
}

/// Renames a collection. The ID and the membership are untouched, so a filter
/// selected on the old name stays selected.
PieceLibrary renameCollection(PieceLibrary lib, String id, String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return lib;
  return lib.copyWith(collections: [
    for (final c in lib.collections) c.id == id ? c.copyWith(name: trimmed) : c,
  ]);
}

/// Drops a collection. The pieces themselves are untouched — this removes a
/// label, never a song.
PieceLibrary removeCollection(PieceLibrary lib, String id) => lib.copyWith(
      collections: [
        for (final c in lib.collections)
          if (c.id != id) c
      ],
    );

/// Moves a chip within the row; see [reorderedIds] for the index convention.
PieceLibrary reorderCollections(PieceLibrary lib, int oldIndex, int newIndex) {
  final ids = [for (final c in lib.collections) c.id];
  final moved = reorderedIds(ids, oldIndex, newIndex);
  if (_listEq(moved, ids)) return lib;
  final byId = {for (final c in lib.collections) c.id: c};
  return lib.copyWith(collections: [for (final id in moved) byId[id]!]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Membership and order
// ─────────────────────────────────────────────────────────────────────────────

/// Adds [pieceId] to the end of [collectionId]'s order. Idempotent — tagging
/// twice does not duplicate, and does not move an existing member.
PieceLibrary tagPiece(
  PieceLibrary lib, {
  required String pieceId,
  required String collectionId,
}) =>
    _mapCollection(
      lib,
      collectionId,
      (c) => c.pieceIds.contains(pieceId)
          ? c
          : c.copyWith(pieceIds: [...c.pieceIds, pieceId]),
    );

PieceLibrary untagPiece(
  PieceLibrary lib, {
  required String pieceId,
  required String collectionId,
}) =>
    _mapCollection(
      lib,
      collectionId,
      (c) => c.copyWith(pieceIds: [
        for (final id in c.pieceIds)
          if (id != pieceId) id
      ]),
    );

/// Sets [pieceId]'s collections to exactly [collectionIds] in one write — what
/// the tag dialog's Save does.
///
/// Position is PRESERVED in collections the piece stays in. A naive "clear then
/// re-add" would silently reset a hand-set order every time the dialog was
/// opened and saved, even when nothing was checked or unchecked.
PieceLibrary setPieceTags(
  PieceLibrary lib, {
  required String pieceId,
  required Set<String> collectionIds,
}) {
  final next = [
    for (final c in lib.collections)
      if (collectionIds.contains(c.id))
        c.pieceIds.contains(pieceId)
            ? c // already a member: leave it exactly where it is
            : c.copyWith(pieceIds: [...c.pieceIds, pieceId])
      else if (c.pieceIds.contains(pieceId))
        c.copyWith(pieceIds: [
          for (final id in c.pieceIds)
            if (id != pieceId) id
        ])
      else
        c,
  ];
  return lib.copyWith(collections: next);
}

/// Applies a drag within [collectionId].
///
/// [visibleIds] is the collection AS DISPLAYED — stale and hidden members
/// already filtered out — and [oldIndex]/[newIndex] index into that list, not
/// into the stored order (see [reorderedIds] for the index convention). Members
/// not in [visibleIds] keep their stored slots, so hiding a piece cannot shuffle
/// the ones around it, and un-hiding it puts it back where it was.
PieceLibrary reorderInCollection(
  PieceLibrary lib,
  String collectionId,
  List<String> visibleIds,
  int oldIndex,
  int newIndex,
) {
  final moved = reorderedIds(visibleIds, oldIndex, newIndex);
  if (_listEq(moved, visibleIds)) return lib;
  return setCollectionOrder(lib, collectionId, moved);
}

/// Rewrites [collectionId]'s order so that its members that appear in
/// [orderedVisibleIds] fall in that sequence, while members absent from it keep
/// the slots they already hold.
PieceLibrary setCollectionOrder(
  PieceLibrary lib,
  String collectionId,
  List<String> orderedVisibleIds,
) =>
    _mapCollection(lib, collectionId, (c) {
      final visible = orderedVisibleIds.toSet();
      final queue = [
        for (final id in orderedVisibleIds)
          if (c.pieceIds.contains(id)) id
      ];
      var next = 0;
      return c.copyWith(pieceIds: [
        for (final id in c.pieceIds)
          if (visible.contains(id)) queue[next++] else id
      ]);
    });

/// Moves the item at [oldIndex] so it ends up at [newIndex].
///
/// [newIndex] is the FINAL destination, already accounting for the moved item's
/// removal — which is exactly what `ReorderableListView.onReorderItem` reports.
/// The older `onReorder` callback instead reported an index counting the dragged
/// row as still present, so a downward move was off by one; that adjustment now
/// belongs to the SDK and is deliberately not duplicated here.
///
/// Returns the same list instance when the move is a no-op.
List<String> reorderedIds(List<String> ids, int oldIndex, int newIndex) {
  if (oldIndex < 0 || oldIndex >= ids.length) return ids;
  final target = newIndex.clamp(0, ids.length - 1);
  if (target == oldIndex) return ids;
  final next = [...ids];
  next.insert(target, next.removeAt(oldIndex));
  return next;
}

// ─────────────────────────────────────────────────────────────────────────────
// Hidden, titles, lifecycle
// ─────────────────────────────────────────────────────────────────────────────

PieceLibrary setHidden(PieceLibrary lib, String pieceId, bool hidden) {
  if (lib.hiddenIds.contains(pieceId) == hidden) return lib;
  return lib.copyWith(
    hiddenIds: hidden
        ? {...lib.hiddenIds, pieceId}
        : {
            for (final id in lib.hiddenIds)
              if (id != pieceId) id
          },
  );
}

/// Sets, or with a null/blank [title] clears, the user's name for [pieceId].
/// Clearing reverts to the score's own title — nothing is lost by renaming.
PieceLibrary setTitleOverride(PieceLibrary lib, String pieceId, String? title) {
  final trimmed = title?.trim();
  final next = {...lib.titleOverrides};
  if (trimmed == null || trimmed.isEmpty) {
    next.remove(pieceId);
  } else {
    next[pieceId] = trimmed;
  }
  return lib.copyWith(titleOverrides: next);
}

/// Everything the library knew about [pieceId], gone: membership in every
/// collection, its hidden flag, its title override. The library half of delete.
PieceLibrary forgetPiece(PieceLibrary lib, String pieceId) => lib.copyWith(
      collections: [
        for (final c in lib.collections)
          c.pieceIds.contains(pieceId)
              ? c.copyWith(pieceIds: [
                  for (final id in c.pieceIds)
                    if (id != pieceId) id
                ])
              : c
      ],
      hiddenIds: {
        for (final id in lib.hiddenIds)
          if (id != pieceId) id
      },
      titleOverrides: {...lib.titleOverrides}..remove(pieceId),
    );

/// Drops references to pieces that no longer exist — one deleted on another
/// device, or a fixture removed from a later build. Run once at load; until
/// then stale IDs are merely inert.
PieceLibrary pruneToExisting(PieceLibrary lib, Set<String> existingIds) {
  final pruned = lib.copyWith(
    collections: [
      for (final c in lib.collections)
        c.copyWith(pieceIds: [
          for (final id in c.pieceIds)
            if (existingIds.contains(id)) id
        ])
    ],
    hiddenIds: {
      for (final id in lib.hiddenIds)
        if (existingIds.contains(id)) id
    },
    titleOverrides: {
      for (final e in lib.titleOverrides.entries)
        if (existingIds.contains(e.key)) e.key: e.value
    },
  );
  return pruned == lib ? lib : pruned;
}

// ─────────────────────────────────────────────────────────────────────────────
// Reads — all derived, nothing stored twice
// ─────────────────────────────────────────────────────────────────────────────

/// Which collections [pieceId] belongs to. Derived by scanning, never stored: a
/// persisted reverse index would be a second copy of the membership, free to
/// disagree with the first.
Set<String> collectionIdsOf(PieceLibrary lib, String pieceId) => {
      for (final c in lib.collections)
        if (c.pieceIds.contains(pieceId)) c.id
    };

/// The list to render.
///
/// Title overrides applied; hidden pieces dropped unless [showHidden]; and when
/// [collectionId] is given, only that collection's members, in its hand-set
/// order.
///
/// With no collection the input order is returned untouched — "All" IS the
/// repository's order (fixtures first, then user pieces oldest-first), so there
/// is deliberately no second ordering to keep in sync with the first.
///
/// IDs in a collection with no matching piece are skipped, not errors. An
/// unknown [collectionId] yields an empty list; `resolveActiveCollection` in
/// `piece_library_view.dart` keeps the UI from ever asking for one.
List<Piece> applyLibrary(
  PieceLibrary lib,
  List<Piece> pieces, {
  String? collectionId,
  bool showHidden = false,
}) {
  final Iterable<Piece> selected;
  if (collectionId == null) {
    selected = pieces;
  } else {
    final c = lib.collectionById(collectionId);
    if (c == null) return const [];
    final byId = {for (final p in pieces) p.id: p};
    selected = [for (final id in c.pieceIds) ?byId[id]];
  }
  return [
    for (final p in selected)
      if (showHidden || !lib.hiddenIds.contains(p.id)) _titled(lib, p)
  ];
}

/// How many of [pieces] are hidden — the count behind "10 hidden pieces". Scoped
/// to [collectionId] when one is active, so the footer never promises pieces
/// that showing hidden wouldn't actually reveal.
int hiddenCount(PieceLibrary lib, List<Piece> pieces, {String? collectionId}) {
  if (collectionId == null) {
    return pieces.where((p) => lib.hiddenIds.contains(p.id)).length;
  }
  final members = lib.collectionById(collectionId)?.pieceIds.toSet();
  if (members == null) return 0;
  return pieces
      .where((p) => members.contains(p.id) && lib.hiddenIds.contains(p.id))
      .length;
}

/// Returns the SAME instance when there is no override, so identity comparison
/// downstream (`selectedPieceProvider`) stays meaningful.
Piece _titled(PieceLibrary lib, Piece piece) {
  final title = lib.titleOverrides[piece.id];
  return (title == null || title == piece.title)
      ? piece
      : piece.copyWith(title: title);
}

// ─────────────────────────────────────────────────────────────────────────────
// Seeding
// ─────────────────────────────────────────────────────────────────────────────

/// The seeding steps this build knows about. Bump when adding one.
const currentSeedVersion = 1;

/// The name of the collection [seedLibrary] files the OMR comparison fixtures
/// under.
const omrDemoCollectionName = 'OMR demos';

/// [library] with any seeding step newer than its `seedVersion` applied.
///
/// Version-gated so each step runs exactly once, ever. That is what makes
/// seeding safe to call on every launch AND non-destructive: a user who
/// un-hides one of the demos never sees a later release re-hide it.
///
/// Step 1 hides the `abc_*`/`homr_*` OMR comparison pairs and files them under
/// [omrDemoCollectionName]. They ship as a side-by-side demonstration of scan
/// quality, but they are 10 of the 13 bundled pieces — pure noise for everyday
/// practice (docs/plan.md §4). Hidden rather than removed: the comparison is
/// one toggle away.
///
/// [omrDemoIds] is a parameter so this file stays free of `PieceRepository`.
PieceLibrary seedLibrary(
  PieceLibrary library, {
  required List<String> omrDemoIds,
  required int nowMillis,
}) {
  var lib = library;
  if (lib.seedVersion < 1 && omrDemoIds.isNotEmpty) {
    lib = addCollection(lib, name: omrDemoCollectionName, nowMillis: nowMillis);
    final id = lib.collections.last.id;
    for (final pieceId in omrDemoIds) {
      lib = tagPiece(lib, pieceId: pieceId, collectionId: id);
      lib = setHidden(lib, pieceId, true);
    }
  }
  return lib.seedVersion >= currentSeedVersion
      ? lib
      : lib.copyWith(seedVersion: currentSeedVersion);
}

// ─────────────────────────────────────────────────────────────────────────────

PieceLibrary _mapCollection(
  PieceLibrary lib,
  String id,
  Collection Function(Collection) f,
) {
  final target = lib.collectionById(id);
  if (target == null) return lib;
  final replaced = f(target);
  if (replaced == target) return lib;
  return lib.copyWith(collections: [
    for (final c in lib.collections) c.id == id ? replaced : c,
  ]);
}

bool _listEq<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _setEq<T>(Set<T> a, Set<T> b) =>
    identical(a, b) || (a.length == b.length && a.containsAll(b));

bool _mapEq<K, V>(Map<K, V> a, Map<K, V> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    if (!b.containsKey(e.key) || b[e.key] != e.value) return false;
  }
  return true;
}
