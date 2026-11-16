import 'dart:typed_data';

import 'tuner_input_base.dart';
import 'tuner_model.dart';

/// Web stub: nowhere to write to.
class TunerRecording {
  TunerRecording._();

  static Future<TunerRecording?> start({required String header}) async => null;

  String get name => '';
  void addPcm(Uint8List chunk) {}
  void addFrame(TunerFrame f, TunerModel m, String status) {}
  void event(String what) {}
  Future<void> close() async {}
}
