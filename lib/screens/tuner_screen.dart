import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:string_tuner/string_tuner.dart';

import '../build_info.dart';
import '../models/violin_string_palette.dart';
import '../services/instrument_setting.dart';
import '../services/keep_awake.dart';
import '../services/piece_display_prefs.dart' show sharedPreferencesProvider;
import '../services/tuner_input.dart';
import '../services/tuner_model.dart';
import '../theme/brand.dart';
import '../ui/stringlings/stringling_climber.dart';

/// The reference A, `tuner.a4`: 440 or 442.
const tunerA4Key = 'tuner.a4';

/// `violin` or `mandolin`, `tuner.instrument`. Mandolin is offered only when
/// the app's Instruments setting includes it.
const tunerInstrumentKey = 'tuner.instrument';

/// The tuner: a stringling climbs to the string being played and shows by
/// its height and face how far out of tune it is (see [StringlingClimber]).
///
/// It opens in PLAY mode, with the microphone off: the pitch slider under the
/// note is a toy, and dragging it makes the stringling squirm, so a child
/// learns what flat and sharp look like before tuning anything. "Ready to
/// tune?" at the top of the card starts listening (and is where the
/// microphone permission is asked, in context); the slider then shows the
/// string's pitch instead. For violin, an arrow above the string's rule shows
/// which way to turn the fine tuner.
///
/// Follows whichever string is played, or the one picked in the chips.
/// Violin targets are pure fifths from A, mandolin's equal-tempered
/// (`string_tuner`'s [InstrumentTuning]). The reference A and the instrument
/// are in the settings sheet (the cog).
class TunerScreen extends ConsumerStatefulWidget {
  const TunerScreen({super.key});

  @override
  ConsumerState<TunerScreen> createState() => _TunerScreenState();
}

enum _Mic { off, starting, listening, denied, unavailable }

class _TunerScreenState extends ConsumerState<TunerScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final TunerInputBase _input;
  StreamSubscription<TunerFrame>? _sub;
  late TunerModel _model;
  final _reading = ValueNotifier<TunerReading?>(null);
  final _play = ValueNotifier<double>(0); // the slider's cents in play mode
  _Mic _mic = _Mic.off;
  String? _error;
  int _rung = 2; // the A string until something is heard or picked
  double _a4 = 440;
  bool _mandolin = false;
  bool _resumeListening = false;

  /// Lets the play slider go back to in tune, with a little overshoot, when
  /// it is let go: every squirm ends happy.
  late final AnimationController _spring; // made in initState, like _input
  double _springFrom = 0;

  void _dragTo(double c) {
    _spring.stop();
    if ((c / 10).round() != (_play.value / 10).round()) HapticFeedback.selectionClick();
    _play.value = c;
  }

  void _springBack() {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _play.value = 0;
      return;
    }
    _springFrom = _play.value;
    _spring.forward(from: 0);
  }

  bool get _listening => _mic == _Mic.listening || _mic == _Mic.starting;

  @override
  void initState() {
    super.initState();
    // Made here, not lazily: dispose() can't use ref, and in play mode
    // nothing else may have touched it.
    _input = ref.read(tunerInputFactoryProvider)();
    _spring = AnimationController(vsync: this, duration: const Duration(milliseconds: 650))
      ..addListener(() =>
          _play.value = _springFrom * (1 - Curves.easeOutBack.transform(_spring.value)));
    final prefs = ref.read(sharedPreferencesProvider);
    _a4 = (prefs?.getInt(tunerA4Key) ?? 440) == 442 ? 442 : 440;
    _mandolin = prefs?.getString(tunerInstrumentKey) == 'mandolin' &&
        ref.read(instrumentFeaturesProvider).fretNumbers;
    _model = TunerModel(_tuning());
    WidgetsBinding.instance.addObserver(this);
    KeepAwake.enable();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    KeepAwake.disable();
    _sub?.cancel();
    _input.dispose();
    _spring.dispose();
    _reading.dispose();
    _play.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_resumeListening) _start();
      _resumeListening = false;
    } else if ((state == AppLifecycleState.paused || state == AppLifecycleState.hidden) &&
        _listening) {
      _resumeListening = true;
      _stop();
    }
  }

  InstrumentTuning _tuning() =>
      _mandolin ? InstrumentTuning.mandolin(a4: _a4) : InstrumentTuning.violin(a4: _a4);

  Future<void> _start() async {
    if (!_input.isSupported) {
      setState(() => _mic = _Mic.unavailable);
      return;
    }
    // Not awaited: start() below stops the previous run itself.
    _sub?.cancel();
    _sub = null;
    setState(() => _mic = _Mic.starting);
    final range = _model.tuning.detectionRange;
    try {
      final frames = await _input.start(minHz: range.minHz, maxHz: range.maxHz);
      if (!mounted) return;
      _sub = frames.listen(_onFrame, onError: (Object e) {
        if (mounted) setState(() => _error = '$e');
      });
      setState(() {
        _mic = _Mic.listening;
        _error = null;
      });
    } on TunerMicDenied {
      if (mounted) setState(() => _mic = _Mic.denied);
    } catch (e) {
      if (kDebugMode) debugPrint('[tuner] start failed: $e');
      if (mounted) {
        setState(() {
          _mic = _Mic.unavailable;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _stop() async {
    _sub?.cancel();
    _sub = null;
    if (mounted) {
      setState(() => _mic = _Mic.off);
      _reading.value = null;
    }
    await _input.stop();
  }

  int _frames = 0;
  void _onFrame(TunerFrame f) {
    if (kDebugMode && f.pitch != null && ++_frames % 90 == 0) {
      final p = f.pitch!;
      debugPrint('[tuner] ${p.hz.toStringAsFixed(2)} Hz clarity ${p.clarity.toStringAsFixed(2)} '
          'rms ${p.rms.toStringAsFixed(4)} → ${_model.reading?.string.name} '
          '${_model.reading?.cents.toStringAsFixed(1)}¢');
    }
    if (!_model.add(f)) return;
    final r = _model.reading;
    _reading.value = r;
    if (r != null) {
      final i = _model.tuning.strings.indexWhere((s) => s.midi == r.string.midi);
      if (i >= 0 && i != _rung) setState(() => _rung = i);
    }
  }

  void _retune({double? a4, bool? mandolin}) {
    final prefs = ref.read(sharedPreferencesProvider);
    if (a4 != null) {
      _a4 = a4;
      prefs?.setInt(tunerA4Key, a4.round());
    }
    final rangeBefore = _model.tuning.detectionRange;
    if (mandolin != null) {
      _mandolin = mandolin;
      prefs?.setString(tunerInstrumentKey, mandolin ? 'mandolin' : 'violin');
    }
    setState(() => _model.tuning = _tuning());
    _reading.value = null;
    if (_model.tuning.detectionRange != rangeBefore && _listening) _start();
  }

  void _pin(String? name) {
    setState(() {
      _model.pinned = name;
      if (name != null) _rung = _model.tuning.strings.indexWhere((s) => s.name == name);
    });
    _reading.value = null;
  }

  Future<void> _openSettings() async {
    final features = ref.read(instrumentFeaturesProvider);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          final theme = Theme.of(context);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Tuner settings', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 16),
                  Text('Reference pitch', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 6),
                  SegmentedButton<double>(
                    key: const ValueKey('tuner_a4'),
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 440, label: Text('A = 440')),
                      ButtonSegment(value: 442, label: Text('A = 442')),
                    ],
                    selected: {_a4},
                    onSelectionChanged: (v) {
                      _retune(a4: v.first);
                      setSheet(() {});
                    },
                  ),
                  const SizedBox(height: 4),
                  Text('Most teachers use 440. Some orchestras tune a little higher, to 442.',
                      style: theme.textTheme.bodySmall),
                  if (features.fretNumbers) ...[
                    const SizedBox(height: 18),
                    Text('Instrument', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    SegmentedButton<bool>(
                      key: const ValueKey('tuner_instrument'),
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: false, label: Text('Violin')),
                        ButtonSegment(value: true, label: Text('Mandolin')),
                      ],
                      selected: {_mandolin},
                      onSelectionChanged: (v) {
                        _retune(mandolin: v.first);
                        setSheet(() {});
                      },
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static Color _colorOf(String letter) =>
      // The icon's darker E: the palette's yellow is too light on paper.
      letter == 'E' ? const Color(0xFFC9961C) : ViolinStringPalette.byString[letter] ?? ViolinStringPalette.unknown;

  /// In play mode, the slider's pretend reading on the shown string.
  TunerReading _pretend(double cents) {
    final s = _model.tuning.strings[_rung.clamp(0, _model.tuning.strings.length - 1)];
    return TunerReading(s, cents, s.hz * math.pow(2, cents / 1200), live: true);
  }

  @override
  Widget build(BuildContext context) {
    final tuning = _model.tuning;
    final rungs = [
      for (final s in tuning.strings)
        ClimberRung(
          letter: s.name[0],
          caption: '${s.name} · ${s.hz.toStringAsFixed(2)} Hz${_mandolin ? ' · pair' : ''}',
          color: _colorOf(s.name[0]),
        ),
    ];
    final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.45);
    final shown = Listenable.merge([_reading, _play]);
    TunerReading? current() => _listening ? _reading.value : _pretend(_play.value);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Tuner'),
            if (kDebugMode) Text(kBuildRef, style: TextStyle(fontSize: 9, color: muted)),
          ],
        ),
        centerTitle: true,
        actions: [
          IconButton(
            key: const ValueKey('tuner_settings'),
            icon: const Icon(Icons.settings),
            tooltip: 'Tuner settings',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: kIconPaper,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFE4D6BC)),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: switch (_mic) {
                      _Mic.denied => _Message(
                          key: const ValueKey('tuner_mic_denied'),
                          text: 'The tuner needs the microphone to hear your strings. '
                              'Allow it for Stringlings in Settings, then come back.',
                          action: 'Try again',
                          onAction: _start,
                          secondary: 'Back to playing',
                          onSecondary: () => setState(() => _mic = _Mic.off),
                        ),
                      _Mic.unavailable => _Message(
                          key: const ValueKey('tuner_unavailable'),
                          text: _error == null
                              ? 'The tuner can\'t listen on this device yet, '
                                  'but you can still play with the slider.'
                              : 'The microphone could not start.\n$_error',
                          action: _error == null ? null : 'Try again',
                          onAction: _start,
                          secondary: 'Back to playing',
                          onSecondary: () => setState(() => _mic = _Mic.off),
                        ),
                      _ => Stack(
                          children: [
                            Positioned.fill(
                              child: ListenableBuilder(
                                listenable: shown,
                                builder: (context, _) => StringlingClimber(
                                  key: const ValueKey('tuner_climber'),
                                  rungs: rungs,
                                  target: _rung,
                                  cents: current()?.cents,
                                  doubled: _mandolin,
                                  fineTuners: !_mandolin,
                                ),
                              ),
                            ),
                            Positioned(
                              top: 10,
                              left: 0,
                              right: 0,
                              child: Column(
                                children: [
                                  _ListenPill(
                                    listening: _listening,
                                    onTap: _listening ? _stop : _start,
                                  ),
                                  if (!_listening)
                                    const Padding(
                                      padding: EdgeInsets.only(top: 6),
                                      child: Text('Slide the dot to make it squirm',
                                          key: ValueKey('tuner_play_hint'),
                                          style: TextStyle(
                                              color: Color(0xFF6A6180),
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w700)),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                    },
                  ),
                ),
              ),
              const SizedBox(height: 10),
              ListenableBuilder(
                listenable: shown,
                builder: (context, _) {
                  final r = current();
                  return _Readout(
                    reading: r,
                    listening: _listening,
                    fineTuners: !_mandolin,
                    onDrag: _listening ? null : _dragTo,
                    onLetGo: _springBack,
                  );
                },
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                alignment: WrapAlignment.center,
                children: [
                  ChoiceChip(
                    key: const ValueKey('tuner_string_auto'),
                    label: const Text('Auto'),
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    selected: _model.pinned == null,
                    onSelected: (_) => _pin(null),
                  ),
                  for (final s in tuning.strings)
                    ChoiceChip(
                      key: ValueKey('tuner_string_${s.name[0]}'),
                      avatar: CircleAvatar(backgroundColor: _colorOf(s.name[0]), radius: 6),
                      label: Text(s.name[0]),
                      // No checkmark: it widens the chip, and the E chip
                      // wrapped onto a row of its own on an iPhone SE.
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      selected: _model.pinned == s.name,
                      onSelected: (on) => _pin(on ? s.name : null),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Ready to tune?" / "Listening · tap to stop".
class _ListenPill extends StatelessWidget {
  const _ListenPill({required this.listening, required this.onTap});
  final bool listening;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF2B2340);
    return Material(
      color: listening ? Colors.white : ink,
      shape: StadiumBorder(
          side: listening ? const BorderSide(color: ink, width: 1.5) : BorderSide.none),
      elevation: listening ? 0 : 2,
      child: InkWell(
        key: ValueKey(listening ? 'tuner_stop' : 'tuner_ready'),
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(listening ? Icons.mic : Icons.mic_none,
                  size: 18, color: listening ? const Color(0xFFC62828) : Colors.white),
              const SizedBox(width: 6),
              Flexible(
                child: Text(listening ? 'Listening · tap to stop' : 'Ready to tune?',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: listening ? ink : Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 15)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Readout extends StatelessWidget {
  const _Readout({
    required this.reading,
    required this.listening,
    required this.fineTuners,
    required this.onDrag,
    required this.onLetGo,
  });

  final TunerReading? reading;
  final bool listening, fineTuners;

  /// Non-null in play mode, where the slider is a toy.
  final ValueChanged<double>? onDrag;
  final VoidCallback onLetGo;

  bool get _playing => onDrag != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = reading;
    final soft = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    const tab = [FontFeature.tabularFigures()];
    final digits = _playing ? 0 : 1;
    final cents = r == null
        ? '–'
        : '${r.cents > 0.05 ? '+' : r.cents < -0.05 ? '−' : '±'}${r.cents.abs().toStringAsFixed(digits)}¢';
    return Opacity(
      opacity: r != null && !r.live ? 0.6 : 1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(cents,
                  key: const ValueKey('tuner_cents'),
                  style: theme.textTheme.headlineSmall?.copyWith(fontFeatures: tab)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  r == null || _playing
                      ? ''
                      : '${r.hz.toStringAsFixed(1)} Hz · ${r.string.hz.toStringAsFixed(2)}',
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodySmall?.copyWith(color: soft, fontFeatures: tab),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _PitchSlider(cents: r?.cents, onChanged: onDrag, onEnd: onLetGo),
          const SizedBox(height: 4),
          Text(_status(r),
              key: const ValueKey('tuner_status'),
              textAlign: TextAlign.center,
              maxLines: 2,
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }

  String _status(TunerReading? r) {
    if (r == null) return listening ? 'Play a string' : '';
    final c = r.cents, a = c.abs();
    if (a <= 3) return _playing ? '' : 'In tune!';
    if (a > 40) {
      return c < 0 ? 'Very flat · the peg needs a turn up' : 'Very sharp · the peg needs a turn down';
    }
    if (!fineTuners) return c < 0 ? 'Flat · tighten the tuner' : 'Sharp · loosen the tuner';
    return c < 0 ? 'Flat · turn the fine tuner clockwise' : 'Sharp · turn the fine tuner anti-clockwise';
  }
}

/// −50..+50 cents with the ±3 in-tune zone, and "flat" and "sharp" under its
/// ends. Draggable when [onChanged] is set (play mode); otherwise it shows
/// the string's pitch.
class _PitchSlider extends StatelessWidget {
  const _PitchSlider({required this.cents, required this.onChanged, required this.onEnd});
  final double? cents;
  final ValueChanged<double>? onChanged;

  /// The finger came off (or the gesture was cancelled).
  final VoidCallback onEnd;

  static const thumb = 13.0;

  @override
  Widget build(BuildContext context) {
    final soft = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
    final label =
        TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: soft, letterSpacing: 0.4);
    final drag = onChanged;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      double toCents(double x) => ((x - thumb) / (w - 2 * thumb) * 100 - 50).clamp(-50.0, 50.0);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            slider: true,
            label: 'Pitch',
            value: cents == null ? 'none' : '${cents!.round()} cents',
            increasedValue: drag == null ? null : '${((cents ?? 0) + 5).clamp(-50, 50).round()} cents',
            decreasedValue: drag == null ? null : '${((cents ?? 0) - 5).clamp(-50, 50).round()} cents',
            onIncrease: drag == null ? null : () => drag(((cents ?? 0) + 5).clamp(-50, 50)),
            onDecrease: drag == null ? null : () => drag(((cents ?? 0) - 5).clamp(-50, 50)),
            child: GestureDetector(
              key: const ValueKey('tuner_slider'),
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: drag == null ? null : (d) => drag(toCents(d.localPosition.dx)),
              onHorizontalDragUpdate: drag == null ? null : (d) => drag(toCents(d.localPosition.dx)),
              onTapDown: drag == null ? null : (d) => drag(toCents(d.localPosition.dx)),
              // A tap that turns into a drag cancels the tap first; the drag
              // then stops the spring, so this is harmless mid-gesture.
              onTapUp: drag == null ? null : (_) => onEnd(),
              onHorizontalDragEnd: drag == null ? null : (_) => onEnd(),
              onHorizontalDragCancel: drag == null ? null : onEnd,
              child: SizedBox(
                height: 32,
                child: CustomPaint(
                    painter: _SliderPainter(cents, draggable: drag != null), size: Size.infinite),
              ),
            ),
          ),
          Row(
            children: [
              Text('flat', style: label),
              const Spacer(),
              Text('sharp', style: label),
            ],
          ),
        ],
      );
    });
  }
}

class _SliderPainter extends CustomPainter {
  _SliderPainter(this.cents, {required this.draggable});
  final double? cents;
  final bool draggable;

  @override
  void paint(Canvas canvas, Size size) {
    const t = _PitchSlider.thumb;
    final w = size.width, mid = size.height / 2;
    double x(double c) => t + (c.clamp(-50, 50) + 50) / 100 * (w - 2 * t);
    canvas.drawRRect(
        RRect.fromLTRBR(t / 2, mid - 5, w - t / 2, mid + 5, const Radius.circular(5)),
        Paint()..color = const Color(0xFFF2E5CE));
    canvas.drawRRect(RRect.fromLTRBR(x(-3), mid - 8, x(3), mid + 8, const Radius.circular(4)),
        Paint()..color = const Color(0x552E7D32));
    final tick = Paint()
      ..color = const Color(0x886A6180)
      ..strokeWidth = 1.2;
    for (final c in [-50.0, -25.0, -10.0, 0.0, 10.0, 25.0, 50.0]) {
      final half = c == 0 ? 11.0 : 7.0;
      canvas.drawLine(Offset(x(c), mid - half), Offset(x(c), mid + half), tick);
    }
    final c = cents;
    if (c == null) return;
    final a = c.abs();
    final col = a <= 3
        ? const Color(0xFF2E7D32)
        : a <= 10
            ? const Color(0xFFC9961C)
            : const Color(0xFFC62828);
    final r = draggable ? t : t * 0.62;
    if (draggable) {
      canvas.drawCircle(Offset(x(c), mid + 1.5), t, Paint()..color = const Color(0x332B2340));
    }
    canvas.drawCircle(Offset(x(c), mid), r, Paint()..color = col);
    canvas.drawCircle(
        Offset(x(c), mid),
        r,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5);
  }

  @override
  bool shouldRepaint(_SliderPainter old) => old.cents != cents || old.draggable != draggable;
}

class _Message extends StatelessWidget {
  const _Message({
    super.key,
    required this.text,
    this.action,
    required this.onAction,
    this.secondary,
    this.onSecondary,
  });
  final String text;
  final String? action, secondary;
  final VoidCallback onAction;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF2B2340), fontSize: 16, height: 1.4)),
            if (action != null) ...[
              const SizedBox(height: 14),
              FilledButton(onPressed: onAction, child: Text(action!)),
            ],
            if (secondary != null) TextButton(onPressed: onSecondary, child: Text(secondary!)),
          ],
        ),
      ),
    );
  }
}
