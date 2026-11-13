// iOS/Android/macOS listen through `record` on a background isolate; web is
// a stub (see tuner_input_web.dart).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'tuner_input_base.dart';
import 'tuner_input_io.dart' if (dart.library.html) 'tuner_input_web.dart';

export 'tuner_input_base.dart';

/// Makes the tuner's microphone input. Overridden in tests with a fake.
final tunerInputFactoryProvider =
    Provider<TunerInputBase Function()>((_) => TunerInput.new);
