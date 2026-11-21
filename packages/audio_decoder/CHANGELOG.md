## 0.1.0

- First version, moved out of Stringlings: `AudioDecoder` (decode a file or
  in-memory bytes to `PcmAudio`), the importable extension lists and
  `isVideoExtension`, and the native decoders, now a Flutter plugin
  registered by the generated registrant. The channel is `audio_decoder`
  and carries `decodeToPcm` only.
