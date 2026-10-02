import 'dart:async';

import 'package:flutter/foundation.dart';

import '../engine/quality.dart';
import '../engine/rotation_engine.dart';
import '../models/models.dart';
import '../services/tts_service.dart';

/// Stages of a guided 360° turn capture ("precision" mode).
enum TurnStage {
  /// Explains the setup; advances on user tap ([TurnCaptureController.confirmIntro]).
  intro,

  /// Live gating at the current stop until the subject is framed and still.
  positioning,

  /// A still is being captured at the current stop.
  capturing,

  /// Every stop captured; the rotation engine is running.
  processing,

  /// Finished successfully.
  done,

  /// Unrecoverable failure (message in [instruction]).
  failed,
}

/// Capture-flow logic + voice coaching for the guided-turn mode.
///
/// The subject turns in place in front of a propped phone, stopping at each
/// of [stops] evenly spaced clock positions. At every stop the controller
/// gates on [checkTurnPose] (framed, centered, upright) plus the tilt gate,
/// waits for a short stability window, captures one still, and advances —
/// speaking a turn prompt between stops. When all stops are captured it
/// hands the frames (each tagged with its instructed yaw) to
/// [onReadyToProcess].
///
/// The instructed yaw is only approximate — the subject never turns exactly
/// 30° — but [RotationMeasurementEngine] fits a phase offset that absorbs a
/// consistent start error, so instructed angles are the right input.
class TurnCaptureController extends ChangeNotifier {
  /// [tts] is borrowed, not owned.
  TurnCaptureController({
    required TtsService tts,
    this.stops = 12,
  })  : assert(stops >= 6, 'need at least 6 stops for an ellipse fit'),
        // The parameter name is borrowed-by-convention; the field is private.
        // ignore: prefer_initializing_formals
        _tts = tts;

  /// Number of evenly spaced stops around the full turn.
  final int stops;

  /// How long the subject must stay framed and still before the still is
  /// taken at each stop.
  static const Duration stabilityWindow = Duration(milliseconds: 1200);

  /// Phone pitch (degrees, absolute) above which capture is blocked.
  static const double maxPitchDegrees = 8.0;

  // --- UX copy -------------------------------------------------------------

  static const String _introInstruction =
      'Prop your phone upright at hip height, about 2 metres away, with your '
      'whole body in view. You will turn slowly all the way around, pausing '
      'when asked. Tap Start when you are ready.';
  static const String _firstStopPrompt =
      'Face the camera, arms slightly away from your body, and hold still.';
  static const String _holdStillPrompt = 'Hold still.';
  static const String _tiltPrompt = 'Stand the phone upright';
  static const String _capturingPrompt = 'Hold still — capturing.';
  static const String _processingPrompt =
      'All the way around. Calculating your measurements…';
  static const String _retryStopPrompt =
      "That didn't capture — hold still a moment longer.";

  final TtsService _tts;

  TurnStage _stage = TurnStage.intro;
  String _instruction = _introInstruction;
  PoseCheckResult? _lastCheck;
  int _currentStop = 0;
  final List<RotationFrame> _frames = [];
  DateTime? _stableSince;
  bool _disposed = false;

  /// Current stage of the turn.
  TurnStage get stage => _stage;

  /// Current on-screen instruction.
  String get instruction => _instruction;

  /// Most recent pose check (for overlay colouring); null before the first.
  PoseCheckResult? get lastCheck => _lastCheck;

  /// Zero-based index of the stop currently being captured.
  int get currentStop => _currentStop;

  /// Fraction of the turn completed so far, 0..1 (for a progress ring).
  double get progress => _currentStop / stops;

  /// Instructed yaw (degrees) of the current stop.
  double get currentAngleDegrees => _currentStop * 360 / stops;

  /// True while the controller is actively gating live pose checks.
  bool get isGating => _stage == TurnStage.positioning;

  /// Wire-up: the screen sets this; the controller calls it to capture one
  /// still at [angleDegrees] and the screen resolves with the frame, or null
  /// if that stop produced nothing usable.
  Future<RotationFrame?> Function(double angleDegrees)? stopCaptor;

  /// Called once every stop is captured; receives all turn frames.
  void Function(List<RotationFrame> frames)? onReadyToProcess;

  /// Begins (or restarts) the turn at the intro stage.
  void start() {
    _stableSince = null;
    _frames.clear();
    _currentStop = 0;
    _lastCheck = null;
    _stage = TurnStage.intro;
    _instruction = _introInstruction;
    unawaited(_tts.coach(_introInstruction));
    _notify();
  }

  /// User tapped through the intro: begin gating the first stop.
  void confirmIntro() {
    if (_stage != TurnStage.intro) return;
    _stage = TurnStage.positioning;
    _stableSince = null;
    _setInstruction(_firstStopPrompt, speak: true);
    _notify();
  }

  /// Feed live pose checks (same cadence as the two-view flow). Drives
  /// gating and, once the pose holds for [stabilityWindow], the capture at
  /// the current stop. [pitchDegrees] drives the tilt gate.
  void onPoseCheck(PoseCheckResult check, {double? pitchDegrees}) {
    if (_disposed || _stage != TurnStage.positioning) return;

    _lastCheck = check;
    final tiltBad =
        pitchDegrees != null && pitchDegrees.abs() > maxPitchDegrees;
    final ok = check.okNow && !tiltBad;

    if (!ok) {
      _stableSince = null;
      _setInstruction(_failureInstruction(check, tiltBad), speak: true);
      _notify();
      return;
    }

    _stableSince ??= DateTime.now();
    if (DateTime.now().difference(_stableSince!) >= stabilityWindow) {
      unawaited(_captureCurrentStop());
      return;
    }
    _setInstruction(_holdStillPrompt, speak: true);
    _notify();
  }

  /// Marks the session successfully finished (screen calls it after the
  /// engine returns).
  void markDone() {
    if (_disposed || _stage != TurnStage.processing) return;
    _stage = TurnStage.done;
    _notify();
  }

  /// Marks the session failed with a user-facing [message].
  void markFailed(String message) {
    if (_disposed) return;
    _stage = TurnStage.failed;
    _setInstruction(message, speak: true);
    _notify();
  }

  /// Returns to the intro stage, dropping all captured frames.
  void reset() {
    if (_disposed) return;
    start();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  // --- internals -----------------------------------------------------------

  Future<void> _captureCurrentStop() async {
    _stage = TurnStage.capturing;
    _stableSince = null;
    _setInstruction(_capturingPrompt, speak: true);
    _notify();

    final captor = stopCaptor;
    if (captor == null) {
      markFailed('Capture is not available. Please try again.');
      return;
    }

    RotationFrame? frame;
    try {
      frame = await captor(currentAngleDegrees);
    } catch (_) {
      frame = null;
    }
    if (_disposed) return;

    if (frame == null) {
      // This stop produced nothing usable: gate it again.
      _stage = TurnStage.positioning;
      _stableSince = null;
      _setInstruction(_retryStopPrompt, speak: true);
      _notify();
      return;
    }

    _frames.add(frame);
    _currentStop++;

    if (_currentStop >= stops) {
      _stage = TurnStage.processing;
      _setInstruction(_processingPrompt, speak: true);
      _notify();
      onReadyToProcess?.call(List.unmodifiable(_frames));
      return;
    }

    // Advance to the next stop with a turn prompt.
    _stage = TurnStage.positioning;
    _lastCheck = null;
    _setInstruction(_turnPrompt(), speak: true);
    _notify();
  }

  /// The spoken prompt that moves the subject to the next stop, with a
  /// quarter-turn milestone where it lands.
  String _turnPrompt() {
    final quarter = stops ~/ 4;
    if (quarter > 0 && _currentStop == quarter) {
      return 'Quarter of the way. Keep turning a little to your right.';
    }
    if (quarter > 0 && _currentStop == quarter * 2) {
      return 'Halfway around. Turn a little more.';
    }
    if (quarter > 0 && _currentStop == quarter * 3) {
      return 'Almost there. Keep turning.';
    }
    return 'Turn a little to your right and hold still.';
  }

  String _failureInstruction(PoseCheckResult check, bool tiltBad) {
    if (tiltBad) return _tiltPrompt;
    if (check.issues.isEmpty) return _holdStillPrompt;
    // Turn mode has no "facing"/"sideways" rule, so the generic front copy
    // for framing issues reads correctly here.
    return instructionFor(check.issues.first, CaptureView.front);
  }

  void _setInstruction(String text, {required bool speak}) {
    if (text == _instruction) return;
    _instruction = text;
    if (speak) unawaited(_tts.coach(text));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
