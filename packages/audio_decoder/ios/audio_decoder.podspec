#
# The native half of package:audio_decoder on iOS: AVAssetReader to mono
# Float32 PCM at the track's own rate. See ../README.md.
#
Pod::Spec.new do |s|
  s.name             = 'audio_decoder'
  s.version          = '0.1.0'
  s.summary          = 'Decodes an audio or video file to mono float PCM.'
  s.description      = <<-DESC
Decodes any file AVFoundation can open (mp3, m4a/aac, caf, aif, flac, and the
audio track of an mp4/mov) to mono Float32 PCM at the file's own sample rate.
                       DESC
  s.homepage         = 'https://github.com/jameshowison/violin_practice_companion'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'James Howison'
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.frameworks       = 'AVFoundation', 'CoreMedia'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
