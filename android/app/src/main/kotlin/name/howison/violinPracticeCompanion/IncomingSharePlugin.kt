package name.howison.violinPracticeCompanion

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.concurrent.thread

/**
 * Hands a `.stringlings` file opened in the app (Quick Share, Files, a mail
 * attachment) to Dart — the Android half of `ios/Runner/IncomingSharePlugin.swift`;
 * see `lib/services/incoming_share.dart`.
 *
 * What arrives is a `content://` URI, readable only while this app holds the
 * grant, so it is copied into the cache folder first and Dart gets a plain
 * path. Paths are queued, never pushed: a file that launches the app arrives
 * before Dart is listening, so Dart drains the queue with `takePending` at
 * startup and whenever this sends `pending`.
 *
 * Registered by hand from [MainActivity], like [AudioDecoderPlugin].
 */
class IncomingSharePlugin(
    messenger: BinaryMessenger,
    private val context: Context,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME).apply {
        setMethodCallHandler(this@IncomingSharePlugin)
    }
    private val pending = mutableListOf<String>()

    fun dispose() = channel.setMethodCallHandler(null)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "takePending") {
            result.notImplemented()
            return
        }
        val paths = synchronized(pending) { pending.toList().also { pending.clear() } }
        result.success(paths)
    }

    /** Takes a VIEW or SEND intent; ignores anything else. */
    fun receive(intent: Intent?) {
        val uri: Uri = when (intent?.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND ->
                if (Build.VERSION.SDK_INT >= 33)
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else
                    @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM)
            else -> null
        } ?: return
        // Off the platform thread: a share with video is tens of MB.
        thread(name = "incoming-share") {
            val path = try { copyToCache(uri) } catch (e: Exception) { null } ?: return@thread
            synchronized(pending) { pending.add(path) }
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                channel.invokeMethod("pending", null)
            }
        }
    }

    private fun copyToCache(uri: Uri): String? {
        var name = "shared.stringlings"
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { c -> if (c.moveToFirst() && !c.isNull(0)) name = c.getString(0) }
        // Mail and chat apps often drop the extension or the type, so the
        // filter is broad; anything that isn't ours is refused here or by Dart.
        name = name.replace(Regex("[/\\\\]"), "_")
        if (!name.endsWith(".stringlings", ignoreCase = true)) name += ".stringlings"
        val dir = File(context.cacheDir, "incoming_share/${System.currentTimeMillis()}")
        dir.mkdirs()
        val out = File(dir, name)
        val input = context.contentResolver.openInputStream(uri) ?: return null
        input.use { i -> out.outputStream().use { o -> i.copyTo(o) } }
        return out.absolutePath
    }

    companion object {
        const val CHANNEL_NAME = "stringlings/incoming_share"
    }
}
