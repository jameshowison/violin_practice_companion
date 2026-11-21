package name.howison.violinPracticeCompanion

import android.content.Context
import io.flutter.FlutterInjector
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import kotlin.concurrent.thread

/**
 * A real file path for a bundled Flutter asset — the Android half of
 * `ios/Runner/BundledAssetPlugin.swift`; see
 * `lib/services/bundled_asset_path_io.dart`.
 *
 * Unlike iOS, assets live inside the APK, so a plugin that wants a path needs
 * a copy. It goes in `cache/bundled_assets/<lastUpdateTime>/<key>`: keyed by
 * the install, so a changed asset can never be shadowed by an old copy under
 * the same name (the stale-soundfont bug), and older installs' copies are
 * deleted when a new one is made. Copied by streaming, never through Dart's
 * heap — the OMR decoder is 94 MB.
 *
 * Registered by hand from [MainActivity], like [MediaToolsPlugin].
 */
class BundledAssetPlugin(
    messenger: BinaryMessenger,
    private val context: Context,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME).apply {
        setMethodCallHandler(this@BundledAssetPlugin)
    }

    fun dispose() = channel.setMethodCallHandler(null)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val key = call.arguments as? String
        if (call.method != "path" || key == null) {
            result.notImplemented()
            return
        }
        // Off the platform thread: a first copy of the models takes seconds.
        thread(name = "bundled-asset") {
            try {
                val path = pathFor(key)
                onMain { result.success(path) }
            } catch (e: Exception) {
                onMain { result.error("copy_failed", e.toString(), null) }
            }
        }
    }

    private fun pathFor(key: String): String = synchronized(lock) {
        @Suppress("DEPRECATION")
        val version = context.packageManager
            .getPackageInfo(context.packageName, 0).lastUpdateTime.toString()
        val root = File(context.cacheDir, "bundled_assets")
        val out = File(File(root, version), key)
        if (out.exists()) return out.path
        root.listFiles()?.filter { it.name != version }?.forEach { it.deleteRecursively() }
        out.parentFile?.mkdirs()
        val part = File(out.path + ".part")
        val lookup = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(key)
        context.assets.open(lookup).use { input ->
            part.outputStream().use { input.copyTo(it, 1 shl 20) }
        }
        if (!part.renameTo(out)) throw IOException("could not move $part into place")
        out.path
    }

    private fun onMain(block: () -> Unit) {
        android.os.Handler(android.os.Looper.getMainLooper()).post(block)
    }

    companion object {
        const val CHANNEL_NAME = "stringlings/bundled_asset"
        private val lock = Any()
    }
}
