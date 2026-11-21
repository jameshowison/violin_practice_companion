package name.howison.violinPracticeCompanion

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.EncoderUtil
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.math.abs
import kotlin.math.min

/**
 * Re-encodes an imported video's picture at a size it is actually shown at,
 * copying its audio across untouched — the Android half of the iOS plugin's
 * `shrinkVideo` (see `ios/Runner/MediaToolsPlugin.swift` for the reasoning,
 * and `lib/services/video_shrinker_io.dart` for the caller).
 *
 * Media3 Transformer copies (transmuxes) an audio track it has no reason to
 * touch, which is what keeps the cached alignment anchors valid. A track it
 * would HAVE to re-encode to fit an mp4 is refused up front instead, for the
 * same reason.
 */
@OptIn(UnstableApi::class)
class VideoShrinker(private val context: Context) {

    /** Runs on the main thread: Transformer must be built and started on a Looper thread. */
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        val source = call.argument<String>("source")
        val destination = call.argument<String>("destination")
        if (source == null || destination == null) {
            result.error("bad_args", "source and destination are required", null)
            return
        }
        val shortSide = call.argument<Int>("shortSide") ?: 720
        val bitrate = call.argument<Int>("bitrate") ?: 2_000_000

        val probe = try {
            probe(source)
        } catch (e: Exception) {
            result.error("shrink_failed", "Couldn't read the video: ${e.message}", source)
            return
        }
        val skip = when {
            probe.shortSide <= 0 -> "no video track"
            probe.audioMime != null && probe.audioMime != MimeTypes.AUDIO_AAC ->
                "audio can't be copied into mp4"
            probe.shortSide <= shortSide && probe.bitrate in 1..(bitrate * 3 / 2) -> "already small"
            else -> null
        }
        if (skip != null) {
            result.success(mapOf("skipped" to skip))
            return
        }

        File(destination).delete()
        // HEVC halves the bytes for the same picture; plenty of mid-range
        // phones only have an H.264 encoder.
        val mime =
            if (EncoderUtil.getSupportedEncoders(MimeTypes.VIDEO_H265).isNotEmpty()) {
                MimeTypes.VIDEO_H265
            } else {
                MimeTypes.VIDEO_H264
            }
        val encoderFactory = DefaultEncoderFactory.Builder(context)
            .setRequestedVideoEncoderSettings(
                VideoEncoderSettings.Builder()
                    .setBitrate(bitrate)
                    // A keyframe every second: the overlay corrects drift by
                    // seeking, and a seek lands on the keyframe before it.
                    .setiFrameIntervalSeconds(1f)
                    .build()
            )
            .setEnableFallback(true)
            .build()

        val transformer = Transformer.Builder(context)
            .setVideoMimeType(mime)
            .setEncoderFactory(encoderFactory)
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                    val problem = verify(source, destination, probe)
                    if (problem != null) {
                        File(destination).delete()
                        result.error("shrink_failed", problem, source)
                        return
                    }
                    val out = probe(destination)
                    result.success(
                        mapOf(
                            "width" to out.width,
                            "height" to out.height,
                            "codec" to if (mime == MimeTypes.VIDEO_H265) "hevc" else "h264",
                            "bytes" to File(destination).length(),
                        )
                    )
                }

                override fun onError(
                    composition: Composition,
                    exportResult: ExportResult,
                    exportException: ExportException,
                ) {
                    File(destination).delete()
                    result.error(
                        "shrink_failed", exportException.message ?: "$exportException", source
                    )
                }
            })
            .build()

        val item = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(File(source))))
            // By the SHORT side, so a portrait phone video comes out 720 wide
            // rather than 720 tall and a third of the width.
            .setEffects(Effects(listOf(), listOf(Presentation.createForShortSide(shortSide))))
            .build()
        try {
            transformer.start(item, destination)
        } catch (e: Exception) {
            File(destination).delete()
            result.error("shrink_failed", e.message ?: "$e", source)
        }
    }

    private class Probe(
        val width: Int,
        val height: Int,
        val bitrate: Int,
        val durationMs: Long,
        val audioMime: String?,
    ) {
        val shortSide get() = min(width, height)
    }

    private fun probe(path: String): Probe {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            fun int(key: Int) = retriever.extractMetadata(key)?.toIntOrNull() ?: 0
            val hasVideo = retriever.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO
            ) == "yes"
            return Probe(
                width = if (hasVideo) int(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH) else 0,
                height = if (hasVideo) int(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT) else 0,
                bitrate = int(MediaMetadataRetriever.METADATA_KEY_BITRATE),
                durationMs = retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_DURATION
                )?.toLongOrNull() ?: 0,
                audioMime = audioMimeOf(path),
            )
        } finally {
            retriever.release()
        }
    }

    private fun audioMimeOf(path: String): String? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            for (i in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME)
                if (mime?.startsWith("audio/") == true) return mime
            }
            return null
        } finally {
            extractor.release()
        }
    }

    /** Null if [destination] is a faithful replacement for [source]. */
    private fun verify(source: String, destination: String, before: Probe): String? {
        val after = try {
            probe(destination)
        } catch (e: Exception) {
            return "The new file can't be read: ${e.message}"
        }
        // More than 100 ms longer or shorter than its source, and the copy has
        // lost or gained part of the performance.
        if (abs(after.durationMs - before.durationMs) > 100) {
            return "The new file is ${after.durationMs - before.durationMs} ms off the original's length."
        }
        if (before.audioMime != null && after.audioMime == null) {
            return "The new file lost its audio track."
        }
        if (File(destination).length() >= File(source).length()) {
            return "The new file is no smaller."
        }
        return null
    }
}
