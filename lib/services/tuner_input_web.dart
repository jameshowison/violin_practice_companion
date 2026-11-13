import 'tuner_input_base.dart';

/// Web stub. `record` can stream on the web, but there are no isolates there,
/// so the detector would run on the UI thread; not done yet.
class TunerInput implements TunerInputBase {
  @override
  bool get isSupported => false;

  @override
  Future<Stream<TunerFrame>> start({required double minHz, required double maxHz}) =>
      throw UnsupportedError('The tuner is not available on the web yet.');

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}
