import 'package:flutter/material.dart';
import 'package:jovial_svg/jovial_svg.dart';

import '../services/screen_share_layout.dart';

/// The "Fit to screen" page: the piece as plain printed music, sized so the
/// whole of it — or, for a long piece, one screen-sized page of it at a time
/// — can be scanned off this screen by another device. See
/// `screen_share_layout.dart` for the sizing rules.
///
/// Black on white whatever the theme: it is meant to be photographed.
class FitToScreenView extends StatefulWidget {
  const FitToScreenView({
    super.key,
    required this.musicXml,
    required this.title,
    this.bottomClearance = 0,
  });

  final String musicXml;
  final String title;

  /// Room left free at the bottom for the playback tray.
  final double bottomClearance;

  @override
  State<FitToScreenView> createState() => _FitToScreenViewState();
}

/// Side margin around the engraving, in logical pixels. Verovio adds its own
/// page margin inside it.
const double _sideMargin = 8;
const double _titleHeight = 36;
const double _pagerHeight = 36;

class _FitToScreenViewState extends State<FitToScreenView> {
  Future<({ScreenShareLayout layout, ScalableImage image})>? _future;
  (String, double, double)? _key;
  var _pageController = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<({ScreenShareLayout layout, ScalableImage image})> _layout(
      double width, double height) {
    final key = (widget.musicXml, width, height);
    if (key != _key || _future == null) {
      _key = key;
      // The old controller may still be attached to the outgoing PageView,
      // so it is disposed after this frame rather than now.
      final old = _pageController;
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      _pageController = PageController();
      _page = 0;
      _future = layoutForScreen(widget.musicXml, width: width, height: height)
          .then((layout) => (
                layout: layout,
                image: ScalableImage.fromSvgString(
                  layout.score.svg,
                  currentColor: Colors.black,
                  warnF: (_) {},
                ),
              ));
    }
    return _future!;
  }

  @override
  Widget build(BuildContext context) {
    const ink = TextStyle(color: Colors.black);
    return ColoredBox(
      color: Colors.white,
      child: Padding(
        padding: EdgeInsets.only(bottom: widget.bottomClearance),
        child: LayoutBuilder(builder: (context, constraints) {
          final width = constraints.maxWidth - 2 * _sideMargin;
          final height = constraints.maxHeight - _titleHeight - _pagerHeight;
          if (width <= 0 || height <= 0) return const SizedBox.shrink();
          return FutureBuilder(
            future: _layout(width, height),
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(child: Text('Error: ${snap.error}', style: ink));
              }
              final data = snap.data;
              if (data == null) {
                return const Center(child: CircularProgressIndicator());
              }
              final layout = data.layout;
              return Column(
                children: [
                  SizedBox(
                    key: const ValueKey('fit_to_screen_title'),
                    height: _titleHeight,
                    child: Center(
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ink.copyWith(
                            fontSize: 20, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ),
                  Expanded(
                    child: PageView.builder(
                      // A new layout (a rotation, an edit) starts at page 1.
                      key: ValueKey(_key),
                      controller: _pageController,
                      itemCount: layout.pageCount,
                      onPageChanged: (p) => setState(() => _page = p),
                      itemBuilder: (context, i) => Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: _sideMargin),
                          child: CustomPaint(
                            size: Size(width, layout.pageHeight(i)),
                            painter: _PagePainter(layout, data.image, i),
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    height: _pagerHeight,
                    child: layout.pageCount < 2
                        ? null
                        : _Pager(
                            page: _page,
                            count: layout.pageCount,
                            onPage: (p) => _pageController.animateToPage(p,
                                duration: const Duration(milliseconds: 250),
                                curve: Curves.easeOut),
                          ),
                  ),
                ],
              );
            },
          );
        }),
      ),
    );
  }
}

class _Pager extends StatelessWidget {
  const _Pager({required this.page, required this.count, required this.onPage});

  final int page;
  final int count;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          key: const ValueKey('fit_to_screen_prev'),
          color: Colors.black54,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.chevron_left),
          onPressed: page > 0 ? () => onPage(page - 1) : null,
        ),
        Text('Page ${page + 1} of $count',
            key: const ValueKey('fit_to_screen_page_label'),
            style: const TextStyle(color: Colors.black54, fontSize: 13)),
        IconButton(
          key: const ValueKey('fit_to_screen_next'),
          color: Colors.black54,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.chevron_right),
          onPressed: page < count - 1 ? () => onPage(page + 1) : null,
        ),
      ],
    );
  }
}

/// One page: the slice of the tall engraving holding its systems.
class _PagePainter extends CustomPainter {
  _PagePainter(this.layout, this.image, this.page);

  final ScreenShareLayout layout;
  final ScalableImage image;
  final int page;

  @override
  void paint(Canvas canvas, Size size) {
    final top = layout.lines[layout.pages[page].first].top;
    canvas.clipRect(Offset.zero & size);
    canvas.translate(0, -top);
    canvas.scale(layout.scale);
    image.paint(canvas);
  }

  @override
  bool shouldRepaint(_PagePainter old) =>
      old.layout != layout || old.page != page || old.image != image;
}
