package com.example.violin_practice_companion

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

/**
 * Decodes any container the platform can open — mp3, m4a/aac, ogg, flac, and
 * the audio track of an mp4 — to mono `Float32` PCM at the source sample rate,
 * for the score-to-audio DTW alignment on the Dart side.
 *
 * WAV never arrives here: `package:wav` reads it in pure Dart, which is faster
 * than a channel round trip and works under `flutter test`. See
 * `lib/services/audio_decoder_io.dart`.
 *
 * Registered by hand from [MainActivity] rather than being a pub package: it
 * serves this app's one alignment pipeline and nothing else.
 */
class AudioDecoderPlugin(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME).apply {
        setMethodCallHandler(this@AudioDecoderPlugin)
    }

    fun dispose() = channel.setMethodCallHandler(null)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "decodeToPcm") {
            result.notImplemented()
            return
        }
        val path = call.argument<String>("path")
        if (path == null) {
            result.error("bad_args", "path is required", null)
            return
        }
        // Whole-file decode is seconds of CPU for a long recording, and this
        // callback runs on the UI thread. The result must be posted back to it.
        thread(name = "audio-decode") {
            try {
                val decoded = decode(path)
                postToMain {
                    result.success(
                        mapOf("sampleRate" to decoded.sampleRate, "samples" to decoded.samples)
                    )
                }
            } catch (e: Exception) {
                postToMain { result.error("decode_failed", e.message ?: "$e", path) }
            }
        }
    }

    private fun postToMain(block: () -> Unit) {
        android.os.Handler(android.os.Looper.getMainLooper()).post(block)
    }

    private class Decoded(val samples: FloatArray, val sampleRate: Double)

    /**
     * Pulls PCM out of the first audio track. MediaCodec emits whatever the
     * source's channel count and encoding are, so the mixdown to mono and the
     * conversion to float both happen here — unlike AVFoundation on iOS, there
     * is no way to ask the decoder to do it.
     */
    private fun decode(path: String): Decoded {
        val extractor = MediaExtractor()
        extractor.setDataSource(path)

        var trackIndex = -1
        var format: MediaFormat? = null
        for (i in 0 until extractor.trackCount) {
            val candidate = extractor.getTrackFormat(i)
            if (candidate.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                trackIndex = i
                format = candidate
                break
            }
        }
        if (trackIndex < 0 || format == null) {
            extractor.release()
            // An imported video with no audio track is a real case; the Dart
            // side turns this into "plays, but cannot drive the highlight".
            throw IllegalStateException("The file has no audio track.")
        }

        extractor.selectTrack(trackIndex)
        val sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val channels =
            if (format.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                format.getInteger(MediaFormat.KEY_CHANNEL_COUNT).coerceAtLeast(1)
            } else {
                1
            }

        val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
        codec.configure(format, null, null, 0)
        codec.start()

        val raw = ByteArrayOutputStream()
        val info = MediaCodec.BufferInfo()
        var sawInputEnd = false
        var sawOutputEnd = false
        var pcmEncoding = AudioFormatEncoding.PCM_16BIT

        try {
            while (!sawOutputEnd) {
                if (!sawInputEnd) {
                    val inputIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (inputIndex >= 0) {
                        val buffer = codec.getInputBuffer(inputIndex)!!
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(
                                inputIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM
                            )
                            sawInputEnd = true
                        } else {
                            codec.queueInputBuffer(inputIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                val outputIndex = codec.dequeueOutputBuffer(info, TIMEOUT_US)
                when {
                    outputIndex >= 0 -> {
                        val buffer = codec.getOutputBuffer(outputIndex)!!
                        if (info.size > 0) {
                            val chunk = ByteArray(info.size)
                            buffer.position(info.offset)
                            buffer.get(chunk, 0, info.size)
                            raw.write(chunk)
                        }
                        codec.releaseOutputBuffer(outputIndex, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            sawOutputEnd = true
                        }
                    }
                    outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        // Devices differ on whether they emit 16-bit or float
                        // PCM, and the real answer only arrives here — the
                        // input format does not state it.
                        pcmEncoding = AudioFormatEncoding.of(codec.outputFormat)
                    }
                }
            }
        } finally {
            codec.stop()
            codec.release()
            extractor.release()
        }

        val interleaved = toFloats(raw.toByteArray(), pcmEncoding)
        return Decoded(mixToMono(interleaved, channels), sampleRate.toDouble())
    }

    private enum class AudioFormatEncoding {
        PCM_16BIT,
        PCM_FLOAT;

        companion object {
            fun of(format: MediaFormat): AudioFormatEncoding {
                if (!format.containsKey(MediaFormat.KEY_PCM_ENCODING)) return PCM_16BIT
                // android.media.AudioFormat.ENCODING_PCM_FLOAT == 4
                return if (format.getInteger(MediaFormat.KEY_PCM_ENCODING) == 4) {
                    PCM_FLOAT
                } else {
                    PCM_16BIT
                }
            }
        }
    }

    private fun toFloats(bytes: ByteArray, encoding: AudioFormatEncoding): FloatArray {
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.nativeOrder())
        return when (encoding) {
            AudioFormatEncoding.PCM_FLOAT -> {
                val floats = buffer.asFloatBuffer()
                FloatArray(floats.remaining()).also { floats.get(it) }
            }
            AudioFormatEncoding.PCM_16BIT -> {
                val shorts = buffer.asShortBuffer()
                FloatArray(shorts.remaining()) { shorts.get(it) / 32768f }
            }
        }
    }

    /**
     * Averages channels rather than taking the first: a recording with the
     * instrument panned to one side would otherwise analyse as near-silence.
     */
    private fun mixToMono(interleaved: FloatArray, channels: Int): FloatArray {
        if (channels <= 1) return interleaved
        val frames = interleaved.size / channels
        return FloatArray(frames) { frame ->
            var sum = 0f
            for (c in 0 until channels) sum += interleaved[frame * channels + c]
            sum / channels
        }
    }

    companion object {
        private const val CHANNEL_NAME = "violin_practice_companion/audio_decoder"
        private const val TIMEOUT_US = 10_000L
    }
}
