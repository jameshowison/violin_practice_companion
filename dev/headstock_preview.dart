// The mandolin headstock's "just the button" view, which the app doesn't use
// yet: every course and string, either hand, either way to roll.
//
//   bash scripts/dev_run.sh dev-iphone-se --target=dev/headstock_preview.dart
import 'package:flutter/material.dart';
import 'package:violin_practice_companion/ui/stringlings/mandolin_headstock.dart';

void main() => runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: _Preview()));

class _Preview extends StatefulWidget {
  const _Preview();

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  bool _left = false;
  bool? _tighten = true;
  bool _buttonOnly = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Headstock: just the button')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                alignment: WrapAlignment.center,
                children: [
                  SegmentedButton<bool>(
                    key: const ValueKey('hand'),
                    segments: const [
                      ButtonSegment(value: false, label: Text('Right')),
                      ButtonSegment(value: true, label: Text('Left')),
                    ],
                    selected: {_left},
                    onSelectionChanged: (s) => setState(() => _left = s.first),
                  ),
                  SegmentedButton<int>(
                    key: const ValueKey('way'),
                    segments: const [
                      ButtonSegment(value: 0, label: Text('Tighten')),
                      ButtonSegment(value: 1, label: Text('Loosen')),
                      ButtonSegment(value: 2, label: Text('Still')),
                    ],
                    selected: {_tighten == null ? 2 : (_tighten! ? 0 : 1)},
                    onSelectionChanged: (s) =>
                        setState(() => _tighten = s.first == 2 ? null : s.first == 0),
                  ),
                  SegmentedButton<bool>(
                    key: const ValueKey('view'),
                    segments: const [
                      ButtonSegment(value: true, label: Text('Button')),
                      ButtonSegment(value: false, label: Text('Headstock')),
                    ],
                    selected: {_buttonOnly},
                    onSelectionChanged: (s) => setState(() => _buttonOnly = s.first),
                  ),
                ],
              ),
            ),
            Expanded(
              child: GridView.count(
                crossAxisCount: 2,
                childAspectRatio: 1.35,
                padding: const EdgeInsets.all(8),
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                children: [
                  for (final course in ['G', 'D', 'A', 'E'])
                    for (final which in MandolinString.values)
                      Card(
                        margin: EdgeInsets.zero,
                        child: Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text('$course · ${which == MandolinString.outer ? 'outside' : 'inside'}',
                                  style: const TextStyle(fontWeight: FontWeight.w800)),
                            ),
                            Expanded(
                              child: MandolinHeadstock(
                                course: course,
                                which: which,
                                tighten: _tighten,
                                leftHanded: _left,
                                buttonOnly: _buttonOnly,
                              ),
                            ),
                          ],
                        ),
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
