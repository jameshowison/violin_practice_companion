import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jovial_svg/jovial_svg.dart';

import '../services/providers.dart';
import 'package:score_view/score_view.dart';

/// The piece's opening clef/key/time, engraved alone and shown next to the
/// title — the counterpart to `_hidePreambleFor` (`services/providers.dart`),
/// which strips this same preamble out of the main staff render so its width
/// goes to notes instead.
///
/// Engraved with `breaks: 'none'` and `pageMarginTop: 0`: Verovio then crops
/// the exported viewBox to the glyphs' own natural extent regardless of the
/// requested page width — confirmed headlessly against the bundled wasm
/// toolkit (widthPx 50 through 300 and scale 40/100 all produced the same
/// 2.33 aspect ratio) — so this never needs to match the main staff's scale.
class PreamblePreview extends ConsumerStatefulWidget {
  const PreamblePreview({super.key, this.height = 28});

  final double height;

  @override
  ConsumerState<PreamblePreview> createState() => _PreamblePreviewState();
}

class _PreamblePreviewState extends ConsumerState<PreamblePreview> {
  String? _engravedFor;
  ScalableImage? _image;
  Size? _viewBox;

  Future<void> _engrave(String xml) async {
    final score = await VerovioEngraver.instance.engrave(
      xml,
      widthPx: 200,
      scale: 100,
      pageMarginTop: 0,
      breaks: 'none',
      tight: true,
    );
    if (!mounted || _engravedFor != xml) return;
    setState(() {
      _image = ScalableImage.fromSvgString(score.svg,
          currentColor: Colors.black, warnF: (_) {});
      _viewBox = score.viewBox;
    });
  }

  @override
  Widget build(BuildContext context) {
    final xml = ref.watch(preambleMusicXmlProvider).valueOrNull;
    if (xml == null) return SizedBox(height: widget.height);
    if (xml != _engravedFor) {
      _engravedFor = xml;
      _engrave(xml);
    }
    final image = _image;
    final viewBox = _viewBox;
    if (image == null || viewBox == null || viewBox.height == 0) {
      return SizedBox(height: widget.height);
    }
    // The engraved viewBox is cropped tight to the ink, but the treble
    // clef's tail dips well below the staff while little extends above it,
    // so the staff itself — the part the eye actually reads as "the icon" —
    // sits in the upper third of that box. Centering the box in the title
    // row therefore reads as the icon sitting too high; nudge the paint
    // down (the paint, not the layout box) to bring the staff visually level
    // with the title text next to it.
    final body = Transform.translate(
      offset: Offset(0, widget.height * 0.14),
      child: SizedBox(
        width: widget.height * viewBox.width / viewBox.height,
        height: widget.height,
        child: ScalableImageWidget(si: image, fit: BoxFit.contain),
      ),
    );
    // Decorative: the key summary next to it says the key in text. The
    // meter is drawn here only, and on bar 1 of the score.
    return ExcludeSemantics(child: body);
  }
}
