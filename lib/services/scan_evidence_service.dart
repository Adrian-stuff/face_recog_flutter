import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Produces the small face crops stored alongside each scan.
///
/// The full liveness capture is a multi-megapixel camera frame; keeping one
/// per scan would fill the device and make uploads impractical. What a
/// dispute actually needs is enough to recognise a face and read a
/// timestamp, so these are downscaled hard and compressed.
class ScanEvidenceService {
  ScanEvidenceService._();

  /// Long edge of the stored crop, in pixels. Recognisable at a glance
  /// without being a usable biometric sample on its own.
  static const int _maxDimension = 240;
  static const int _jpegQuality = 55;

  /// Reads a capture off disk and returns a base64 JPEG thumbnail.
  ///
  /// Returns null rather than throwing: evidence is valuable but never worth
  /// failing an attendance action over. A scan with no thumbnail still
  /// records its metadata, which is the part that proves it happened.
  static Future<String?> thumbnailFromFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;

      final bytes = await file.readAsBytes();

      // Decoding a camera-resolution JPEG takes long enough to drop frames on
      // the kiosk's UI thread, and this runs right after a scan while the
      // success animation is playing.
      return await compute(_encodeThumbnail, bytes);
    } catch (e) {
      debugPrint('ScanEvidenceService: failed to build thumbnail: $e');
      return null;
    }
  }

  static String? _encodeThumbnail(Uint8List bytes) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;

      final resized = decoded.width >= decoded.height
          ? img.copyResize(decoded, width: _maxDimension)
          : img.copyResize(decoded, height: _maxDimension);

      return base64Encode(img.encodeJpg(resized, quality: _jpegQuality));
    } catch (e) {
      debugPrint('ScanEvidenceService: thumbnail encode failed: $e');
      return null;
    }
  }
}
