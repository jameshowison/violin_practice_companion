package name.howison.violinPracticeCompanion

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

/**
 * The app's own native media helpers, on `violin_practice_companion/media_tools`
 * (lib/services/media_tools.dart): `shrinkVideo` (handed to [VideoShrinker])
 * and `encodeAac` ([AacEncoder]). They once shared the decoder's channel; the
 * decoder is headed for a library and these write files in the app's own
 * formats, so they stay here.
 *
 * Registered by hand from [MainActivity].
 */
class MediaToolsPlugin(messenger: BinaryMessenger, context: Context) :
    MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME).apply {
        setMethodCallHandler(this@MediaToolsPlugin)
    }
    private val videoShrinker = VideoShrinker(context)

    fun dispose() = channel.setMethodCallHandler(null)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "shrinkVideo" -> videoShrinker.handle(call, result)
            "encodeAac" -> encodeAac(call, result)
            else -> result.notImplemented()
        }
    }

    private fun encodeAac(call: MethodCall, result: MethodChannel.Result) {
        val input = call.argument<String>("input")
        val output = call.argument<String>("output")
        if (input == null || output == null) {
            result.error("bad_args", "input and output are required", null)
            return
        }
        val bitRate = call.argument<Int>("bitRate") ?: 64000
        thread(name = "aac-encode") {
            try {
                AacEncoder.encode(input, output, bitRate)
                postToMain { result.success(null) }
            } catch (e: Exception) {
                java.io.File(output).delete()
                postToMain { result.error("encode_failed", e.message ?: "$e", input) }
            }
        }
    }

    private fun postToMain(block: () -> Unit) {
        android.os.Handler(android.os.Looper.getMainLooper()).post(block)
    }

    companion object {
        private const val CHANNEL_NAME = "violin_practice_companion/media_tools"
    }
}
