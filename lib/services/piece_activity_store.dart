import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'piece_display_prefs.dart' show sharedPreferencesProvider;

/// When a piece was last opened on THIS device, and where the player left off.
///
/// What the piece list's Recents tab is built from.
class PieceActivity {
  final DateTime openedAt;

  /// "B section" or "Bars 9–16": the selection on screen when the piece was
  /// last left. Null when nothing was selected.
  final String? lastSection;

  const PieceActivity({required this.openedAt, this.lastSection});

  static PieceActivity? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final at = json['openedAt'];
    if (at is! int) return null;
    final section = json['lastSection'];
    return PieceActivity(
      openedAt: DateTime.fromMillisecondsSinceEpoch(at),
      lastSection: section is String && section.isNotEmpty ? section : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'openedAt': openedAt.millisecondsSinceEpoch,
        if (lastSection != null) 'lastSection': lastSection,
      };

  @override
  bool operator ==(Object other) =>
      other is PieceActivity &&
      other.openedAt == openedAt &&
      other.lastSection == lastSection;

  @override
  int get hashCode => Object.hash(openedAt, lastSection);
}

/// Stored as one JSON map under [pieceActivityKey]: piece id → activity.
///
/// Device-local on purpose. The dev library syncs an allowlist of pref keys
/// (`dev_library_io.dart`) and this is not on it: timestamps from two devices
/// would three-way-conflict on every sync, and "what I played recently" is a
/// fact about this device anyway.
const pieceActivityKey = 'pieceActivity';

/// Pieces kept in the map. Older entries are dropped on write, so the blob
/// stays small however long the app is used.
const pieceActivityLimit = 50;

class PieceActivityNotifier extends StateNotifier<Map<String, PieceActivity>> {
  PieceActivityNotifier(this._prefs) : super(_read(_prefs));

  final SharedPreferences? _prefs;

  static Map<String, PieceActivity> _read(SharedPreferences? prefs) {
    final raw = prefs?.getString(pieceActivityKey);
    if (raw == null) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return {
        for (final e in decoded.entries)
          if (e.key is String)
            e.key as String: ?PieceActivity.tryFromJson(e.value),
      };
    } catch (_) {
      return const {};
    }
  }

  void _publish(Map<String, PieceActivity> next) {
    if (next.length > pieceActivityLimit) {
      final newest = next.entries.toList()
        ..sort((a, b) => b.value.openedAt.compareTo(a.value.openedAt));
      next = Map.fromEntries(newest.take(pieceActivityLimit));
    }
    state = next;
    _prefs?.setString(pieceActivityKey,
        jsonEncode({for (final e in next.entries) e.key: e.value.toJson()}));
  }

  /// The piece was opened [now]. Keeps the last section, so Recents can still
  /// say where the player left off until they leave it somewhere else.
  void opened(String pieceId, DateTime now) {
    final prev = state[pieceId];
    _publish({
      ...state,
      pieceId: PieceActivity(openedAt: now, lastSection: prev?.lastSection),
    });
  }

  /// Where the player was when they left the piece. Null leaves the previous
  /// one in place: backing out without a selection says nothing new.
  void left(String pieceId, String? section) {
    final prev = state[pieceId];
    if (prev == null || section == null || section == prev.lastSection) return;
    _publish({
      ...state,
      pieceId: PieceActivity(openedAt: prev.openedAt, lastSection: section),
    });
  }

  void forget(String pieceId) {
    if (!state.containsKey(pieceId)) return;
    _publish({...state}..remove(pieceId));
  }
}

final pieceActivityProvider =
    StateNotifierProvider<PieceActivityNotifier, Map<String, PieceActivity>>(
  (ref) => PieceActivityNotifier(ref.watch(sharedPreferencesProvider)),
);

/// What Recents says the player was working on: the section's own label when
/// the selection is exactly one section (from its start to the bar before the
/// next section starts, or to the end), else "Bars a–b".
///
/// [sectionStarts] are the sections' (label, startMeasure) in score order.
String selectionLabel(
  List<(String, int)> sectionStarts,
  int startMeasure,
  int endMeasure,
) {
  for (var i = 0; i < sectionStarts.length; i++) {
    final (label, start) = sectionStarts[i];
    if (start != startMeasure) continue;
    final nextStart =
        i + 1 < sectionStarts.length ? sectionStarts[i + 1].$2 : null;
    if (nextStart == null || nextStart == endMeasure + 1) return label;
  }
  return startMeasure == endMeasure
      ? 'Bar $startMeasure'
      : 'Bars $startMeasure–$endMeasure';
}
