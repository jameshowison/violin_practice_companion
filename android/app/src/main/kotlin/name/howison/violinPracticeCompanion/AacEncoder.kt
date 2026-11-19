package name.howison.violinPracticeCompanion

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * The rendered score (lib/services/rendered_score_cache_io.dart): a WAV the
 * Dart side rendered — 16-bit PCM, its own 44-byte header — re-encoded as the
 * app's recordings are, AAC-LC in an MPEG-4 file, by the platform's encoder.
 * The iOS twin is `encodeAac` in AudioDecoderPlugin.swift.
 */
object AacEncoder {
    fun encode(input: String, output: String, bitRate: Int) {
        val wav = RandomAccessFile(input, "r")
        val header = ByteArray(44)
        wav.readFully(header)
        val h = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
        require(String(header, 0, 4) == "RIFF" && String(header, 36, 4) == "data") {
            "not a plain 44-byte-header WAV"
        }
        val channels = h.getShort(22).toInt()
        val sampleRate = h.getInt(24)
        require(h.getShort(34).toInt() == 16) { "16-bit PCM only" }
        val dataBytes = h.getInt(40).toLong()

        val format = MediaFormat.createAudioFormat(
            MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, channels
        ).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        File(output).delete()
        val muxer = MediaMuxer(output, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var track = -1
        try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
            val info = MediaCodec.BufferInfo()
            val frameBytes = 2 * channels
            var readBytes = 0L
            var inputDone = false
            var outputDone = false
            val chunk = ByteArray(16384)
            while (!outputDone) {
                if (!inputDone) {
                    val i = codec.dequeueInputBuffer(2_000)
                    if (i >= 0) {
                        val buf = codec.getInputBuffer(i)!!
                        buf.clear()
                        val want = minOf(buf.remaining().toLong(), chunk.size.toLong(),
                            dataBytes - readBytes).toInt() / frameBytes * frameBytes
                        val pts = readBytes / frameBytes * 1_000_000L / sampleRate
                        if (want <= 0) {
                            codec.queueInputBuffer(i, 0, 0, pts,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            wav.readFully(chunk, 0, want)
                            buf.put(chunk, 0, want)
                            codec.queueInputBuffer(i, 0, want, pts, 0)
                            readBytes += want
                        }
                    }
                }
                // Drain everything ready: one input chunk is several AAC
                // frames, and taking one per pass with a wait each made the
                // timeouts, not the encoder, set the pace (38 s for a 55 s
                // piece on the emulator).
                while (true) {
                    val o = codec.dequeueOutputBuffer(info, if (inputDone) 10_000 else 0)
                    if (o == MediaCodec.INFO_TRY_AGAIN_LATER) break
                    if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        track = muxer.addTrack(codec.outputFormat)
                        muxer.start()
                        continue
                    }
                    if (o < 0) continue
                    val buf = codec.getOutputBuffer(o)!!
                    val config = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    if (!config && info.size > 0 && track >= 0) {
                        buf.position(info.offset)
                        buf.limit(info.offset + info.size)
                        muxer.writeSampleData(track, buf, info)
                    }
                    codec.releaseOutputBuffer(o, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        outputDone = true
                        break
                    }
                }
            }
        } finally {
            wav.close()
            try { codec.stop() } catch (_: Exception) {}
            codec.release()
            try { if (track >= 0) muxer.stop() } catch (_: Exception) {}
            muxer.release()
        }
    }
}
