import 'dart:typed_data';

import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';

import '../models/models.dart';

/// Wraps `google_mlkit_selfie_segmentation` in **single-image mode** to turn
/// a captured still into a person-confidence [BinaryMask].
///
/// The segmenter runs with `enableRawSizeMask: true`, so the returned mask
/// keeps the model's native resolution (typically 256x256) instead of being
/// rescaled to the input image. The raw mask is stretched over the whole
/// image, so its x/y scales differ — [SilhouetteFrame.maskScaleX] /
/// [SilhouetteFrame.maskScaleY] carry that mapping. Mask orientation matches
/// the EXIF-upright image, the same frame `PoseService.detectFromFile`
/// reports landmarks in.
class SegmentationService {
  final SelfieSegmenter _segmenter = SelfieSegmenter(
    mode: SegmenterMode.single,
    enableRawSizeMask: true,
  );
  bool _disposed = false;

  /// Segments the image file at [path].
  ///
  /// Returns a [BinaryMask] whose `confidences` (row-major, 0..1) give the
  /// probability of each mask pixel belonging to the person, or `null` when
  /// the file cannot be processed, the platform call fails, or the plugin
  /// returns a malformed mask.
  Future<BinaryMask?> maskFromFile(String path) async {
    if (_disposed) return null;
    SegmentationMask? mask;
    try {
      mask = await _segmenter.processImage(InputImage.fromFilePath(path));
    } catch (_) {
      return null;
    }
    if (mask == null) return null;
    if (mask.width <= 0 ||
        mask.height <= 0 ||
        mask.confidences.length < mask.width * mask.height) {
      return null;
    }
    return BinaryMask(
      width: mask.width,
      height: mask.height,
      confidences: Float32List.fromList(mask.confidences),
    );
  }

  /// Releases the native segmenter. Further calls return `null`.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _segmenter.close();
    } catch (_) {
      // Releasing on a platform without the plugin must not throw.
    }
  }
}
