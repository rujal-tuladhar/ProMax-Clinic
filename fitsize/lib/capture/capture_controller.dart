import 'dart:async';

import 'package:flutter/foundation.dart';

import '../engine/quality.dart';
import '../models/models.dart';
import '../services/tts_service.dart';

/// The stages of one guided measurement session.
enum CaptureStage {
  /// Explains the setup; advances on user tap ([CaptureController.confirmIntro]).
  intro,

  /// Live gating until the FRONT pose is OK for ~1.5 s continuously.
  positioningFront,

  /// Spoken 3..2..1 before the front burst.
  countdownFront,

  /// Front burst in progress.
  capturingFront,

  /// Live gating for the SIDE pose.
  positioningSide,

  /// Spoken 3..2..1 before the side burst.
  countdownSide,

  /// Side burst in progress.
  capturingSide,

  /// Both bursts done; the measurement engine is running.
  processing,

  /// Measurement finished successfully.
  done,

  /// Something went unrecoverably wrong (see [instruction] for the message).
  failed,
}

/// Pure capture-flow logic + TTS coaching.
///
/// The camera screen feeds it live pose-check results via [onPoseCheck] and
/// executes capture bursts when asked (via [burstCaptor]). The controller
/// decides when the pose has been stable long enough (>= 1.5 s), runs the
/// spoken countdown, aborts it when the pose breaks, sequences front -> side
/// -> processing, and speaks every instruction change through
/// [TtsService.coach].
///
/// It is a [ChangeNotifier] so the UI can rebuild on any state change.
class CaptureController extends ChangeNotifier {
  /// [tts] is borrowed, not owned: the controller never disposes it.
  CaptureController({required TtsService tts, this.framesPerBurst = 5})
      // The parameter name is pinned by the contract; the field stays private.
      // ignore: prefer_initializing_formals
      : _tts = tts;

  /// How many stills each burst captures.
  final int framesPerBurst;

  /// How long the pose must stay continuously OK before the countdown starts.
  static const Duration stabilityWindow = Duration(milliseconds: 1500);

  /// Phone pitch (degrees, absolute) above which capture is blocked.
  static const double maxPitchDegrees = 8.0;

  // --- UX copy -------------------------------------------------------------

  static const String _introInstruction =
      'Prop your phone upright at hip height, 2–3 metres away, and wear '
      'tight clothing. Stand with your feet a little apart. Tap Start when '
      'you are ready.';

  /// Feet a little apart: the inseam is measured from the gap between the
  /// legs, so the front gate rejects a closed stance ([PoseIssue.feetTogether]).
  static const String _frontPrompt =
      'Face the camera, stand tall with your feet a little apart, and raise '
      'your arms away from your body.';
  static const String _sidePrompt =
      'Great. Now turn to your left and raise your arms forward.';
  static const String _holdStillPrompt = 'Perfect. Hold that pose.';

  /// Spoken right before the countdown. WHO protocol measures the waist at
  /// the end of a normal expiration — also the stillest moment of the breath
  /// cycle, so the burst lands on the least-moving, most comparable frame.
  static const String _exhalePrompt = 'Breathe out gently and hold still.';
  static const String _tiltPrompt = 'Stand the phone upright';
  static const String _capturingPrompt = 'Hold still — capturing.';
  static const String _processingPrompt =
      'All done. Calculating your measurements…';
  static const String _retryPrompt = "That didn't work — let's try again.";

  final TtsService _tts;

  CaptureStage _stage = CaptureStage.intro;
  String _instruction = _introInstruction;
  PoseCheckResult? _lastCheck;
  int _countdownValue = 3;

  DateTime? _stableSince;
  Timer? _countdownTimer;
  List<SilhouetteFrame> _frontFrames = const [];
  bool _disposed = false;

  /// Current stage of the capture flow.
  CaptureStage get stage => _stage;

  /// Current on-screen instruction text.
  String get instruction => _instruction;

  /// Most recent pose check, for overlay colouring. Null before the first
  /// check of the current session.
  PoseCheckResult? get lastCheck => _lastCheck;

  /// 3..1 during the countdown stages; meaningless otherwise.
  int get countdownValue => _countdownValue;

  /// The view currently being gated, or null when the controller is not in a
  /// positioning/countdown stage (so the screen can skip live detection).
  CaptureView? get gatingView => switch (_stage) {
        CaptureStage.positioningFront ||
        CaptureStage.countdownFront =>
          CaptureView.front,
        CaptureStage.positioningSide ||
        CaptureStage.countdownSide =>
          CaptureView.side,
        _ => null,
      };

  /// The view the current stage is about (for the guide overlay); front for
  /// everything up to and including the front burst, side afterwards.
  CaptureView get displayView => switch (_stage) {
        CaptureStage.intro ||
        CaptureStage.positioningFront ||
        CaptureStage.countdownFront ||
        CaptureStage.capturingFront =>
          CaptureView.front,
        _ => CaptureView.side,
      };

  /// Wire-up: the screen sets this; the controller calls it to run a burst
  /// and the screen resolves with the captured frames for the given view.
  Future<List<SilhouetteFrame>> Function(CaptureView view)? burstCaptor;

  /// Called once both bursts are done; receives the front and side frames.
  void Function(List<SilhouetteFrame> front, List<SilhouetteFrame> side)?
      onReadyToProcess;

  /// Begins (or restarts) the flow at the intro stage and speaks the setup
  /// instructions. [confirmIntro] then advances to [CaptureStage.positioningFront].
  void start() {
    _cancelCountdown();
    _stableSince = null;
    _frontFrames = const [];
    _lastCheck = null;
    _countdownValue = 3;
    _stage = CaptureStage.intro;
    // Speak unconditionally: on the very first start the instruction field
    // already holds the intro text, so _setInstruction would stay silent.
    _instruction = _introInstruction;
    unawaited(_tts.coach(_introInstruction));
    _notify();
  }

  /// User tapped through the intro: advance to front positioning.
  void confirmIntro() {
    if (_stage != CaptureStage.intro) return;
    _stage = CaptureStage.positioningFront;
    _stableSince = null;
    _setInstruction(_frontPrompt, speak: true);
    _notify();
  }

  /// Feed ~5–15 Hz live pose checks; drives gating, coaching and countdown.
  ///
  /// The pose must stay OK for >= [stabilityWindow] before the countdown
  /// starts; a failing check during the countdown aborts back to positioning.
  /// Tilt gate: when [pitchDegrees] is provided and |pitch| > 8°, capture is
  /// blocked with the instruction "Stand the phone upright" regardless of
  /// the pose check.
  void onPoseCheck(PoseCheckResult check, CaptureView view,
      {double? pitchDegrees}) {
    if (_disposed) return;
    final gating = gatingView;
    if (gating == null || gating != view) return; // stale/out-of-stage frame

    _lastCheck = check;
    final tiltBad =
        pitchDegrees != null && pitchDegrees.abs() > maxPitchDegrees;
    final ok = check.okNow && !tiltBad;

    if (_stage == CaptureStage.countdownFront ||
        _stage == CaptureStage.countdownSide) {
      if (!ok) {
        _abortCountdown(view, check: check, tiltBad: tiltBad);
      } else {
        _notify(); // keep the overlay colour fresh
      }
      return;
    }

    // Positioning stage.
    if (!ok) {
      _stableSince = null;
      _setInstruction(_failureInstruction(check, view, tiltBad), speak: true);
      _notify();
      return;
    }

    _stableSince ??= DateTime.now();
    if (DateTime.now().difference(_stableSince!) >= stabilityWindow) {
      _beginCountdown(view);
      return;
    }
    _setInstruction(_holdStillPrompt, speak: true);
    _notify();
  }

  /// Marks the session successfully finished (called by the screen after the
  /// measurement engine returns).
  void markDone() {
    if (_disposed || _stage != CaptureStage.processing) return;
    _stage = CaptureStage.done;
    _notify();
  }

  /// Marks the session failed with a user-facing [message]; the screen shows
  /// a retry affordance and calls [reset] to start over.
  void markFailed(String message) {
    if (_disposed) return;
    _cancelCountdown();
    _stage = CaptureStage.failed;
    _setInstruction(message, speak: true);
    _notify();
  }

  /// Returns the controller to the intro stage, dropping all session state.
  void reset() {
    if (_disposed) return;
    start();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelCountdown();
    super.dispose();
  }

  // --- internals -----------------------------------------------------------

  String _failureInstruction(
      PoseCheckResult check, CaptureView view, bool tiltBad) {
    if (tiltBad) return _tiltPrompt;
    if (check.issues.isEmpty) return _holdStillPrompt; // defensive
    return instructionFor(check.issues.first, view);
  }

  void _beginCountdown(CaptureView view) {
    _stableSince = null;
    _stage = view == CaptureView.front
        ? CaptureStage.countdownFront
        : CaptureStage.countdownSide;
    _countdownValue = 3;
    _setInstruction(_exhalePrompt, speak: false);
    unawaited(_tts.speak(_exhalePrompt));
    // Give the exhale cue time to play (and the subject time to exhale)
    // before the spoken 3-2-1; aborting cancels this prep timer too.
    _countdownTimer = Timer(const Duration(milliseconds: 2200), () {
      if (_disposed) return;
      unawaited(_tts.speak('3'));
      _notify();
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (_disposed) {
          timer.cancel();
          return;
        }
        _countdownValue -= 1;
        if (_countdownValue >= 1) {
          unawaited(_tts.speak('$_countdownValue'));
          _notify();
        } else {
          timer.cancel();
          _countdownTimer = null;
          unawaited(_startBurst(view));
        }
      });
    });
    _notify();
  }

  void _abortCountdown(CaptureView view,
      {required PoseCheckResult check, required bool tiltBad}) {
    _cancelCountdown();
    _stableSince = null;
    _stage = view == CaptureView.front
        ? CaptureStage.positioningFront
        : CaptureStage.positioningSide;
    _setInstruction(_failureInstruction(check, view, tiltBad), speak: true);
    _notify();
  }

  Future<void> _startBurst(CaptureView view) async {
    _stage = view == CaptureView.front
        ? CaptureStage.capturingFront
        : CaptureStage.capturingSide;
    _setInstruction(_capturingPrompt, speak: true);
    _notify();

    final captor = burstCaptor;
    if (captor == null) {
      markFailed('Capture is not available. Please try again.');
      return;
    }

    List<SilhouetteFrame> frames;
    try {
      frames = await captor(view);
    } catch (_) {
      frames = const [];
    }
    if (_disposed) return;

    if (frames.isEmpty) {
      // Burst produced nothing usable: retry this view.
      _stage = view == CaptureView.front
          ? CaptureStage.positioningFront
          : CaptureStage.positioningSide;
      _stableSince = null;
      _setInstruction(
        '$_retryPrompt ${view == CaptureView.front ? _frontPrompt : _sidePrompt}',
        speak: true,
      );
      _notify();
      return;
    }

    if (view == CaptureView.front) {
      _frontFrames = frames;
      _stage = CaptureStage.positioningSide;
      _stableSince = null;
      _lastCheck = null;
      _setInstruction(_sidePrompt, speak: true);
      _notify();
    } else {
      _stage = CaptureStage.processing;
      _setInstruction(_processingPrompt, speak: true);
      _notify();
      onReadyToProcess?.call(_frontFrames, frames);
    }
  }

  void _setInstruction(String text, {required bool speak}) {
    if (text == _instruction) return;
    _instruction = text;
    if (speak) unawaited(_tts.coach(text));
  }

  void _cancelCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _countdownValue = 3;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
