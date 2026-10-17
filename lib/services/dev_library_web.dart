import 'dart:convert';
import 'dart:js_interop';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:web/web.dart' as web;

import 'dev_library_bundle.dart';

/// Web: the library arrives as `dev_library.json` next to `index.html`, written
/// into `web/` (gitignored) by `scripts/push_dev_library_web.sh`. Its absence
/// is the gate, as `state.json`'s is on io. Same constructor as the io version
/// so callers needn't branch.
class DevLibraryIngester {
  DevLibraryIngester();

  Future<Object?> ingest() async {
    final web.Response response;
    try {
      response = await web.window
          .fetch('dev_library.json'.toJS,
              web.RequestInit(cache: 'no-store'))
          .toDart;
    } catch (_) {
      return null;
    }
    if (!response.ok) return null;
    final text = (await response.text().toDart).toDart;
    // A dev server may answer an unknown path with index.html.
    if (!text.trimLeft().startsWith('{')) return null;
    final bundle = jsonDecode(text) as Map<String, dynamic>;
    return DevLibraryBundleMerger(await SharedPreferences.getInstance())
        .merge(bundle);
  }
}
