import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:face_anti_spoofing_detector/face_anti_spoofing_detector.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

// --- Top-Level Functions for Isolate Processing ---

class CameraImageData {
  final int width;
  final int height;
  final List<Uint8List> planesBytes;
  final List<int> bytesPerRow;
  final List<int?> bytesPerPixel;
  final int rotation;

  CameraImageData({
    required this.width,
    required this.height,
    required this.planesBytes,
    required this.bytesPerRow,
    required this.bytesPerPixel,
    required this.rotation,
  });

  factory CameraImageData.fromCameraImage(CameraImage image, int rotation) {
    return CameraImageData(
      width: image.width,
      height: image.height,
      planesBytes: image.planes.map((p) => p.bytes).toList(),
      bytesPerRow: image.planes.map((p) => p.bytesPerRow).toList(),
      bytesPerPixel: image.planes.map((p) => p.bytesPerPixel).toList(),
      rotation: rotation,
    );
  }
}

/// Isolate function: Convert YUV to RGB
img.Image? convertYuvToRgbIsolate(CameraImageData data) {
  try {
    final int width = data.width;
    final int height = data.height;
    final int uvRowStride = data.bytesPerRow[1];
    final int uvPixelStride = data.bytesPerPixel[1] ?? 1;

    final Uint8List yPlane = data.planesBytes[0];
    final Uint8List uPlane = data.planesBytes[1];
    final Uint8List vPlane = data.planesBytes[2];

    var imgBuffer = img.Image(width: width, height: height);

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int yIndex = y * width + x;
        final int uvIndex = uvPixelStride * (x ~/ 2) + uvRowStride * (y ~/ 2);

        if (yIndex >= yPlane.length ||
            uvIndex >= uPlane.length ||
            uvIndex >= vPlane.length) {
          continue;
        }

        final yp = yPlane[yIndex];
        final up = uPlane[uvIndex];
        final vp = vPlane[uvIndex];

        int r = (yp + (1.370705 * (vp - 128))).round().clamp(0, 255);
        int g = (yp - (0.337633 * (up - 128)) - (0.698001 * (vp - 128)))
            .round()
            .clamp(0, 255);
        int b = (yp + (1.732446 * (up - 128))).round().clamp(0, 255);

        imgBuffer.setPixelRgb(x, y, r, g, b);
      }
    }

    if (data.rotation == 90) return img.copyRotate(imgBuffer, angle: 90);
    if (data.rotation == 270) return img.copyRotate(imgBuffer, angle: -90);
    if (data.rotation == 180) return img.copyRotate(imgBuffer, angle: 180);

    return imgBuffer;
  } catch (e) {
    debugPrint("Isolate Error converting YUV: $e");
    return null;
  }
}

/// Isolate function: Convert to Planar YUV (for Anti-Spoofing)
Uint8List convertYuvToPlanarIsolate(CameraImageData data) {
  final int width = data.width;
  final int height = data.height;
  final int ySize = width * height;
  final int uvWidth = width ~/ 2;
  final int uvHeight = height ~/ 2;
  final int uvPlaneSize = uvWidth * uvHeight;

  final Uint8List result = Uint8List(ySize + uvPlaneSize * 2);

  // Y Plane
  final Uint8List yPlane = data.planesBytes[0];
  final int yRowStride = data.bytesPerRow[0];
  for (int row = 0; row < height; row++) {
    final int srcOffset = row * yRowStride;
    final int dstOffset = row * width;
    final int end = srcOffset + width;
    if (end <= yPlane.length) {
      result.setRange(
        dstOffset,
        dstOffset + width,
        yPlane.buffer.asUint8List(yPlane.offsetInBytes + srcOffset, width),
      );
    }
  }

  // U Plane
  final Uint8List uPlane = data.planesBytes[1];
  final int uvRowStride = data.bytesPerRow[1];
  final int uvPixelStride = data.bytesPerPixel[1] ?? 1;
  int uOffset = ySize;
  for (int row = 0; row < uvHeight; row++) {
    for (int col = 0; col < uvWidth; col++) {
      final int idx = row * uvRowStride + col * uvPixelStride;
      if (idx < uPlane.length) {
        result[uOffset++] = uPlane[idx];
      }
    }
  }

  // V Plane
  final Uint8List vPlane = data.planesBytes[2];
  int vOffset = ySize + uvPlaneSize;
  for (int row = 0; row < uvHeight; row++) {
    for (int col = 0; col < uvWidth; col++) {
      final int idx = row * uvRowStride + col * uvPixelStride;
      if (idx < vPlane.length) {
        result[vOffset++] = vPlane[idx];
      }
    }
  }

  return result;
}

/// Isolate function: Convert to NV21 (for ML Kit)
Uint8List convertYuvToNv21Isolate(CameraImageData data) {
  final int width = data.width;
  final int height = data.height;
  final int ySize = width * height;
  final int uvSize = width * height ~/ 2;

  final Uint8List nv21 = Uint8List(ySize + uvSize);

  // Y Plane
  final Uint8List yPlane = data.planesBytes[0];
  final int yRowStride = data.bytesPerRow[0];

  if (yRowStride == width) {
    nv21.setRange(0, ySize, yPlane);
  } else {
    for (int row = 0; row < height; row++) {
      final int srcOffset = row * yRowStride;
      final int dstOffset = row * width;
      nv21.setRange(
        dstOffset,
        dstOffset + width,
        yPlane.buffer.asUint8List(yPlane.offsetInBytes + srcOffset, width),
      );
    }
  }

  // Interleave V and U (NV21 = V then U)
  final Uint8List uPlane = data.planesBytes[1];
  final Uint8List vPlane = data.planesBytes[2];
  final int uvRowStride = data.bytesPerRow[1];
  final int uvPixelStride = data.bytesPerPixel[1] ?? 1;

  int offset = ySize;
  for (int row = 0; row < height ~/ 2; row++) {
    for (int col = 0; col < width ~/ 2; col++) {
      final int uvIndex = row * uvRowStride + col * uvPixelStride;
      if (uvIndex < vPlane.length &&
          uvIndex < uPlane.length &&
          offset + 1 < nv21.length) {
        nv21[offset++] = vPlane[uvIndex]; // V
        nv21[offset++] = uPlane[uvIndex]; // U
      }
    }
  }

  return nv21;
}

// --------------------------------------------------------

class FaceService {
  static final FaceService _instance = FaceService._internal();
  factory FaceService() => _instance;
  FaceService._internal();

  FaceDetector? _faceDetector;
  Interpreter? _interpreter;
  bool _isInitialized = false;
  String? _interpreterError;
  Completer<void>? _initCompleter;

  bool get isInterpreterReady => _interpreter != null;
  String? get interpreterErrorMessage => _interpreterError;

  Future<void> initialize() async {
    if (_isInitialized) return;

    if (_initCompleter != null) {
      await _initCompleter!.future;
      return;
    }

    _initCompleter = Completer<void>();

    try {
      _faceDetector ??= FaceDetector(
        options: FaceDetectorOptions(
          enableContours: true,
          enableClassification: true,
          enableLandmarks: true,
          performanceMode: FaceDetectorMode.accurate,
        ),
      );

      await FaceAntiSpoofingDetector.initialize();

      try {
        final options = InterpreterOptions();
        _interpreter = await Interpreter.fromAsset(
          'mobilefacenet.tflite',
          options: options,
        );
        _interpreterError = null;
        debugPrint('Face Recognition Model Loaded');
      } catch (e) {
        _interpreterError = e.toString();
        debugPrint('Failed to load Face Recognition Model: $e');
      }

      _isInitialized = true;
      _initCompleter!.complete();
    } catch (e) {
      _initCompleter!.completeError(e);
      _initCompleter = null;
      rethrow;
    }
  }

  void dispose() {
    _faceDetector?.close();
    _faceDetector = null;
    FaceAntiSpoofingDetector.destroy();
    _interpreter?.close();
    _interpreter = null;
    _isInitialized = false;
    _initCompleter = null;
  }

  Future<Map<String, dynamic>> processImage(
    CameraImage image,
    int rotation,
  ) async {
    try {
      if (!_isInitialized) await initialize();

      if (!_isValidCameraImage(image)) {
        return {'error': 'Invalid camera frame'};
      }

      // Convert CameraImage to DTO for isolate
      final imageData = CameraImageData.fromCameraImage(image, rotation);

      // 1. Run NV21 conversion in background isolate
      final Uint8List nv21Bytes = await compute(
        convertYuvToNv21Isolate,
        imageData,
      );

      final inputImage = InputImage.fromBytes(
        bytes: nv21Bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation:
              InputImageRotationValue.fromRawValue(rotation) ??
              InputImageRotation.rotation0deg,
          format: InputImageFormat.nv21,
          bytesPerRow: image.width,
        ),
      );

      // 2. Detect Faces
      if (_faceDetector == null) {
        return {'error': 'Face detector not initialized'};
      }
      final List<Face> faces = await _faceDetector!.processImage(inputImage);

      if (faces.isEmpty) {
        return {'error': 'No face detected'};
      }

      if (faces.length > 1) {
        return {'error': 'Multiple faces detected'};
      }

      final Face face = faces.first;

      // 3. Planar YUV conversion for Anti-Spoofing (Background Isolate)
      final Uint8List planarYuv = await compute(
        convertYuvToPlanarIsolate,
        imageData,
      );

      final score = await FaceAntiSpoofingDetector.detect(
        yuvBytes: planarYuv,
        previewWidth: image.width,
        previewHeight: image.height,
        orientation: rotation,
        faceContour: face.boundingBox,
      );

      final isLive = (score ?? 0.0) >= 0.8;

      return {'face': face, 'isLive': isLive, 'score': score, 'error': null};
    } catch (e) {
      debugPrint('Detection failed: $e');
      return {'error': 'Detection failed: $e'};
    }
  }

  Future<List<double>?> getFaceEmbedding(
    CameraImage cameraImage,
    Face face,
    int rotation,
  ) async {
    if (_interpreter == null) {
      debugPrint('Interpreter not initialized');
      return null;
    }

    try {
      if (!_isValidCameraImage(cameraImage)) {
        debugPrint('Invalid camera image for embedding');
        return null;
      }

      final imageData = CameraImageData.fromCameraImage(cameraImage, rotation);

      // 1. Convert YUV to RGB Image (Background Isolate)
      img.Image? image = await compute(convertYuvToRgbIsolate, imageData);
      if (image == null) return null;

      // 2. Crop Face
      final Rect boundingBox = face.boundingBox;
      int left = max(0, boundingBox.left.toInt());
      int top = max(0, boundingBox.top.toInt());
      int right = min(image.width, boundingBox.right.toInt());
      int bottom = min(image.height, boundingBox.bottom.toInt());
      int width = right - left;
      int height = bottom - top;

      // Guard against zero or negative crop dimensions
      if (width <= 0 || height <= 0) {
        debugPrint('Invalid crop dimensions: ${width}x$height');
        return null;
      }

      img.Image croppedImage = img.copyCrop(
        image,
        x: left,
        y: top,
        width: width,
        height: height,
      );

      // 3. Resize to 112x112
      img.Image resizedImage = img.copyResize(
        croppedImage,
        width: 112,
        height: 112,
      );

      // 4. Preprocess (Normalize)
      final input = _imageToFloatList(resizedImage);

      // 5. Run Inference
      final outputShape = _interpreter!.getOutputTensor(0).shape;
      final outputLength = outputShape[1];

      var output = List.generate(1, (_) => List.filled(outputLength, 0.0));
      _interpreter!.run(input, output);

      final embedding = List<double>.from(output[0]);

      // 6. L2 Normalize
      return _l2Normalize(embedding);
    } catch (e) {
      debugPrint('Error generating embedding: $e');
      return null;
    }
  }

  // Helper: Convert CameraImage to RGB via Isolate (exposed wrapper)
  Future<img.Image?> convertCameraToRgb(
    CameraImage cameraImage,
    int rotation,
  ) async {
    if (!_isValidCameraImage(cameraImage)) return null;
    final imageData = CameraImageData.fromCameraImage(cameraImage, rotation);
    return await compute(convertYuvToRgbIsolate, imageData);
  }

  /// Generate Face Embedding from a pre-decoded RGB image and face bounding box.
  Future<List<double>?> getEmbeddingFromRgbImage(
    img.Image image,
    Rect boundingBox,
  ) async {
    if (_interpreter == null) {
      debugPrint('Interpreter not initialized');
      return null;
    }

    try {
      // Crop face region
      int left = max(0, boundingBox.left.toInt());
      int top = max(0, boundingBox.top.toInt());
      int right = min(image.width, boundingBox.right.toInt());
      int bottom = min(image.height, boundingBox.bottom.toInt());
      int width = right - left;
      int height = bottom - top;

      if (width <= 0 || height <= 0) {
        debugPrint('Invalid crop dimensions: ${width}x$height');
        return null;
      }

      img.Image croppedImage = img.copyCrop(
        image,
        x: left,
        y: top,
        width: width,
        height: height,
      );

      // Resize to 112x112
      img.Image resizedImage = img.copyResize(
        croppedImage,
        width: 112,
        height: 112,
      );

      // Preprocess
      final input = _imageToFloatList(resizedImage);

      // Run Inference
      final outputShape = _interpreter!.getOutputTensor(0).shape;
      final outputLength = outputShape[1];
      var output = List.generate(1, (_) => List.filled(outputLength, 0.0));
      _interpreter!.run(input, output);

      final embedding = List<double>.from(output[0]);

      return _l2Normalize(embedding);
    } catch (e) {
      debugPrint('Error generating embedding from RGB image: $e');
      return null;
    }
  }

  Future<List<double>?> getFaceEmbeddingFromFile(String imagePath) async {
    if (_interpreter == null) {
      debugPrint('Interpreter not initialized');
      return null;
    }

    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      if (_faceDetector == null) {
        debugPrint('Face detector not initialized');
        return null;
      }
      final faces = await _faceDetector!.processImage(inputImage);
      if (faces.isEmpty) {
        debugPrint('No face found in captured image');
        return null;
      }
      final face = faces.first;

      final bytes = await File(imagePath).readAsBytes();
      img.Image? fullImage = img.decodeImage(bytes);
      if (fullImage == null) {
        debugPrint('Failed to decode captured image');
        return null;
      }

      // Re-use the RGB embedding logic
      return await getEmbeddingFromRgbImage(fullImage, face.boundingBox);
    } catch (e) {
      debugPrint('Error generating embedding from file: $e');
      return null;
    }
  }

  bool _isValidCameraImage(CameraImage image) {
    if (image.planes.length < 3) return false;
    for (final plane in image.planes) {
      if (plane.bytes.isEmpty) return false;
    }
    final expectedYSize = image.width * image.height;
    if (image.planes[0].bytes.length < expectedYSize) return false;
    return true;
  }

  List<double> _l2Normalize(List<double> embedding) {
    double sum = 0;
    for (var x in embedding) {
      sum += x * x;
    }
    double norm = sqrt(sum);
    if (norm < 1e-10) return embedding;
    return embedding.map((x) => x / norm).toList();
  }

  List<List<List<List<double>>>> _imageToFloatList(img.Image image) {
    var input = List.generate(
      1,
      (i) => List.generate(
        112,
        (y) => List.generate(112, (x) => List.filled(3, 0.0)),
      ),
    );

    for (var y = 0; y < 112; y++) {
      for (var x = 0; x < 112; x++) {
        var pixel = image.getPixel(x, y);
        input[0][y][x][0] = (pixel.r - 128) / 128;
        input[0][y][x][1] = (pixel.g - 128) / 128;
        input[0][y][x][2] = (pixel.b - 128) / 128;
      }
    }
    return input;
  }
}
