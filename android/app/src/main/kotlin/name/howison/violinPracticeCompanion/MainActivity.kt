package name.howison.violinPracticeCompanion

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var audioDecoder: AudioDecoderPlugin? = null
    private var contentResolver: ContentResolverPlugin? = null
    private var textRecognition: TextRecognitionPlugin? = null
    private var incomingShare: IncomingSharePlugin? = null
    private var bundledAsset: BundledAssetPlugin? = null

    // Registered by hand because it is app-local rather than a pub package —
    // GeneratedPluginRegistrant only knows about pubspec dependencies. See
    // AudioDecoderPlugin.kt.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        audioDecoder = AudioDecoderPlugin(
            flutterEngine.dartExecutor.binaryMessenger, applicationContext)
        contentResolver = ContentResolverPlugin(
            flutterEngine.dartExecutor.binaryMessenger, applicationContext)
        textRecognition = TextRecognitionPlugin(flutterEngine.dartExecutor.binaryMessenger)
        incomingShare = IncomingSharePlugin(
            flutterEngine.dartExecutor.binaryMessenger, applicationContext)
        bundledAsset = BundledAssetPlugin(
            flutterEngine.dartExecutor.binaryMessenger, applicationContext)
    }

    // A shared piece (.stringlings) opened from Files, Quick Share or a mail
    // attachment: at launch, or while running (singleTop delivers it here).
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) incomingShare?.receive(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        incomingShare?.receive(intent)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        audioDecoder?.dispose()
        audioDecoder = null
        contentResolver?.dispose()
        contentResolver = null
        textRecognition?.dispose()
        textRecognition = null
        incomingShare?.dispose()
        incomingShare = null
        bundledAsset?.dispose()
        bundledAsset = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
