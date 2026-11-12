import 'package:flutter/material.dart';

import '../models/piece_meta.dart';
import '../models/piece_filter.dart';
import '../theme/skin_style.dart';

/// A row's second line: who and what key, plus where the player left off on
/// Recents. Parts that aren't known yet (metadata still loading, no composer)
/// are left out rather than shown as blanks.
String pieceRowSubtitle(PieceListRow row,
    {required bool recents, required bool wide}) {
  final m = row.meta;
  return [
    ?m?.composer,
    // The wide layout has its own Key column.
    if (!wide && m != null) m.keyName,
    if (recents && row.activity?.lastSection != null) row.activity!.lastSection!,
    if (m == null && row.piece.sections.isNotEmpty)
      '${row.piece.sections.length} sections',
  ].join(' · ');
}

/// Classic: one row of an inset grouped list. On a wide screen it adds key,
/// time, keywords and last-played columns.
class PieceListTile extends StatelessWidget {
  const PieceListTile({
    super.key,
    required this.row,
    required this.subtitle,
    required this.wide,
    required this.lastPlayed,
    required this.onTap,
  });

  final PieceListRow row;
  final String subtitle;
  final bool wide;

  /// "Today", "3 days ago"; only shown wide.
  final String? lastPlayed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final small = theme.textTheme.bodyMedium?.copyWith(color: muted);
    return InkWell(
      onTap: onTap,
      child: LayoutBuilder(builder: (context, c) {
        final rowWidth = c.maxWidth;
        // The subtitle leaves the key out when wide; put it back if even the
        // Key column doesn't fit.
        final keyInColumn = rowWidth >= _chrome + _minTitle + 96;
        final line = wide && !keyInColumn && row.meta != null
            ? [if (subtitle.isNotEmpty) subtitle, row.meta!.keyName].join(' · ')
            : subtitle;
        return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        child: Row(
          children: [
            if (row.bookNumber case final n?) ...[
              BookNumberBadge(number: n),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(row.piece.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge),
                  if (line.isNotEmpty)
                    Text(line,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                ],
              ),
            ),
            if (wide)
              ..._columns(
                rowWidth,
                key: Text(row.meta?.keyName ?? '', style: small),
                time: Text(row.meta?.time ?? '', style: small),
                keywords: Text(
                  row.keywordNames.map((k) => '#$k').join('  '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: small,
                ),
                lastPlayed: Text(lastPlayed ?? '—', style: small),
              ),
            SizedBox(
              width: 24,
              child: row.hasRecording
                  ? Icon(Icons.graphic_eq,
                      size: 18, color: muted, semanticLabel: 'Has a recording')
                  : null,
            ),
            Icon(Icons.chevron_right, color: theme.colorScheme.outline),
          ],
        ),
      );
      }),
    );
  }

  /// The wide row's extra columns, as many as fit while the title keeps at
  /// least [_minTitle]: a landscape phone beside the 320pt sidebar has ~545pt,
  /// and all four fixed columns there squeezed titles to "Ga…". Dropped in
  /// order of least use: keywords, then time, then last played; key stays.
  static const _minTitle = 220.0;

  /// Padding, number badge, recording mark and chevron.
  static const _chrome = 16 + 12 + 42 + 24 + 24.0;

  static List<Widget> _columns(
    double rowWidth, {
    required Widget key,
    required Widget time,
    required Widget keywords,
    required Widget lastPlayed,
  }) {
    var room = rowWidth - _chrome - _minTitle;
    final out = <Widget>[];
    bool take(double w) {
      if (room < w) return false;
      room -= w;
      return true;
    }

    final showKey = take(96);
    final showLast = take(96);
    final showTime = take(44);
    final showKeywords = take(200);
    if (showKey) out.add(SizedBox(width: 96, child: key));
    if (showTime) out.add(SizedBox(width: 44, child: time));
    if (showKeywords) out.add(SizedBox(width: 200, child: keywords));
    if (showLast) out.add(SizedBox(width: 96, child: lastPlayed));
    return out;
  }
}

/// Playful: a colourful card in a grid.
class PieceCard extends StatelessWidget {
  const PieceCard({
    super.key,
    required this.row,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  final PieceListRow row;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = SkinStyle.of(context).cardInk;
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(22),
      elevation: 0,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (row.bookNumber case final n?) ...[
                    BookNumberBadge(number: n, inverse: true),
                    const SizedBox(width: 4),
                  ],
                  // "3♯ A maj." beside a book number and the recording mark
                  // just fits a portrait iPad's 156pt card; a longer key
                  // ("3♯ F♯ min.") ellipsizes there rather than overflows.
                  Expanded(
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: row.meta != null
                          ? Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 3),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.75),
                                borderRadius: BorderRadius.circular(13),
                              ),
                              child: Text(cardKeyLabel(row.meta!),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelMedium?.copyWith(
                                      color: ink, fontWeight: FontWeight.w900)),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                  if (row.hasRecording)
                    Icon(Icons.graphic_eq,
                        size: 18, color: ink, semanticLabel: 'Has a recording'),
                ],
              ),
              const Spacer(),
              Text(row.piece.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                      color: ink, fontWeight: FontWeight.w900, height: 1.15)),
              if (subtitle.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: ink.withValues(alpha: 0.85),
                        fontWeight: FontWeight.w700)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A piece's number in the selected book.
class BookNumberBadge extends StatelessWidget {
  const BookNumberBadge({super.key, required this.number, this.inverse = false});

  final int number;

  /// Dark-on-light for a coloured card; the default is the theme's accent.
  final bool inverse;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = SkinStyle.of(context).cardInk;
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: inverse ? ink : scheme.primaryContainer,
        shape: BoxShape.circle,
      ),
      child: Text('$number',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: inverse ? Colors.white : scheme.onPrimaryContainer,
          )),
    );
  }
}
