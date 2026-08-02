/// Pure presentation logic for the piece list and the Manage screen.
///
/// Flutter-free (no widget imports) and unit-tested, following the house
/// convention set by `piece_layout.dart` and `staff_zoom.dart`: layout and copy
/// decisions live here as plain functions, and the widgets stay thin.
library;

import 'piece.dart';
import 'piece_library.dart';

/// One row as the Manage screen needs it: the piece plus the three library
/// facts about it that deliberately are NOT fields on [Piece].
typedef LibraryRow = ({
  Piece piece,
  bool isBundled,
  bool hidden,
  List<String> collectionNames,
});

/// Builds the Manage screen's rows.
///
/// [isBundled] is passed in rather than derived from [Piece.musicXmlAssetPath],
/// which would be WRONG: once a bundled fixture has been edited the repository
/// re-points it at its writable copy, making it field-for-field
/// indistinguishable from a scan. Deciding Hide-vs-Delete on the path field
/// would silently offer Delete on exactly the fixtures the user had edited.
List<LibraryRow> libraryRows(
  PieceLibrary lib,
  List<Piece> pieces,
  bool Function(String id) isBundled,
) {
  final nameById = {for (final c in lib.collections) c.id: c.name};
  return [
    for (final p in pieces)
      (
        piece: p,
        isBundled: isBundled(p.id),
        hidden: lib.hiddenIds.contains(p.id),
        collectionNames: [
          for (final c in lib.collections)
            if (c.pieceIds.contains(p.id)) nameById[c.id]!
        ],
      ),
  ];
}

/// A row's second line.
///
/// The collection names are dropped when a chip is already selected — repeating
/// "Suzuki 1" on every row under the Suzuki 1 filter is noise.
String pieceSubtitle(
  Piece piece,
  List<String> collectionNames, {
  required bool includeCollections,
}) {
  final sections = '${piece.sections.length} sections';
  if (!includeCollections || collectionNames.isEmpty) return sections;
  return '$sections · ${collectionNames.join(' · ')}';
}

/// What an empty list should say, and whether it offers a way out.
///
/// Genuinely different situations, so different messages: an empty filter is a
/// curation problem (send them to Manage), an empty library is an onboarding one
/// (the Scan/Import FABs are already on screen, so no button), and an all-hidden
/// list is neither — the "show hidden" footer is the way out, so the message
/// must not claim the pieces don't exist.
///
/// [hiddenCount] is scoped to the active collection by the caller, which is what
/// makes the all-hidden case distinguishable from the genuinely-empty one. A
/// seeded install opens with "OMR demos" holding ten hidden pieces; saying "No
/// pieces in OMR demos yet" there would be a plain lie.
typedef LibraryEmptyState = ({String message, bool offerManage});

LibraryEmptyState libraryEmptyState({
  required bool hasAnyPieces,
  required String? collectionName,
  required int hiddenCount,
}) {
  if (collectionName != null) {
    return hiddenCount > 0
        ? (
            message: hiddenCount == 1
                ? 'The one piece in "$collectionName" is hidden.'
                : 'All $hiddenCount pieces in "$collectionName" are hidden.',
            offerManage: false,
          )
        : (message: 'No pieces in "$collectionName" yet.', offerManage: true);
  }
  if (!hasAnyPieces) {
    return (
      message: 'No pieces yet.\nScan a page or import from ABC to get started.',
      offerManage: false,
    );
  }
  return (
    message: hiddenCount > 0 ? 'All pieces are hidden.' : 'Nothing to show.',
    offerManage: hiddenCount == 0,
  );
}

/// The active collection ID, or null if it names one that no longer exists.
///
/// A guard, not a nicety: deleting the selected collection (or restoring a
/// library from another device) would otherwise leave a chip selected that
/// filters everything away, with no chip visible to deselect.
String? resolveActiveCollection(String? requested, List<Collection> collections) {
  if (requested == null) return null;
  for (final c in collections) {
    if (c.id == requested) return requested;
  }
  return null;
}

/// Whether a Manage row has room to label its three action buttons.
///
/// Below this a phone-width row spends 16 + 40 (drag handle) + 3×40 + 16 =
/// 192pt on chrome, leaving ~200pt for the title — enough for icons only. The
/// same 600pt breakpoint as `measuresPerRowForWidth`; see
/// `piece_detail_screen.dart`'s compact-layout switch for the precedent.
bool manageRowUsesLabeledActions(double widthPx) => widthPx >= 600;
