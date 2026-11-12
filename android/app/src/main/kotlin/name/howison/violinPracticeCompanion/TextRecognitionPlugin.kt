package name.howison.violinPracticeCompanion

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.os.Handler
import android.os.Looper
import androidx.exifinterface.media.ExifInterface
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Printed-text recognition with ML Kit, for reading a scanned piece's title:
 * the Android side of `ios/Runner/TextRecognitionPlugin.swift`, same channel
 * and same reply. Dart decides WHERE to look (`lib/services/title_region.dart`)
 * and WHICH line is the title; this only reads every line in that region.
 *
 * Coordinates crossing the channel are normalised to the upright image with a
 * top-left origin, as on iOS. "Upright" means after the JPEG's EXIF
 * orientation, which Flutter's decoder (and so the crop locator) applies.
 *
 * ML Kit has no region of interest, so the region is cut out of the bitmap and
 * the boxes mapped back. The bundled Latin-script model stands in for iOS's
 * explicit Latin languages list: the books are English with European
 * translations, and pencil marks read as other scripts are noise.
 *
 * Registered by hand from [MainActivity], like [AudioDecoderPlugin].
 */
class TextRecognitionPlugin(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME).apply {
        setMethodCallHandler(this@TextRecognitionPlugin)
    }
    private val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
    private val main = Handler(Looper.getMainLooper())

    fun dispose() {
        channel.setMethodCallHandler(null)
        recognizer.close()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "recognizeText") {
            result.notImplemented()
            return
        }
        val bytes = call.argument<ByteArray>("image")
        if (bytes == null) {
            result.error("bad_args", "image bytes required", null)
            return
        }
        val region = call.argument<List<Double>>("region") ?: listOf(0.0, 0.0, 1.0, 1.0)
        thread(name = "text-recognition") {
            try {
                val lines = recognize(bytes, region)
                main.post { result.success(lines) }
            } catch (e: Exception) {
                main.post { result.error("recognize_failed", e.toString(), null) }
            }
        }
    }

    private fun recognize(bytes: ByteArray, region: List<Double>): List<Map<String, Any>> {
        val page = upright(bytes)
        val w = page.width.toDouble()
        val h = page.height.toDouble()

        // Clamp to the image, as iOS intersects with the unit square.
        var (rx, ry, rw, rh) = if (region.size == 4) region else listOf(0.0, 0.0, 1.0, 1.0)
        val left = max(0.0, rx); val top = max(0.0, ry)
        rw = min(1.0, rx + rw) - left; rh = min(1.0, ry + rh) - top
        rx = left; ry = top
        val px = (rx * w).roundToInt().coerceIn(0, page.width - 1)
        val py = (ry * h).roundToInt().coerceIn(0, page.height - 1)
        val pw = (rw * w).roundToInt().coerceIn(1, page.width - px)
        val ph = (rh * h).roundToInt().coerceIn(1, page.height - py)
        val crop = Bitmap.createBitmap(page, px, py, pw, ph)

        val text = Tasks.await(recognizer.process(InputImage.fromBitmap(crop, 0)))
        return text.textBlocks.flatMap { it.lines }.mapNotNull { line ->
            val b = line.boundingBox ?: return@mapNotNull null
            mapOf(
                "text" to lineText(line),
                "confidence" to line.confidence.toDouble(),
                // Crop pixels → whole-image fractions, top-left origin.
                "box" to listOf(
                    (px + b.left) / w, (py + b.top) / h, b.width() / w, b.height() / h),
            )
        }
    }

    /**
     * The line from its words, not `line.text`: ML Kit's line string can drop
     * a word gap ("Go TellAunt Rhody") that its word split keeps.
     *
     * Also drops one leading page number. The books box a number beside each
     * title; Vision never returns it with the title, but ML Kit reads it as the
     * line's first word ("10 Allegretto", "9] Perpetual Motion", the box's
     * edge read as "]" or "J"). It can't be split off by spacing: on the dev-library
     * scans its gap is 0.0-0.4 of the text height, the same as a word space.
     */
    private fun lineText(line: Text.Line): String {
        val words = line.elements.map { it.text }
        if (words.isEmpty()) return line.text
        val kept = if (words.size > 1 && words[0].matches(PAGE_NUMBER)) words.drop(1) else words
        return kept.joinToString(" ")
    }

    /** The image as Flutter decodes it: EXIF rotation and mirroring applied. */
    private fun upright(bytes: ByteArray): Bitmap {
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            ?: throw IllegalArgumentException("could not decode image")
        val exif = try {
            ExifInterface(bytes.inputStream())
        } catch (_: Exception) {
            return bitmap // PNG without EXIF, say
        }
        val degrees = exif.rotationDegrees
        if (degrees == 0 && !exif.isFlipped) return bitmap
        val m = Matrix().apply {
            if (exif.isFlipped) postScale(-1f, 1f)
            postRotate(degrees.toFloat())
        }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, m, true)
    }

    companion object {
        const val CHANNEL_NAME = "violin_practice_companion/text_recognition"
        private val PAGE_NUMBER = Regex("^[\\[(]?[0-9]{1,3}[\\])|.J]?$")
    }
}
