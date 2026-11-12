package name.howison.violinPracticeCompanion

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var audioDecoder: AudioDecoderPlugin? = null
    private var contentResolver: ContentResolverPlugin? = null
    private var textRecognition: TextRecognitionPlugin? = null

    // Registered by hand because it is app-local rather than a pub package —
    // GeneratedPluginRegistrant only knows about pubspec dependencies. See
    // AudioDecoderPlugin.kt.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        audioDecoder = AudioDecoderPlugin(flutterEngine.dartExecutor.binaryMessenger)
        contentResolver = ContentResolverPlugin(
            flutterEngine.dartExecutor.binaryMessenger, applicationContext)
        textRecognition = TextRecognitionPlugin(flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        audioDecoder?.dispose()
        audioDecoder = null
        contentResolver?.dispose()
        contentResolver = null
        textRecognition?.dispose()
        textRecognition = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
