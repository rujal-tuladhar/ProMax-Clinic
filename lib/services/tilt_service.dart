import 'dart:async';
import 'dart:math' as math;

import 'package:sensors_plus/sensors_plus.dart';

/// Accelerometer-based phone pitch for the "prop the phone upright" gate.
///
/// Convention (portrait-upright phone, screen facing the subject):
/// * `0°` — phone perfectly upright.
/// * Positive — leaning back (top of the phone tipping away from the
///   subject, screen starting to face the sky).
/// * Negative — leaning forward.
///
/// Computed as `atan2(z, y)` over the gravity components reported by the
/// accelerometer: upright the reaction to gravity sits on +y, and tilting
/// back moves it onto +z (out of the screen).
class TiltService {
  final StreamController<double> _controller =
      StreamController<double>.broadcast();
  StreamSubscription<AccelerometerEvent>? _subscription;
  double? _latestPitch;
  DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

  /// Requested sampling period (~10 Hz). The platform treats it as a hint,
  /// so [_minEmitInterval] additionally rate-limits emissions.
  static const Duration _samplingPeriod = Duration(milliseconds: 100);
  static const Duration _minEmitInterval = Duration(milliseconds: 90);

  /// Starts listening to the accelerometer. Idempotent; silently a no-op on
  /// devices without an accelerometer.
  void start() {
    if (_subscription != null) return;
    try {
      _subscription =
          accelerometerEventStream(samplingPeriod: _samplingPeriod).listen(
        (event) {
          final pitch =
              math.atan2(event.z, event.y) * 180 / math.pi;
          _latestPitch = pitch;
          final now = DateTime.now();
          if (now.difference(_lastEmit) < _minEmitInterval) return;
          _lastEmit = now;
          if (!_controller.isClosed) _controller.add(pitch);
        },
        onError: (Object _) {
          // Sensor unavailable: keep the stream open but silent.
        },
        cancelOnError: false,
      );
    } catch (_) {
      _subscription = null; // No sensor plugin on this platform: stay silent.
    }
  }

  /// Stops listening. The [pitchDegrees] stream stays usable; [start] may be
  /// called again.
  void stop() {
    _subscription?.cancel();
    _subscription = null;
  }

  /// Broadcast stream of pitch in degrees, emitted at roughly 10 Hz while
  /// started.
  Stream<double> get pitchDegrees => _controller.stream;

  /// Most recent pitch in degrees, or `null` before the first sample.
  double? get latestPitch => _latestPitch;
}
