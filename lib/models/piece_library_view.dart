/// Pure presentation logic for the piece list and its editing actions.
///
/// Flutter-free (no widget imports) and unit-tested, following the house
/// convention set by `piece_layout.dart` and `staff_zoom.dart`: layout and copy
/// decisions live here as plain functions, and the widgets stay thin.
library;


/// Whether [title] matches the search box's [query].
///
/// Every word of the query must appear somewhere in the title, in any order and
/// ignoring case and punctuation — so "devils dream" finds "The Devil's Dream"
/// and "mount" finds "I Love the Mountains". An empty query matches everything.
bool matchesSearch(String title, String query) {
  final words = _searchText(query).split(' ').where((w) => w.isNotEmpty);
  final haystack = _searchText(title);
  return words.every(haystack.contains);
}

String _searchText(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r"['’]"), '')
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ');

/// What an empty list should say.
///
/// An empty library is an onboarding problem (the add-piece button is already
/// on screen); an all-hidden list is not — the "hidden pieces" footer is the
/// way out, so the message must not claim the pieces don't exist.
/// [hiddenCount] is scoped by the caller to the list being shown.
String libraryEmptyMessage({
  required bool hasAnyPieces,
  required int hiddenCount,
}) {
  if (!hasAnyPieces) {
    return 'No pieces yet.\nScan a page or import from ABC to get started.';
  }
  return hiddenCount > 0 ? 'All pieces are hidden.' : 'Nothing to show.';
}

/// Tablet-class width: the piece list keeps its filter panel out as a
/// sidebar, where narrower screens slide it in as a drawer. The app's one
/// width breakpoint, shared with `measuresPerRowForWidth`.
bool isWideLayout(double widthPx) => widthPx >= 600;

/// The always-out filter sidebar on a wide layout: about a third of the
/// window, so a landscape phone keeps most of it for titles, and never wider
/// than an iPad needs.
double sidebarWidth(double widthPx) => (widthPx * 0.35).clamp(240.0, 320.0);
