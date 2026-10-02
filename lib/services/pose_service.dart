import 'dart:io';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import '../models/models.dart';

/// Wraps `google_mlkit_pose_detection`. Stream mode for live gating,
/// single-image mode for captured stills.
///
/// ## Coordinate frame of the returned poses
///
/// Both [detectFromCameraImage] and [detectFromFile] return landmarks in
/// **upright image pixel coordinates**: x grows rightwards, y grows
/// downwards, origin at the top-left of the image *as a viewer would see it
/// standing behind the phone* (gravity pointing down the +y axis). The
/// returned `width`/`height` are the dimensions of that upright image, so a
/// landmark always satisfies `0 <= x <= width`, `0 <= y <= height`.
///
/// How that comes about per platform (verified against the installed
/// `google_mlkit_commons` 0.13.0 README and the `camera` platform sources):
///
/// * **Android** — the camera plugin streams single-plane NV21 buffers in the
///   sensor's native (usually landscape) orientation. We compute the rotation
///   with the standard ML Kit formula from `sensorOrientation`, the current
///   [DeviceOrientation] and the lens direction, and pass it as
///   [InputImageMetadata.rotation]. ML Kit rotates the buffer natively and
///   returns landmark coordinates **already in the rotated (upright) frame**,
///   so no coordinate remap is needed here — but the upright width/height are
///   the buffer's height/width when the rotation is 90°/270°, and we report
///   those swapped dimensions.
/// * **iOS** — the camera plugin sets `AVCaptureConnection.videoOrientation`
///   from the device orientation, so BGRA8888 stream buffers arrive already
///   physically upright; ML Kit ignores the rotation metadata on iOS and
///   returns coordinates in the buffer's own (upright) frame. Width/height
///   are passed through unchanged.
///
/// ## Front-camera mirroring
///
/// Neither platform mirrors the stream buffers for front cameras, so the
/// returned coordinates are **unmirrored**: they match the content of a
/// photo taken by `takePicture`, not the (usually mirrored) on-screen
/// preview. Overlay painters that draw on a mirrored front-camera preview
/// must flip x themselves (`previewX = width - x`). Landmark left/right
/// labels are the subject's anatomical left/right as reported by ML Kit.
class PoseService {
  /// [streamMode] selects the detector configuration:
  /// * `true` (default) — fast base model in stream mode, for live gating
  ///   via [detectFromCameraImage].
  /// * `false` — accurate model in single-image mode, for captured stills
  ///   via [detectFromFile].
  PoseService({bool streamMode = true})
      : _detector = PoseDetector(
          options: PoseDetectorOptions(
            model: streamMode
                ? PoseDetectionModel.base
                : PoseDetectionModel.accurate,
            mode: streamMode
                ? PoseDetectionMode.stream
                : PoseDetectionMode.single,
          ),
        );

  final PoseDetector _detector;
  bool _disposed = false;

  /// Standard ML Kit rotation-compensation table (degrees the UI is rotated
  /// from the device's natural portrait orientation).
  static const Map<DeviceOrientation, int> _orientationDegrees = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  /// ML Kit landmark types -> the 17 landmarks the engine consumes.
  static const Map<PoseLandmarkType, Landmark> _landmarkMap = {
    PoseLandmarkType.nose: Landmark.nose,
    PoseLandmarkType.leftEye: Landmark.leftEye,
    PoseLandmarkType.rightEye: Landmark.rightEye,
    PoseLandmarkType.leftEar: Landmark.leftEar,
    PoseLandmarkType.rightEar: Landmark.rightEar,
    PoseLandmarkType.leftShoulder: Landmark.leftShoulder,
    PoseLandmarkType.rightShoulder: Landmark.rightShoulder,
    PoseLandmarkType.leftElbow: Landmark.leftElbow,
    PoseLandmarkType.rightElbow: Landmark.rightElbow,
    PoseLandmarkType.leftWrist: Landmark.leftWrist,
    PoseLandmarkType.rightWrist: Landmark.rightWrist,
    PoseLandmarkType.leftHip: Landmark.leftHip,
    PoseLandmarkType.rightHip: Landmark.rightHip,
    PoseLandmarkType.leftKnee: Landmark.leftKnee,
    PoseLandmarkType.rightKnee: Landmark.rightKnee,
    PoseLandmarkType.leftAnkle: Landmark.leftAnkle,
    PoseLandmarkType.rightAnkle: Landmark.rightAnkle,
  };

  /// Detect on a live [CameraImage]. Returns the pose in **upright image
  /// coordinates** together with the upright image size (see class docs),
  /// or `null` when the frame cannot be converted, no person is detected,
  /// or the detector fails.
  ///
  /// The camera stream must be configured with `ImageFormatGroup.nv21` on
  /// Android and `ImageFormatGroup.bgra8888` on iOS (single-plane buffers);
  /// any other format is rejected with `null`.
  Future<(BodyPose, int width, int height)?> detectFromCameraImage(
    CameraImage image,
    CameraDescription description,
    DeviceOrientation deviceOrientation,
  ) async {
    if (_disposed) return null;

    // --- rotation (standard ML Kit formula from the commons README) ---
    final sensorOrientation = description.sensorOrientation;
    InputImageRotation? rotation;
    if (Platform.isIOS) {
      // Not used natively on iOS (buffers are delivered upright), but kept
      // for metadata completeness.
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    } else if (Platform.isAndroid) {
      var rotationCompensation = _orientationDegrees[deviceOrientation];
      if (rotationCompensation == null) return null;
      if (description.lensDirection == CameraLensDirection.front) {
        rotationCompensation =
            (sensorOrientation + rotationCompensation) % 360;
      } else {
        rotationCompensation =
            (sensorOrientation - rotationCompensation + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
    }
    if (rotation == null) return null;

    // --- format validation: NV21 (Android) / BGRA8888 (iOS), one plane ---
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null ||
        (Platform.isAndroid && format != InputImageFormat.nv21) ||
        (Platform.isIOS && format != InputImageFormat.bgra8888)) {
      return null;
    }
    if (image.planes.length != 1) return null;
    final plane = image.planes.first;

    final inputImage = InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: ui.Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation, // used only on Android
        format: format, // used only on iOS
        bytesPerRow: plane.bytesPerRow, // used only on iOS
      ),
    );

    final pose = await _detect(inputImage);
    if (pose == null) return null;

    // Upright dimensions. On Android ML Kit rotates the buffer natively, so
    // with a 90°/270° rotation the upright image has swapped dimensions and
    // the landmarks are already expressed in that swapped frame. On iOS the
    // buffer is already upright.
    final bool swapped = Platform.isAndroid &&
        (rotation == InputImageRotation.rotation90deg ||
            rotation == InputImageRotation.rotation270deg);
    final int width = swapped ? image.height : image.width;
    final int height = swapped ? image.width : image.height;
    return (pose, width, height);
  }

  /// Detect on an image file (e.g. a `takePicture` still). Both platforms
  /// apply the file's EXIF orientation before detection, so the returned
  /// pose and `width`/`height` describe the upright image — the same frame
  /// `dart:ui` decodes the file into.
  ///
  /// Returns `null` when the file cannot be decoded or no person is found.
  Future<(BodyPose, int width, int height)?> detectFromFile(
      String path) async {
    if (_disposed) return null;
    final pose = await _detect(InputImage.fromFilePath(path));
    if (pose == null) return null;
    final size = await _uprightImageSize(path);
    if (size == null) return null;
    return (pose, size.$1, size.$2);
  }

  /// Releases the native detector. Further calls return `null`.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _detector.close();
    } catch (_) {
      // Releasing a detector on a platform without the plugin must not throw.
    }
  }

  /// Runs the detector and converts the first detected pose; `null` when no
  /// person is found or the platform call fails.
  Future<BodyPose?> _detect(InputImage inputImage) async {
    List<Pose> poses;
    try {
      poses = await _detector.processImage(inputImage);
    } catch (_) {
      return null;
    }
    if (poses.isEmpty) return null;
    final landmarks = poses.first.landmarks;
    final points = <Landmark, PosePoint>{};
    for (final entry in _landmarkMap.entries) {
      final lm = landmarks[entry.key];
      if (lm == null) continue;
      points[entry.value] =
          PosePoint(lm.x, lm.y, z: lm.z, likelihood: lm.likelihood);
    }
    if (points.isEmpty) return null;
    return BodyPose(points);
  }

  /// Decodes the image far enough to learn its EXIF-upright dimensions.
  Future<(int, int)?> _uprightImageSize(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      // Full decode: Flutter's codec applies EXIF orientation, so width and
      // height match the upright frame ML Kit reported coordinates in.
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final frame = await codec.getNextFrame();
        final width = frame.image.width;
        final height = frame.image.height;
        frame.image.dispose();
        return (width, height);
      } finally {
        codec.dispose();
      }
    } catch (_) {
      return null;
    }
  }
}
