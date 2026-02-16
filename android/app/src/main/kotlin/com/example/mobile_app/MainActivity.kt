package com.example.mobile_app

import android.media.AudioManager
import android.media.ToneGenerator
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.mobile_app/sound"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler {
            call, result ->
            if (call.method == "playSystemSound") {
                val toneType = call.argument<Int>("type")
                val toneGenerator = ToneGenerator(AudioManager.STREAM_NOTIFICATION, 100)
                if (toneType == 1) {
                    // Success Beep
                     toneGenerator.startTone(ToneGenerator.TONE_PROP_BEEP)
                } else {
                    // Error Beep (Double beep or different tone)
                     toneGenerator.startTone(ToneGenerator.TONE_SUP_ERROR)
                }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }
}
