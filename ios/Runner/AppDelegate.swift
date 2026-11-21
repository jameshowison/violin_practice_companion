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
    // Play-and-record rather than .playback so the speaker sync calibration
    // can use the mic without switching sessions — see AudioCalibrationPlugin.
    AudioCalibrationPlugin.applyAppSession()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Registered by hand because they are app-local rather than pub packages —
    // GeneratedPluginRegistrant only knows about pubspec dependencies (which
    // now include packages/audio_decoder). See MediaToolsPlugin.swift.
    MediaToolsPlugin.register(
      with: engineBridge.pluginRegistry.registrar(forPlugin: "MediaToolsPlugin")!)
    AudioRoutePlugin.register(
      with: engineBridge.pluginRegistry.registrar(forPlugin: "AudioRoutePlugin")!)
    AudioCalibrationPlugin.register(
      with: engineBridge.pluginRegistry.registrar(forPlugin: "AudioCalibrationPlugin")!)
    IncomingSharePlugin.register(
      with: engineBridge.pluginRegistry.registrar(forPlugin: "IncomingSharePlugin")!)
    BundledAssetPlugin.register(
      with: engineBridge.pluginRegistry.registrar(forPlugin: "BundledAssetPlugin")!)
    VideoTransportPlugin.register(
      with: engineBridge.pluginRegistry.registrar(forPlugin: "VideoTransportPlugin")!)
  }
}
