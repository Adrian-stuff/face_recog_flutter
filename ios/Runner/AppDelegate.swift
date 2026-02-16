import UIKit
import Flutter
import AVFoundation

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller : FlutterViewController = window?.rootViewController as! FlutterViewController
    let soundChannel = FlutterMethodChannel(name: "com.example.mobile_app/sound",
                                              binaryMessenger: controller.binaryMessenger)
    soundChannel.setMethodCallHandler({
      (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      if call.method == "playSystemSound" {
        if let args = call.arguments as? [String: Any],
           let type = args["type"] as? Int {
             if type == 1 {
                 // Success
                 AudioServicesPlaySystemSound(1052)
             } else {
                 // Error
                 AudioServicesPlaySystemSound(1053)
             }
        }
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    })

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
