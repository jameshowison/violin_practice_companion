import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'piece_display_prefs.dart' show sharedPreferencesProvider;

/// One of the people who play from this app (docs/family/layers.md, the
/// player layer): their name, initials and colour for the title-bar badge.
/// Their instrument, view settings, practice settings and recents are
/// preferences kept under their own keys ([playerKeyProvider]).
class Player {
  final String id;
  final String name;

  /// An index into [playerColours].
  final int colour;

  const Player({required this.id, required this.name, required this.colour});

  /// Up to two letters: the first letters of the first two words, else the
  /// name's first letter.
  String get initials {
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    if (words.isEmpty) return '?';
    return words
        .take(2)
        .map((w) => String.fromCharCode(w.runes.first).toUpperCase())
        .join();
  }

  Player copyWith({String? name, int? colour}) =>
      Player(id: id, name: name ?? this.name, colour: colour ?? this.colour);

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'colour': colour};

  static Player fromJson(Map<String, dynamic> j) => Player(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        colour: (j['colour'] as num?)?.toInt() ?? 0,
      );
}

/// The badge colours: a fill and the ink that reads on it (both pass 4.5:1).
const playerColours = <({int fill, int ink})>[
  (fill: 0xFFFFD166, ink: 0xFF3A2A00), // gold
  (fill: 0xFF8BD3C7, ink: 0xFF0B3B35), // teal
  (fill: 0xFFF7B2C1, ink: 0xFF4A1424), // pink
  (fill: 0xFFB5CBFF, ink: 0xFF14285A), // blue
  (fill: 0xFFC8E89F, ink: 0xFF213A08), // green
  (fill: 0xFFFFC49B, ink: 0xFF4A2205), // orange
];

const playersKey = 'players';
const currentPlayerKey = 'players.current';

/// The players, in the order they were added. Empty means one player who has
/// never been named: the app as it always was, every setting already on the
/// device theirs. Adding a second player names the first too.
class PlayersNotifier extends StateNotifier<List<Player>> {
  PlayersNotifier(this._prefs) : super(_read(_prefs));

  final SharedPreferences? _prefs;

  static List<Player> _read(SharedPreferences? prefs) {
    final raw = prefs?.getString(playersKey);
    if (raw == null) return const [];
    try {
      return [
        for (final p in jsonDecode(raw) as List)
          Player.fromJson((p as Map).cast<String, dynamic>()),
      ];
    } catch (_) {
      return const [];
    }
  }

  void _save(List<Player> players) {
    state = players;
    _prefs?.setString(
        playersKey, jsonEncode([for (final p in players) p.toJson()]));
  }

  /// Adds [name], naming the first player [firstName] if there was only the
  /// unnamed one. Returns the new player.
  Player add(String name, {required int colour, String firstName = 'Player 1'}) {
    final players = [...state];
    if (players.isEmpty) {
      players.add(Player(id: 'p1', name: firstName, colour: 0));
    }
    var n = players.length + 1;
    while (players.any((p) => p.id == 'p$n')) {
      n++;
    }
    final added = Player(id: 'p$n', name: name, colour: colour);
    _save([...players, added]);
    return added;
  }

  void rename(String id, String name) =>
      _save([for (final p in state) p.id == id ? p.copyWith(name: name) : p]);
}

final playersProvider = StateNotifierProvider<PlayersNotifier, List<Player>>(
  (ref) => PlayersNotifier(ref.watch(sharedPreferencesProvider)),
);

/// Who is playing: a [Player.id], or null for the first (or only) player.
final currentPlayerIdProvider = StateProvider<String?>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  ref.listenSelf((_, next) {
    if (prefs == null) return;
    if (next == null) {
      prefs.remove(currentPlayerKey);
    } else {
      prefs.setString(currentPlayerKey, next);
    }
  });
  final stored = prefs?.getString(currentPlayerKey);
  return stored;
});

/// The player playing now, or null when there is only the one, unnamed.
final currentPlayerProvider = Provider<Player?>((ref) {
  final players = ref.watch(playersProvider);
  if (players.isEmpty) return null;
  final id = ref.watch(currentPlayerIdProvider);
  return players.where((p) => p.id == id).firstOrNull ?? players.first;
});

/// Whether there is more than one player: the badge, the switcher and the
/// after-recording question appear only then.
final multiplePlayersProvider =
    Provider<bool>((ref) => ref.watch(playersProvider).length > 1);

/// The preference key for [base] under [player], among [players]. The first
/// player keeps every key as it was, so a device that gains a second player
/// needs no migration: everything already stored is the first player's.
String playerKey(String base, Player? player, List<Player> players) {
  if (player == null || players.isEmpty || player.id == players.first.id) {
    return base;
  }
  return 'player.${player.id}.$base';
}

/// [playerKey] for the player playing now. Every per-player preference reads
/// and writes through this, and rebuilds when the player changes.
final playerKeyProvider = Provider<String Function(String)>((ref) {
  final players = ref.watch(playersProvider);
  final player = ref.watch(currentPlayerProvider);
  return (base) => playerKey(base, player, players);
});
