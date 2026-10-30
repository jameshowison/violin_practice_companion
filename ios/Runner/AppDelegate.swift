import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Without a category iOS applies the default one, which the ringer/silent
    // switch mutes: the score went silent on the phone while the simulator
    // (which ignores the switch) kept playing. Muting is the app's own button.
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Registered by hand because it is app-local rather than a pub package —
    // GeneratedPluginRegistrant only knows about pubspec dependencies. See
    // AudioDecoderPlugin.swift.
    AudioDecoderPlugin.register(
      with: engineBridge.pluginRegistry.registrar(forPlugin: "AudioDecoderPlugin")!)
  }
}
