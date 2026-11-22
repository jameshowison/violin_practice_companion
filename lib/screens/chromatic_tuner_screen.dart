import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pitch_tuner/pitch_tuner.dart';

import '../models/app_edition.dart';
import '../models/instrument_profile.dart';
import '../services/keep_awake.dart';
import '../services/piece_display_prefs.dart' show sharedPreferencesProvider;
import '../services/players.dart' show playerKeyProvider;
import '../services/providers.dart' show instrumentProfileProvider;
import '../services/tuner_input.dart';
import 'tuner_screen.dart' show tunerA4Key;

/// The tuner for an instrument without strings (the recorder, in Windlings):
/// chromatic, so whatever note is played is measured against the nearest
/// semitone, and named as the player READS it — the written note, through
/// the profile's [InstrumentProfile.transposition]. A soprano recorder's
/// sounding C5 is its written C4, so it says C.
///
/// Deliberately plain for step W1: a note name, how many cents off, and
/// flat or sharp. No strings, so none of the string tuner's climber,
/// courses, headstock or drone (the drone tunes to a string; a wind tunes
/// to whatever note it holds). The string tuner ([TunerScreen]) is
/// untouched. The microphone is off until Listen is pressed, which is where
/// its permission is asked, as on the string tuner. The reference A is the
/// string tuner's setting (`tuner.a4`), read, not offered here.
///
/// Uses `pitch_tuner`'s [TunerModel] as it is: its onset and settling logic
/// was tuned for plucks and bows, and a breathy recorder tone may want a
/// sustained-tone segmenter and a lower clarity threshold
/// (docs/family/approach.md, 2.3). Untested on a real recorder.
class ChromaticTunerScreen extends ConsumerStatefulWidget {
  const ChromaticTunerScreen({super.key});

  @override
  ConsumerState<ChromaticTunerScreen> createState() =>
      _ChromaticTunerScreenState();
}

enum _Mic { off, starting, listening, denied, unavailable }

class _ChromaticTunerScreenState extends ConsumerState<ChromaticTunerScreen>
    with WidgetsBindingObserver {
  late final TunerInputBase _input;
  late final InstrumentProfile _profile;
  late final TunerModel _model;
  StreamSubscription<TunerFrame>? _sub;
  TunerReading? _reading;
  _Mic _mic = _Mic.off;
  String? _error;
  bool _resumeListening = false;

  @override
  void initState() {
    super.initState();
    _input = ref.read(tunerInputFactoryProvider)();
    _profile = ref.read(instrumentProfileProvider);
    final prefs = ref.read(sharedPreferencesProvider);
    final a4 = (prefs?.getInt(ref.read(playerKeyProvider)(tunerA4Key)) ?? 440) ==
            442
        ? 442.0
        : 440.0;
    _model = TunerModel(_tuningFor(_profile, a4));
    WidgetsBinding.instance.addObserver(this);
    KeepAwake.enable();
  }

  /// Every semitone the instrument can sound, with a tone's margin either
  /// side: its written range moved to sounding pitch.
  static InstrumentTuning _tuningFor(InstrumentProfile p, double a4) =>
      InstrumentTuning.chromatic(
          a4: a4,
          lowest: p.transposition.sounding(p.lowestMidi) - 2,
          highest: p.transposition.sounding(p.highestMidi) + 2);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    KeepAwake.disable();
    _sub?.cancel();
    _input.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_resumeListening) _start();
      _resumeListening = false;
    } else if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden) &&
        _listening) {
      _resumeListening = true;
      _stop();
    }
  }

  bool get _listening => _mic == _Mic.listening || _mic == _Mic.starting;

  Future<void> _start() async {
    if (!_input.isSupported) {
      setState(() => _mic = _Mic.unavailable);
      return;
    }
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
    if (mounted) setState(() => _mic = _Mic.off);
    await _input.stop();
  }

  void _onFrame(TunerFrame f) {
    if (!_model.add(f)) return;
    final r = _model.reading;
    if (r != null && mounted) setState(() => _reading = r);
  }

  /// The written name of [target], such as `C4` for the recorder's C5.
  String _written(TunedString target) =>
      _profile.transposition.writtenName(target);

  /// A note name without its octave: `C♯4` → `C♯`.
  static String _letter(String name) => name.replaceAll(RegExp(r'-?\d+$'), '');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = _reading;
    final body = switch (_mic) {
      _Mic.denied => _Message(
          key: const ValueKey('tuner_mic_denied'),
          text: 'The tuner needs the microphone to hear your notes. Allow it '
              'for ${ref.read(appEditionProvider).appName} in Settings, then '
              'come back.',
          action: 'Try again',
          onAction: _start,
        ),
      _Mic.unavailable => _Message(
          key: const ValueKey('tuner_unavailable'),
          text: _error == null
              ? 'The tuner can\'t listen on this device.'
              : 'The microphone could not start.\n$_error',
          action: _error == null ? null : 'Try again',
          onAction: _start,
        ),
      _ => Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              r == null ? '–' : _letter(_written(r.string)),
              key: const ValueKey('tuner_note'),
              style: theme.textTheme.displayLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: r != null && r.inTune ? Colors.green.shade700 : null),
            ),
            const SizedBox(height: 4),
            Text(
              r == null
                  ? (_listening ? 'Play a long note' : 'Press Listen, then play a long note')
                  : '${_written(r.string)} as written · sounds ${r.string.name}',
              key: const ValueKey('tuner_written'),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            _CentsBar(cents: r?.cents),
            const SizedBox(height: 8),
            Text(
              r == null
                  ? ''
                  : r.inTune
                      ? 'In tune'
                      : '${r.cents.abs().round()} cents ${r.cents < 0 ? 'flat' : 'sharp'}',
              key: const ValueKey('tuner_status'),
              style: theme.textTheme.titleMedium,
            ),
          ],
        ),
    };
    return Scaffold(
      appBar: AppBar(title: Text('${_profile.displayName} tuner')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: body),
              FilledButton.icon(
                key: const ValueKey('tuner_listen'),
                icon: Icon(_listening ? Icons.mic_off : Icons.mic),
                label: Text(_listening ? 'Stop' : 'Listen'),
                onPressed: _listening ? _stop : _start,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// How far off, on a bar from 50 cents flat to 50 sharp, the middle in tune.
class _CentsBar extends StatelessWidget {
  const _CentsBar({required this.cents});

  final double? cents;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = cents;
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;
      final x = c == null ? null : (c.clamp(-50, 50) + 50) / 100 * w;
      return SizedBox(
        height: 48,
        child: Stack(children: [
          Positioned(
            left: 0,
            right: 0,
            top: 16,
            child: Container(height: 4, color: scheme.outlineVariant),
          ),
          Positioned(
            left: w / 2 - 1,
            top: 4,
            child: Container(width: 2, height: 28, color: scheme.outline),
          ),
          if (x != null)
            Positioned(
              left: x - 6,
              top: 6,
              child: Container(
                key: const ValueKey('tuner_needle'),
                width: 12,
                height: 24,
                decoration: BoxDecoration(
                  color: c!.abs() <= TunerModel.inTuneCents
                      ? Colors.green.shade600
                      : scheme.primary,
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
          const Positioned(left: 0, bottom: 0, child: Text('flat')),
          const Positioned(right: 0, bottom: 0, child: Text('sharp')),
        ]),
      );
    });
  }
}

class _Message extends StatelessWidget {
  const _Message(
      {super.key, required this.text, this.action, required this.onAction});

  final String text;
  final String? action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(text, textAlign: TextAlign.center),
          if (action != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onAction, child: Text(action!)),
          ],
        ]),
      );
}
