import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

class SoundService {
  static final SoundService _instance = SoundService._internal();

  factory SoundService() {
    return _instance;
  }

  SoundService._internal();

  final FlutterTts _flutterTts = FlutterTts();
  static const _platform = MethodChannel('com.example.mobile_app/sound');
  bool _isInitialized = false;

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      await _flutterTts.setLanguage("en-US");
      await _flutterTts.setSpeechRate(0.5);
      await _flutterTts.setVolume(1.0);
      await _flutterTts.setPitch(1.0);
      _isInitialized = true;
    } catch (e) {
      print("Error initializing TTS: $e");
    }
  }

  Future<void> playSuccess({String message = "Success"}) async {
    try {
      // Play a positive beep (Type 1)
      await _platform.invokeMethod('playSystemSound', {'type': 1});
      await _speak(message);
    } catch (e) {
      print("Error playing success sound: $e");
    }
  }

  Future<void> playError({String message = "Error"}) async {
    try {
      // Play a negative beep (Type 2)
      await _platform.invokeMethod('playSystemSound', {'type': 2});
      await _speak(message);
    } catch (e) {
      print("Error playing error sound: $e");
    }
  }

  Future<void> speak(String message) async {
    await _speak(message);
  }

  Future<void> _speak(String message) async {
    if (!_isInitialized) await initialize();
    await _flutterTts.speak(message);
  }
}
