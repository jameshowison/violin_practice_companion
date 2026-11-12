import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/bundled_licenses.dart';

const _homrUrl = 'https://github.com/liebharc/homr';

/// What the app is built on, and where to change it. Opened from the top of
/// Settings; ends in Flutter's licence page, which lists every package and
/// what [registerBundledLicenses] adds.
class ThanksScreen extends StatelessWidget {
  const ThanksScreen({super.key});

  Future<void> _open(BuildContext context, String url) async {
    final ok = await launchUrl(Uri.parse(url),
        mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not open $url')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    Widget heading(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(text, style: theme.textTheme.titleMedium),
        );
    Widget para(String text, {TextStyle? style}) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(text, style: style ?? theme.textTheme.bodyMedium),
        );
    Widget linkButton(Key key, IconData icon, String label, String url) =>
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: key,
              icon: Icon(icon),
              label: Text(label),
              onPressed: () => _open(context, url),
            ),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Thanks and how to contribute')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          heading('Free and open source'),
          para('Stringlings is free software, made in the open. All of its '
              'code is on GitHub, and you are welcome to tweak it, fix it, '
              'improve it, or make your own version of it: for your studio, '
              'your instrument or your language.'),
          linkButton(const ValueKey('thanks_github'), Icons.code,
              'Stringlings on GitHub', kSourceRepoUrl),
          para('Ideas and bug reports are welcome there too. Open an issue, '
              'or send a pull request with your change.'),
          para(
              'The licence is the GNU General Public License, version 3 or '
              'later. In short: use it, change it and share it freely. If you '
              'share a version you have changed, share its source code too, '
              'under the same licence, so the next person can keep improving '
              'it.',
              style: muted),
          heading('Wait, why did I pay for the app?'),
          para('Distributing through the app stores costs money, and '
              'hopefully the convenience is worth the cost. Building from '
              'source on GitHub is always without cost.'),
          heading('A special thank-you to homr'),
          para('Scanning sheet music works because of homr, an open-source '
              'optical music recognition project. homr\'s trained models do '
              'the hard part, finding the staves and reading the notes; '
              'Stringlings runs a port of homr\'s pipeline, homr_flutter, '
              'right on your device, with no internet needed. Thank you to '
              'everyone who built and trained it.'),
          linkButton(const ValueKey('thanks_homr'), Icons.document_scanner,
              'homr on GitHub', _homrUrl),
          para('homr and homr_flutter are licensed under the GNU Affero '
              'General Public License, version 3 or later.',
              style: muted),
          heading('Also thanks to'),
          for (final (name, what) in const [
            ('Verovio', 'engraves the score (LGPL-3.0)'),
            (
              'OpenSheetMusicDisplay and VexFlow',
              'a second score renderer (BSD-3-Clause, MIT)'
            ),
            ('abcjs', 'reads tunes written in ABC notation (MIT)'),
            (
              'GeneralUser GS',
              'the instrument sounds, by S. Christian Collins (free licence)'
            ),
            ('Nunito', 'the Playful typeface (SIL Open Font License)'),
            ('Flutter', 'and the many open-source Dart packages listed below'),
            ('Claude Code', 'by Anthropic, which helped write the code'),
          ])
            ListTile(
              dense: true,
              title: Text(name),
              subtitle: Text(what),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                key: const ValueKey('thanks_licenses'),
                icon: const Icon(Icons.description_outlined),
                label: const Text('All licences'),
                onPressed: () => showLicensePage(
                  context: context,
                  applicationName: 'Stringlings',
                  applicationLegalese:
                      'Free software under the GNU GPL, version 3 or later.\n'
                      '$kSourceRepoUrl',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
