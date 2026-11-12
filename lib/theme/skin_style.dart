import 'package:flutter/material.dart';

/// How the piece list draws a row.
enum PieceRowStyle {
  /// Inset grouped list rows (Classic).
  list,

  /// Colourful cards in a grid (Playful).
  cards,
}

/// What a skin changes beyond [ThemeData]'s colours, type and shapes: the
/// piece list's row style, the card colours, and the friendlier wording.
///
/// Read with [SkinStyle.of]; a theme without the extension is Classic.
@immutable
class SkinStyle extends ThemeExtension<SkinStyle> {
  const SkinStyle({
    required this.rowStyle,
    required this.cardColors,
    required this.cardInk,
    required this.friendlyCopy,
    required this.groupRadius,
    this.mascots = false,
    this.filtersInSearch = false,
  });

  final PieceRowStyle rowStyle;

  /// Card backgrounds, cycled down the grid.
  final List<Color> cardColors;

  /// Text on a card; dark enough on every [cardColors] entry.
  final Color cardInk;

  /// "What shall we play?" rather than "Pieces", and so on.
  final bool friendlyCopy;

  /// Corner radius of grouped lists, panels and fields.
  final double groupRadius;

  /// Stringlings peek over the piece screen's title.
  final bool mascots;

  /// On a phone, the Filters button sits at the end of the search field
  /// rather than at the left of the app bar.
  final bool filtersInSearch;

  static const classic = SkinStyle(
    rowStyle: PieceRowStyle.list,
    cardColors: [Color(0xFFE8EAF6)],
    cardInk: Color(0xFF1C1B1F),
    friendlyCopy: false,
    groupRadius: 10,
  );

  static SkinStyle of(BuildContext context) =>
      Theme.of(context).extension<SkinStyle>() ?? classic;

  String get listTitle => friendlyCopy ? 'What shall we play?' : 'Pieces';
  String get recentsLabel => friendlyCopy ? 'Played lately' : 'Recents';
  String get booksLabel => friendlyCopy ? 'My books' : 'Books';

  /// The phone's three segments are ~114pt each on an SE, too narrow for
  /// Playful's longer words in its heavy type; the sidebar keeps the long ones.
  String get recentsTab => friendlyCopy ? 'Lately' : recentsLabel;
  String get booksTab => friendlyCopy ? 'Books' : booksLabel;
  String get allTab => friendlyCopy ? 'All songs' : allLabel;
  String get allLabel => friendlyCopy ? 'All my music' : 'All Pieces';
  String get searchHint =>
      friendlyCopy ? 'Find a song' : 'Title, composer or keyword';

  @override
  SkinStyle copyWith({
    PieceRowStyle? rowStyle,
    List<Color>? cardColors,
    Color? cardInk,
    bool? friendlyCopy,
    double? groupRadius,
    bool? mascots,
    bool? filtersInSearch,
  }) =>
      SkinStyle(
        rowStyle: rowStyle ?? this.rowStyle,
        cardColors: cardColors ?? this.cardColors,
        cardInk: cardInk ?? this.cardInk,
        friendlyCopy: friendlyCopy ?? this.friendlyCopy,
        groupRadius: groupRadius ?? this.groupRadius,
        mascots: mascots ?? this.mascots,
        filtersInSearch: filtersInSearch ?? this.filtersInSearch,
      );

  /// Skins switch whole, so there is nothing to interpolate.
  @override
  SkinStyle lerp(SkinStyle? other, double t) =>
      t < 0.5 || other == null ? this : other;
}
