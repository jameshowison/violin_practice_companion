import 'package:flutter/material.dart';

/// A titled, faintly section-colored band wrapping one section run's rows in the
/// jianpu/fingering views: a header (`A ————`) on a tint of the section color,
/// followed by the run's rows. The header carries [headerKey] so the view can
/// `Scrollable.ensureVisible` it for minimap navigation and scroll tracking.
class SectionRunBlock extends StatelessWidget {
  final String title;
  final Color? color;
  final Key headerKey;
  final List<Widget> children;

  const SectionRunBlock({
    super.key,
    required this.title,
    required this.color,
    required this.headerKey,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final ruleColor = (color ?? onSurface).withAlpha(110);
    return Container(
      color: color?.withAlpha(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            key: headerKey,
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
            child: Row(
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: onSurface.withAlpha(200),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: Container(height: 1, color: ruleColor)),
              ],
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}
