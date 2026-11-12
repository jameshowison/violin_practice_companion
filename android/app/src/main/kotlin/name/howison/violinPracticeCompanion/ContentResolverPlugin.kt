package name.howison.violinPracticeCompanion

import android.content.Context
import android.net.Uri
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

/**
 * Reads the bytes behind a `content://` URI. On Android the document scanner
 * (flutter_doc_scanner, ML Kit) returns content URIs rather than file paths;
 * `OmrService._resolveToFile` in `lib/services/omr_service_io.dart` copies
 * them into the cache dir through this channel. iOS never calls it.
 *
 * Registered by hand from [MainActivity], like [AudioDecoderPlugin].
 */
class ContentResolverPlugin(
    messenger: BinaryMessenger,
    private val context: Context,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME).apply {
        setMethodCallHandler(this@ContentResolverPlugin)
    }

    fun dispose() = channel.setMethodCallHandler(null)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "readBytes") {
            result.notImplemented()
            return
        }
        val uri = call.argument<String>("uri")
        if (uri == null) {
            result.error("bad_args", "uri is required", null)
            return
        }
        // Off the platform thread: a scanned page is several MB.
        thread(name = "content-resolver") {
            try {
                val bytes = context.contentResolver.openInputStream(Uri.parse(uri))
                    ?.use { it.readBytes() }
                postResult {
                    if (bytes == null) result.error("not_found", "cannot open $uri", null)
                    else result.success(bytes)
                }
            } catch (e: Exception) {
                postResult { result.error("read_failed", e.message, null) }
            }
        }
    }

    private fun postResult(block: () -> Unit) =
        android.os.Handler(android.os.Looper.getMainLooper()).post(block)

    companion object {
        const val CHANNEL_NAME = "dev.homr/content_resolver"
    }
}
