import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/instrument_profile.dart' show Transcription;
import '../services/instrument_setting.dart';
import '../services/piece_display_prefs.dart' show sharedPreferencesProvider;
import '../screens/settings_screen.dart';
import '../services/players.dart';

/// A player's initials in a circle of their colour.
class PlayerAvatar extends StatelessWidget {
  const PlayerAvatar(this.player, {super.key, this.size = 32});

  final Player player;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = playerColours[player.colour % playerColours.length];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: Color(c.fill), shape: BoxShape.circle),
      child: Text(
        player.initials,
        style: TextStyle(
          color: Color(c.ink),
          fontSize: size * 0.42,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Who is playing, in the title bar: shown only when there is more than one
/// player (docs/family/layers.md). A tap opens the switcher.
class PlayerBadge extends ConsumerWidget {
  const PlayerBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(multiplePlayersProvider)) return const SizedBox.shrink();
    final player = ref.watch(currentPlayerProvider)!;
    return IconButton(
      key: const ValueKey('player_badge'),
      tooltip: 'Playing: ${player.name}. Switch player',
      onPressed: () => showPlayerSwitcher(context,
          onManage: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => const SettingsScreen()))),
      icon: PlayerAvatar(player, size: 30),
    );
  }
}

/// "Who's playing?": one tap switches. Settings is where players are added
/// or changed.
Future<void> showPlayerSwitcher(BuildContext context,
    {VoidCallback? onManage}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => Consumer(builder: (ctx, ref, _) {
      final players = ref.watch(playersProvider);
      final current = ref.watch(currentPlayerProvider);
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text("Who's playing?",
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
            for (final p in players)
              ListTile(
                key: ValueKey('player_switch_${p.id}'),
                leading: PlayerAvatar(p, size: 40),
                title: Text(p.name),
                subtitle: Text(_instrumentName(ref, p, players)),
                trailing: p.id == current?.id ? const Text('Playing') : null,
                selected: p.id == current?.id,
                onTap: () {
                  ref.read(currentPlayerIdProvider.notifier).state =
                      p.id == players.first.id ? null : p.id;
                  Navigator.of(ctx).pop();
                },
              ),
            if (onManage != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    onManage();
                  },
                  child: const Text('Add or change players in Settings'),
                ),
              ),
          ],
        ),
      );
    }),
  );
}

/// [player]'s instrument, read under their own key.
String _instrumentName(WidgetRef ref, Player player, List<Player> players) {
  final prefs = ref.read(sharedPreferencesProvider);
  final stored =
      prefs?.getString(playerKey(instrumentSetKeyBase, player, players));
  return switch (stored) {
    'viola' => 'Viola',
    'mandolin' || 'violinAndMandolin' => 'Mandolin',
    _ => 'Violin',
  };
}

/// Public for Settings' list.
String instrumentNameOf(WidgetRef ref, Player player, List<Player> players) =>
    _instrumentName(ref, player, players);

/// "Add a player": a name, a colour (those taken shown faded) and an
/// instrument. The new player is the one playing afterwards.
Future<void> showAddPlayerSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => const _AddPlayerSheet(),
  );
}

class _AddPlayerSheet extends ConsumerStatefulWidget {
  const _AddPlayerSheet();

  @override
  ConsumerState<_AddPlayerSheet> createState() => _AddPlayerSheetState();
}

class _AddPlayerSheetState extends ConsumerState<_AddPlayerSheet> {
  final _name = TextEditingController();
  late int _colour;
  var _instrument = InstrumentSet.violin;

  @override
  void initState() {
    super.initState();
    final taken = _taken();
    _colour = List.generate(playerColours.length, (i) => i)
            .where((i) => !taken.contains(i))
            .firstOrNull ??
        0;
  }

  Set<int> _taken() {
    final players = ref.read(playersProvider);
    // The unnamed first player becomes "Player 1" in colour 0.
    return players.isEmpty ? {0} : {for (final p in players) p.colour};
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _add() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final notifier = ref.read(playersProvider.notifier);
    final added = notifier.add(name, colour: _colour);
    final players = ref.read(playersProvider);
    final prefs = ref.read(sharedPreferencesProvider);
    prefs?.setString(
        playerKey(instrumentSetKeyBase, added, players), _instrument.name);
    if (_instrument == InstrumentSet.viola) {
      prefs?.setString(playerKey(violaTranscriptionKeyBase, added, players),
          Transcription.none.name);
    }
    ref.read(currentPlayerIdProvider.notifier).state = added.id;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final taken = _taken();
    final preview = Player(
        id: '_',
        name: _name.text.isEmpty ? '?' : _name.text,
        colour: _colour);
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Add a player', style: theme.textTheme.titleMedium),
          const SizedBox(height: 14),
          Row(children: [
            PlayerAvatar(preview, size: 56),
            const SizedBox(width: 14),
            Expanded(
              child: TextField(
                key: const ValueKey('add_player_name'),
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Name'),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _add(),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          Text('Colour', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(spacing: 12, children: [
            for (var i = 0; i < playerColours.length; i++)
              Semantics(
                button: true,
                selected: i == _colour,
                label: 'Colour ${i + 1}${taken.contains(i) ? ', taken' : ''}',
                child: GestureDetector(
                  onTap: () => setState(() => _colour = i),
                  child: Opacity(
                    opacity: taken.contains(i) && i != _colour ? 0.35 : 1,
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Color(playerColours[i].fill),
                        shape: BoxShape.circle,
                        border: i == _colour
                            ? Border.all(
                                color: theme.colorScheme.onSurface, width: 2)
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
          ]),
          const SizedBox(height: 16),
          Text('Instrument', style: theme.textTheme.labelLarge),
          RadioGroup<InstrumentSet>(
            groupValue: _instrument,
            onChanged: (v) {
              if (v != null) setState(() => _instrument = v);
            },
            child: const Column(children: [
              RadioListTile<InstrumentSet>(
                  value: InstrumentSet.violin, dense: true, title: Text('Violin')),
              RadioListTile<InstrumentSet>(
                  value: InstrumentSet.viola,
                  dense: true,
                  title: Text('Viola: alto clef, C G D A')),
              RadioListTile<InstrumentSet>(
                  value: InstrumentSet.mandolin,
                  dense: true,
                  title: Text('Mandolin: frets, tab, chords')),
            ]),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                key: const ValueKey('add_player_confirm'),
                onPressed: _name.text.trim().isEmpty ? null : _add,
                child: Text(_name.text.trim().isEmpty
                    ? 'Add'
                    : 'Add ${_name.text.trim()}'),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

/// "Copy to all players" for [pieceId]: how the piece looks (a one-time copy)
/// and, if the playing player has takes limited to them, sharing those.
Future<void> showCopyToAllSheet(BuildContext context, String pieceId,
    {required Future<void> Function(bool looks, bool takes) onCopy,
    required int ownTakes}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      var looks = true;
      var takes = false;
      return StatefulBuilder(builder: (ctx, setSheet) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Copy to all players',
                    style: Theme.of(ctx).textTheme.titleMedium),
                CheckboxListTile(
                  key: const ValueKey('copy_looks'),
                  contentPadding: EdgeInsets.zero,
                  value: looks,
                  onChanged: (v) => setSheet(() => looks = v ?? false),
                  title: const Text('How the piece looks'),
                  subtitle: const Text('Zoom, string colours, fingering '
                      'detail, note names. A one-time copy: afterwards each '
                      'player changes their own.'),
                ),
                if (ownTakes > 0)
                  CheckboxListTile(
                    key: const ValueKey('copy_takes'),
                    contentPadding: EdgeInsets.zero,
                    value: takes,
                    onChanged: (v) => setSheet(() => takes = v ?? false),
                    title: Text(ownTakes == 1
                        ? 'Your own recording'
                        : 'Your $ownTakes own recordings'),
                    subtitle: const Text('Limited to you now. Copying shares '
                        'it with everyone.'),
                  ),
                const SizedBox(height: 8),
                FilledButton(
                  key: const ValueKey('copy_to_all_confirm'),
                  onPressed: looks || takes
                      ? () async {
                          Navigator.of(ctx).pop();
                          await onCopy(looks, takes);
                        }
                      : null,
                  child: const Text('Copy'),
                ),
              ],
            ),
          ),
        );
      });
    },
  );
}
