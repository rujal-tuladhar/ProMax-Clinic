import 'dart:math' as math;
import 'dart:typed_data';

/// Core data models shared by the measurement engine, services and UI.
/// This file is the contract between modules — do not change public
/// signatures without updating docs/CONTRACTS.md.

enum Sex { male, female, other }

enum UnitSystem { metric, imperial }

/// The body parts FitSize measures.
///
/// The first three (the torso circumferences) are measured directly from
/// silhouette widths; the rest were added in v2: lengths from pose
/// landmarks / the silhouette, plus regression-derived circumferences.
enum BodyPart {
  chest,
  waist,
  hip,
  neck,
  shoulder,
  sleeve,
  shirtSleeve,
  inseam,
  thigh,
}

/// Whether a part is a girth (tape wrapped around) or a straight length.
enum MeasurementKind { circumference, length }

extension BodyPartLabel on BodyPart {
  String get label => switch (this) {
        BodyPart.chest => 'Chest',
        BodyPart.waist => 'Waist',
        BodyPart.hip => 'Hip',
        BodyPart.neck => 'Neck',
        BodyPart.shoulder => 'Shoulder width',
        BodyPart.sleeve => 'Sleeve (shoulder to wrist)',
        BodyPart.shirtSleeve => 'Shirt sleeve (centre back to wrist)',
        BodyPart.inseam => 'Inseam',
        BodyPart.thigh => 'Thigh',
      };

  /// chest/waist/hip/neck/thigh are circumferences; the rest are lengths.
  MeasurementKind get kind => switch (this) {
        BodyPart.chest ||
        BodyPart.waist ||
        BodyPart.hip ||
        BodyPart.neck ||
        BodyPart.thigh =>
          MeasurementKind.circumference,
        BodyPart.shoulder ||
        BodyPart.sleeve ||
        BodyPart.shirtSleeve ||
        BodyPart.inseam =>
          MeasurementKind.length,
      };

  bool get isCircumference => kind == MeasurementKind.circumference;
}

/// Parts measured directly from silhouette widths (front + side / turn).
const List<BodyPart> kTorsoParts = [
  BodyPart.chest,
  BodyPart.waist,
  BodyPart.hip,
];

/// Which capture view a frame belongs to.
enum CaptureView { front, side }

/// How the shopper likes clothes to sit. Only biases the size lookup when a
/// measurement is close to a chart boundary (see `SizeRecommender`); it never
/// changes the measurements themselves.
enum FitPreference { slim, regular, relaxed }

extension FitPreferenceLabel on FitPreference {
  String get label => switch (this) {
        FitPreference.slim => 'Slim',
        FitPreference.regular => 'Regular',
        FitPreference.relaxed => 'Relaxed',
      };
}

class UserProfile {
  /// Standing height without shoes, in centimetres. The single scale
  /// reference for every measurement, so it must be accurate.
  final double heightCm;
  final Sex sex;
  final UnitSystem units;

  /// Preferred fit, used to bias size suggestions near chart boundaries.
  /// Optional; profiles saved before this field existed read as regular.
  final FitPreference fit;

  /// Tap-to-correct calibration: tape value minus app value, per part (cm).
  /// Added to every future measurement of that part. Optional; profiles
  /// saved before this field existed read as empty.
  final Map<BodyPart, double> offsetsCm;

  const UserProfile({
    required this.heightCm,
    required this.sex,
    this.units = UnitSystem.metric,
    this.fit = FitPreference.regular,
    this.offsetsCm = const {},
  });

  /// Copy with the given fields replaced.
  UserProfile copyWith({
    double? heightCm,
    Sex? sex,
    UnitSystem? units,
    FitPreference? fit,
    Map<BodyPart, double>? offsetsCm,
  }) =>
      UserProfile(
        heightCm: heightCm ?? this.heightCm,
        sex: sex ?? this.sex,
        units: units ?? this.units,
        fit: fit ?? this.fit,
        offsetsCm: offsetsCm ?? this.offsetsCm,
      );

  Map<String, dynamic> toJson() => {
        'heightCm': heightCm,
        'sex': sex.name,
        'units': units.name,
        'fit': fit.name,
        'offsetsCm': {
          for (final e in offsetsCm.entries) e.key.name: e.value,
        },
      };

  static UserProfile? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final height = (json['heightCm'] as num?)?.toDouble();
    if (height == null) return null;
    return UserProfile(
      heightCm: height,
      sex: Sex.values.asNameMap()[json['sex']] ?? Sex.other,
      units: UnitSystem.values.asNameMap()[json['units']] ?? UnitSystem.metric,
      fit: FitPreference.values.asNameMap()[json['fit']] ??
          FitPreference.regular,
      offsetsCm: _offsetsFromJson(json['offsetsCm']),
    );
  }

  /// Parses `{partName: cm}`; unknown parts and non-numeric values are
  /// skipped, anything that is not a map reads as no offsets.
  static Map<BodyPart, double> _offsetsFromJson(Object? raw) {
    if (raw is! Map) return const {};
    final names = BodyPart.values.asNameMap();
    final out = <BodyPart, double>{};
    for (final entry in raw.entries) {
      final part = names[entry.key];
      final value = entry.value;
      if (part == null || value is! num) continue;
      final cm = value.toDouble();
      if (!cm.isFinite) continue;
      out[part] = cm;
    }
    return out;
  }
}

/// Pose landmarks the engine consumes. Mirrors the ML Kit / BlazePose
/// landmark set we rely on; services translate plugin types into these.
enum Landmark {
  nose,
  leftEye,
  rightEye,
  leftEar,
  rightEar,
  leftShoulder,
  rightShoulder,
  leftElbow,
  rightElbow,
  leftWrist,
  rightWrist,
  leftHip,
  rightHip,
  leftKnee,
  rightKnee,
  leftAnkle,
  rightAnkle,
}

/// A single pose landmark in ORIGINAL IMAGE pixel coordinates.
class PosePoint {
  final double x;
  final double y;

  /// Relative depth (ML Kit z, roughly hip-centred, same scale as x).
  final double z;

  /// In-frame likelihood 0..1.
  final double likelihood;

  const PosePoint(this.x, this.y, {this.z = 0, this.likelihood = 1});
}

/// A detected body pose: landmark -> point, in image pixel coordinates.
class BodyPose {
  final Map<Landmark, PosePoint> points;

  const BodyPose(this.points);

  PosePoint? operator [](Landmark l) => points[l];

  /// Midpoint of two landmarks, or null if either is missing.
  PosePoint? mid(Landmark a, Landmark b) {
    final pa = points[a], pb = points[b];
    if (pa == null || pb == null) return null;
    return PosePoint(
      (pa.x + pb.x) / 2,
      (pa.y + pb.y) / 2,
      z: (pa.z + pb.z) / 2,
      likelihood: math.min(pa.likelihood, pb.likelihood),
    );
  }

  /// Lowest likelihood among the given landmarks (0 when one is missing).
  double minLikelihood(Iterable<Landmark> ls) {
    var m = 1.0;
    for (final l in ls) {
      final p = points[l];
      if (p == null) return 0;
      m = math.min(m, p.likelihood);
    }
    return m;
  }
}

/// A person-segmentation confidence mask. Usually lower resolution than
/// the source image; [SilhouetteFrame] carries the scale between them.
class BinaryMask {
  final int width;
  final int height;

  /// Row-major confidences, length == width * height, each 0..1.
  final Float32List confidences;

  const BinaryMask({
    required this.width,
    required this.height,
    required this.confidences,
  });

  double at(int x, int y) {
    if (x < 0 || y < 0 || x >= width || y >= height) return 0;
    return confidences[y * width + x];
  }
}

/// One captured still: segmentation mask + pose + source image dimensions.
/// Pose coordinates are in source-image pixels; the mask has its own
/// resolution. Use [maskX]/[maskY] to project pose points onto the mask.
class SilhouetteFrame {
  final BinaryMask mask;
  final BodyPose pose;
  final int imageWidth;
  final int imageHeight;
  final CaptureView view;

  const SilhouetteFrame({
    required this.mask,
    required this.pose,
    required this.imageWidth,
    required this.imageHeight,
    required this.view,
  });

  double get maskScaleX => mask.width / imageWidth;
  double get maskScaleY => mask.height / imageHeight;

  /// Project an image-space x/y into mask space.
  double maskX(double imageX) => imageX * maskScaleX;
  double maskY(double imageY) => imageY * maskScaleY;
}

/// One measured body part with uncertainty.
class PartMeasurement {
  final BodyPart part;
  final double valueCm;

  /// Spread across frames (cm); lower is better.
  final double stdDevCm;

  /// 0..1 quality score (frame agreement, landmark confidence).
  final double confidence;

  /// True when estimated from other measurements by regression (neck from
  /// chest, thigh from hip, shirt sleeve from shoulder + sleeve) rather
  /// than measured from the frames directly.
  final bool derived;

  const PartMeasurement({
    required this.part,
    required this.valueCm,
    required this.stdDevCm,
    required this.confidence,
    this.derived = false,
  });

  Map<String, dynamic> toJson() => {
        'part': part.name,
        'valueCm': valueCm,
        'stdDevCm': stdDevCm,
        'confidence': confidence,
        'derived': derived,
      };

  static PartMeasurement fromJson(Map<String, dynamic> json) =>
      PartMeasurement(
        part: BodyPart.values.asNameMap()[json['part']] ?? BodyPart.waist,
        valueCm: (json['valueCm'] as num).toDouble(),
        stdDevCm: (json['stdDevCm'] as num?)?.toDouble() ?? 0,
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
        derived: json['derived'] as bool? ?? false,
      );
}

/// Full result of one measurement session.
class MeasurementResult {
  final List<PartMeasurement> parts;

  /// cm-per-pixel scale used (median across frames), for diagnostics.
  final double scaleCmPerPx;
  final int frontFrameCount;
  final int sideFrameCount;
  final DateTime timestamp;

  const MeasurementResult({
    required this.parts,
    required this.scaleCmPerPx,
    required this.frontFrameCount,
    required this.sideFrameCount,
    required this.timestamp,
  });

  PartMeasurement? partFor(BodyPart p) {
    for (final m in parts) {
      if (m.part == p) return m;
    }
    return null;
  }

  double? valueFor(BodyPart p) => partFor(p)?.valueCm;

  Map<String, dynamic> toJson() => {
        'parts': parts.map((p) => p.toJson()).toList(),
        'scaleCmPerPx': scaleCmPerPx,
        'frontFrameCount': frontFrameCount,
        'sideFrameCount': sideFrameCount,
        'timestamp': timestamp.toIso8601String(),
      };

  static MeasurementResult fromJson(Map<String, dynamic> json) =>
      MeasurementResult(
        parts: (json['parts'] as List)
            .map((e) => PartMeasurement.fromJson(e as Map<String, dynamic>))
            .toList(),
        scaleCmPerPx: (json['scaleCmPerPx'] as num?)?.toDouble() ?? 0,
        frontFrameCount: (json['frontFrameCount'] as num?)?.toInt() ?? 0,
        sideFrameCount: (json['sideFrameCount'] as num?)?.toInt() ?? 0,
        timestamp:
            DateTime.tryParse(json['timestamp'] as String? ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
      );
}

/// Unit helpers.
double cmToInches(double cm) => cm / 2.54;

String formatLength(double cm, UnitSystem units) {
  if (units == UnitSystem.metric) return '${cm.toStringAsFixed(1)} cm';
  return '${cmToInches(cm).toStringAsFixed(1)} in';
}
