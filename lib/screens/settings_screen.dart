import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/instrument_setting.dart';
import '../theme/app_skin.dart';
import '../theme/skins.dart';
import 'thanks_screen.dart';

/// The privacy policy, docs/privacy.md, on GitHub. The App Store listing links
/// the stringlings.app copy instead, built from the same file (build_site.py).
const privacyPolicyUrl =
    'https://github.com/jameshowison/violin_practice_companion/blob/main/docs/privacy.md';
const issueTrackerUrl =
    'https://github.com/jameshowison/violin_practice_companion/issues';

/// App-wide settings, from the gear on the piece list. Per-piece choices (view,
/// spacing, fingering detail) stay in the piece's own drawer; this is for facts
/// about who uses the app.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final set = ref.watch(instrumentSetProvider);
    final skin = ref.watch(appSkinProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _PrivacyNote(key: ValueKey('privacy_note')),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text('Appearance', style: theme.textTheme.titleSmall),
          ),
          Padding(
            key: const ValueKey('skin_setting'),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                for (final (s, label) in const [
                  (AppSkin.classic, 'Classic'),
                  (AppSkin.playful, 'Playful'),
                ]) ...[
                  if (s != AppSkin.classic) const SizedBox(width: 12),
                  Expanded(
                    child: _SkinTile(
                      key: ValueKey('skin_setting_${s.name}'),
                      skin: s,
                      label: label,
                      selected: skin == s,
                      onTap: () =>
                          ref.read(appSkinProvider.notifier).state = s,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Changes the look; the screens and controls stay the same.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text('Instruments', style: theme.textTheme.titleSmall),
          ),
          RadioGroup<InstrumentSet>(
            groupValue: set,
            onChanged: (v) {
              if (v != null) ref.read(instrumentSetProvider.notifier).state = v;
            },
            child: const Column(
              key: ValueKey('instrument_setting'),
              children: [
                RadioListTile<InstrumentSet>(
                  key: ValueKey('instrument_setting_violin'),
                  value: InstrumentSet.violin,
                  dense: true,
                  title: Text('Violin'),
                ),
                RadioListTile<InstrumentSet>(
                  key: ValueKey('instrument_setting_violin_mandolin'),
                  value: InstrumentSet.violinAndMandolin,
                  dense: true,
                  title: Text('Violin and mandolin: frets, tab, chords'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),
          ListTile(
            key: const ValueKey('thanks_entry'),
            leading: const Icon(Icons.favorite_outline),
            title: const Text('Thanks and how to contribute'),
            subtitle: const Text(
                'Free and open source on GitHub: credits and licences'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ThanksScreen()),
            ),
          ),
        ],
      ),
    );
  }

}

/// What the app collects (nothing), with links to the full policy and to
/// support.
class _PrivacyNote extends StatefulWidget {
  const _PrivacyNote({super.key});

  @override
  State<_PrivacyNote> createState() => _PrivacyNoteState();
}

class _PrivacyNoteState extends State<_PrivacyNote> {
  final _taps = <TapGestureRecognizer>[];

  TapGestureRecognizer _tapFor(String url) {
    final r = TapGestureRecognizer()..onTap = () => _open(url);
    _taps.add(r);
    return r;
  }

  Future<void> _open(String url) async {
    final ok = await launchUrl(Uri.parse(url),
        mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not open $url')));
    }
  }

  @override
  void dispose() {
    for (final r in _taps) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _taps) {
      r.dispose();
    }
    _taps.clear();
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium;
    final linkColor = theme.colorScheme.primary;
    InlineSpan link(String text, String url) => TextSpan(
          text: text,
          recognizer: _tapFor(url),
          style: TextStyle(color: linkColor),
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: GestureDetector(
                onTap: () => _open(url),
                child: Padding(
                  padding: const EdgeInsets.only(left: 2),
                  child: Icon(Icons.open_in_new,
                      size: (base?.fontSize ?? 14) * 0.95, color: linkColor),
                ),
              ),
            ),
          ],
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Text.rich(
        TextSpan(children: [
          const TextSpan(
              text: 'Stringlings collects no data, has no accounts or '
                  'sign-ups, and its features work entirely on your device. '
                  'See the '),
          link('privacy policy', privacyPolicyUrl),
          const TextSpan(text: '.\n\nQuestions go to '),
          link('support@stringlings.app', 'mailto:support@stringlings.app'),
          const TextSpan(text: ' or the '),
          link("project's issue tracker", issueTrackerUrl),
          const TextSpan(
              text: '. Stringlings is a one-person, spare-time project, so '
                  "please be patient with replies — there's violin and "
                  'mandolin practice to fit in too ;)'),
        ]),
        style: base,
      ),
    );
  }
}

/// A small preview of a skin, drawn in that skin's own colours and type.
class _SkinTile extends StatelessWidget {
  const _SkinTile({
    super.key,
    required this.skin,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final AppSkin skin;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final own = themeFor(skin);
    final scheme = own.colorScheme;
    final current = Theme.of(context).colorScheme;
    final radius = skin == AppSkin.playful ? 10.0 : 4.0;
    final second = skin == AppSkin.playful ? const Color(0xFF8BD3C7) : scheme.primary;
    final first = skin == AppSkin.playful ? const Color(0xFFFFD166) : scheme.surface;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? current.primary : current.outlineVariant,
              width: 2.5,
            ),
          ),
          child: Column(
            children: [
              Container(
                height: 72,
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(10),
                  // Cream-on-cream otherwise, in the Playful skin itself.
                  border: Border.all(color: current.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FractionallySizedBox(
                      widthFactor: 0.6,
                      child: Container(
                        height: 8,
                        decoration: BoxDecoration(
                          color: scheme.onSurface,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Expanded(
                      child: Row(children: [
                        Expanded(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: first,
                              borderRadius: BorderRadius.circular(radius),
                            ),
                          ),
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: second,
                              borderRadius: BorderRadius.circular(radius),
                            ),
                          ),
                        ),
                      ]),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(label,
                  style: own.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700, color: current.onSurface)),
            ],
          ),
        ),
      ),
    );
  }
}
