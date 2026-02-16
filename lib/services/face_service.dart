import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
// To re-enable anti-spoofing model, uncomment:
// import 'package:face_anti_spoofing_detector/face_anti_spoofing_detector.dart';
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
  Uint8List? _modelBytes;
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

      // To re-enable the anti-spoofing model, uncomment:
      // await FaceAntiSpoofingDetector.initialize();
      try {
        // Pre-load model bytes so they can be passed to isolates later.
        // rootBundle.load only works on the main thread.
        final rawAsset = await rootBundle.load('assets/mobilefacenet.tflite');
        _modelBytes = rawAsset.buffer.asUint8List();

        final options = InterpreterOptions();
        _interpreter = Interpreter.fromBuffer(_modelBytes!, options: options);
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
    // To re-enable the anti-spoofing model, uncomment:
    // FaceAntiSpoofingDetector.destroy();
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

      return {
        'face': face,
        'leftEyeOpen': face.leftEyeOpenProbability,
        'rightEyeOpen': face.rightEyeOpenProbability,
        'error': null,
      };
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

      // 1. Prepare data for Isolate
      final imageData = CameraImageData.fromCameraImage(cameraImage, rotation);
      final rootIsolateToken = RootIsolateToken.instance;
      if (rootIsolateToken == null) {
        debugPrint('Could not get RootIsolateToken');
        return null; // Should fall back or handle error
      }

      final inferenceData = _InferenceData(
        cameraData: imageData,
        faceBox: face.boundingBox,
        token: rootIsolateToken,
        modelBytes: _modelBytes!,
      );

      // 2. Offload everything to background isolate
      return await compute(_inferenceIsolate, inferenceData);
    } catch (e) {
      debugPrint('Error generating embedding: $e');
      return null;
    }
  }

  Future<List<double>?> getFaceEmbeddingFromFile(String imagePath) async {
    // Note: We don't check _interpreter here because the isolate will create its own instance.
    // However, we do need the FaceDetector for the initial detection on main thread.

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

      // 1. Prepare data for Isolate
      final rootIsolateToken = RootIsolateToken.instance;
      if (rootIsolateToken == null) {
        debugPrint('Could not get RootIsolateToken');
        return null;
      }

      final inferenceData = _InferenceData(
        imagePath: imagePath,
        faceBox: face.boundingBox,
        token: rootIsolateToken,
        modelBytes: _modelBytes!,
      );

      // 2. Offload heavy work (Decode -> Crop -> Resize -> Inference) to background isolate
      return await compute(_inferenceIsolate, inferenceData);
    } catch (e) {
      debugPrint('Error generating embedding from file: $e');
      return null;
    }
  }

  // ... (keep _isValidCameraImage and other helpers)
}

// --- Isolate Data & Logic ---

class _InferenceData {
  final CameraImageData? cameraData;
  final String? imagePath;
  final Rect faceBox;
  final RootIsolateToken token;
  final Uint8List modelBytes;

  _InferenceData({
    this.cameraData,
    this.imagePath,
    required this.faceBox,
    required this.token,
    required this.modelBytes,
  });
}

/// Isolate function: Load/Convert Image -> Crop -> Resize -> MobileFaceNet Inference
Future<List<double>?> _inferenceIsolate(_InferenceData data) async {
  try {
    img.Image? fullImage;

    // 1. Get Image Source
    if (data.imagePath != null) {
      // Read & Decode Image (Heavy I/O + CPU)
      final bytes = await File(data.imagePath!).readAsBytes();
      fullImage = img.decodeImage(bytes);
    } else if (data.cameraData != null) {
      // Convert YUV to RGB (CPU)
      // Note: We are already in an isolate here, so we call the function directly.
      fullImage = convertYuvToRgbIsolate(data.cameraData!);
    }

    if (fullImage == null) return null;

    // 3. Crop Face
    final box = data.faceBox;
    int left = max(0, box.left.toInt());
    int top = max(0, box.top.toInt());
    int right = min(fullImage.width, box.right.toInt());
    int bottom = min(fullImage.height, box.bottom.toInt());
    int width = right - left;
    int height = bottom - top;

    if (width <= 0 || height <= 0) return null;

    img.Image croppedImage = img.copyCrop(
      fullImage,
      x: left,
      y: top,
      width: width,
      height: height,
    );

    // 4. Resize to 112x112 (Heavy CPU)
    img.Image resizedImage = img.copyResize(
      croppedImage,
      width: 112,
      height: 112,
    );

    // 5. Preprocess (Normalize)
    // We duplicate _imageToFloatList here to avoid static access issues or move it to top-level
    var input = List.generate(
      1,
      (i) => List.generate(
        112,
        (y) => List.generate(112, (x) => List.filled(3, 0.0)),
      ),
    );

    for (var y = 0; y < 112; y++) {
      for (var x = 0; x < 112; x++) {
        var pixel = resizedImage.getPixel(x, y);
        input[0][y][x][0] = (pixel.r - 128) / 128; // R
        input[0][y][x][1] = (pixel.g - 128) / 128; // G
        input[0][y][x][2] = (pixel.b - 128) / 128; // B
      }
    }

    // 6. Load Model & Run Inference
    // Use fromBuffer with pre-loaded bytes (rootBundle.load doesn't work in isolates).
    final options = InterpreterOptions();
    final interpreter = Interpreter.fromBuffer(
      data.modelBytes,
      options: options,
    );

    final outputShape = interpreter.getOutputTensor(0).shape;
    final outputLength = outputShape[1];
    var output = List.generate(1, (_) => List.filled(outputLength, 0.0));

    interpreter.run(input, output);
    interpreter.close();

    final embedding = List<double>.from(output[0]);

    // 7. L2 Normalize
    double sum = 0;
    for (var x in embedding) {
      sum += x * x;
    }
    double norm = sqrt(sum);
    if (norm < 1e-10) return embedding;
    return embedding.map((x) => x / norm).toList();
  } catch (e) {
    debugPrint("Isolate Inference Error: $e");
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
