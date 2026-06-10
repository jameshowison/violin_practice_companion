// Mobile/desktop uses flutter_doc_scanner + homr_omr; web is a stub pending
// a server-side homr backend.
export 'omr_service_base.dart';
export 'omr_service_io.dart' if (dart.library.html) 'omr_service_web.dart';
