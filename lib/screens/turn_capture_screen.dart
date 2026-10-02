import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../capture/turn_capture_controller.dart';
import '../engine/measurement_engine.dart' show MeasurementException;
import '../engine/quality.dart';
import '../engine/rotation_engine.dart';
import '../models/models.dart';
import '../services/pose_service.dart';
import '../services/profile_store.dart';
import '../services/segmentation_service.dart';
import '../services/tilt_service.dart';
import '../services/tts_service.dart';

/// Isolate entry point for the rotation engine (kept top-level for
/// [compute]). [RotationFrame]/[SilhouetteFrame] are isolate-sendable.
MeasurementResult measureTurnInIsolate(
    (List<RotationFrame>, UserProfile) args) {
  final (frames, profile) = args;
  return const RotationMeasurementEngine()
      .compute(frames: frames, profile: profile);
}

const Duration _detectInterval = Duration(milliseconds: 150);
const Duration _burstGap = Duration(milliseconds: 90);

/// Stills captured per stop; the clearest (most confident pose) is kept.
const int _shotsPerStop = 2;

enum _CameraStatus { initializing, ready, permissionDenied, error }

/// Guided 360° turn capture ("precision" mode). Navigates to `/results` with
/// a [MeasurementResult] when the turn is measured.
class TurnCaptureScreen extends StatefulWidget {
  const TurnCaptureScreen({super.key});

  @override
  State<TurnCaptureScreen> createState() => _TurnCaptureScreenState();
}

class _TurnCaptureScreenState extends State<TurnCaptureScreen>
    with WidgetsBindingObserver {
  final TtsService _tts = TtsService();
  final TiltService _tilt = TiltService();
  final PoseService _livePose = PoseService();
  final PoseService _stillPose = PoseService(streamMode: false);
  final SegmentationService _segmentation = SegmentationService();
  final ProfileStore _store = ProfileStore();

  late final TurnCaptureController _turn;

  CameraController? _camera;
  List<CameraDescription>? _cameras;
  CameraLensDirection _lensDirection = CameraLensDirection.front;
  _CameraStatus _status = _CameraStatus.initializing;
  String? _errorMessage;

  bool _detecting = false;
  DateTime _lastDetection = DateTime.fromMillisecondsSinceEpoch(0);
  UserProfile? _profile;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _turn = TurnCaptureController(tts: _tts)
      ..stopCaptor = _captureStop
      ..onReadyToProcess = _onReadyToProcess;
    unawaited(_boot());
  }

  Future<void> _boot() async {
    await _tts.init();
    _tilt.start();
    _profile = await _store.loadProfile();
    if (!mounted) return;
    _turn.start();
    await _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _turn.dispose();
    final camera = _camera;
    _camera = null;
    if (camera != null) {
      unawaited(() async {
        try {
          if (camera.value.isStreamingImages) await camera.stopImageStream();
        } catch (_) {}
        await camera.dispose();
      }());
    }
    unawaited(_livePose.dispose());
    unawaited(_stillPose.dispose());
    unawaited(_segmentation.dispose());
    unawaited(_tts.dispose());
    _tilt.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) {
      if (state == AppLifecycleState.resumed &&
          _status == _CameraStatus.permissionDenied) {
        unawaited(_initCamera());
      }
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(_stopStream());
      _tilt.stop();
    } else if (state == AppLifecycleState.resumed) {
      _tilt.start();
      unawaited(_startStream());
    }
  }

  // --- camera --------------------------------------------------------------

  Future<void> _initCamera() async {
    setState(() {
      _status = _CameraStatus.initializing;
      _errorMessage = null;
    });

    final old = _camera;
    _camera = null;
    if (old != null) {
      try {
        if (old.value.isStreamingImages) await old.stopImageStream();
      } catch (_) {}
      await old.dispose();
    }

    try {
      _cameras ??= await availableCameras();
      final cameras = _cameras!;
      if (cameras.isEmpty) {
        setState(() {
          _status = _CameraStatus.error;
          _errorMessage = 'No camera was found on this device.';
        });
        return;
      }
      final description = cameras.firstWhere(
        (c) => c.lensDirection == _lensDirection,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        description,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      _camera = controller;
      setState(() => _status = _CameraStatus.ready);
      await _startStream();
    } on CameraException catch (e) {
      if (!mounted) return;
      setState(() {
        if (_isPermissionError(e)) {
          _status = _CameraStatus.permissionDenied;
        } else {
          _status = _CameraStatus.error;
          _errorMessage = e.description ?? 'The camera could not be started.';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _status = _CameraStatus.error;
        _errorMessage = 'The camera could not be started.';
      });
    }
  }

  static bool _isPermissionError(CameraException e) {
    final code = e.code.toLowerCase();
    return code.contains('accessdenied') ||
        code.contains('accessrestricted') ||
        code.contains('permission');
  }

  Future<void> _flipCamera() async {
    _lensDirection = _lensDirection == CameraLensDirection.front
        ? CameraLensDirection.back
        : CameraLensDirection.front;
    await _initCamera();
  }

  Future<void> _startStream() async {
    final camera = _camera;
    if (!mounted ||
        camera == null ||
        !camera.value.isInitialized ||
        camera.value.isStreamingImages) {
      return;
    }
    try {
      await camera.startImageStream(_onFrame);
    } on CameraException {
      // Gating simply pauses.
    }
  }

  Future<void> _stopStream() async {
    final camera = _camera;
    if (camera == null || !camera.value.isStreamingImages) return;
    try {
      await camera.stopImageStream();
    } on CameraException {
      // Already stopped.
    }
  }

  // --- live gating ---------------------------------------------------------

  void _onFrame(CameraImage image) {
    if (!_turn.isGating) return;
    if (_detecting) return;
    final now = DateTime.now();
    if (now.difference(_lastDetection) < _detectInterval) return;
    final camera = _camera;
    if (camera == null) return;
    _lastDetection = now;
    _detecting = true;
    unawaited(_detect(image, camera));
  }

  Future<void> _detect(CameraImage image, CameraController camera) async {
    try {
      final detected = await _livePose.detectFromCameraImage(
        image,
        camera.description,
        camera.value.deviceOrientation,
      );
      if (!mounted) return;
      final PoseCheckResult check;
      if (detected == null) {
        check = const PoseCheckResult([PoseIssue.noPerson]);
      } else {
        final (pose, width, height) = detected;
        check = checkTurnPose(pose, width, height);
      }
      _turn.onPoseCheck(check, pitchDegrees: _tilt.latestPitch);
    } catch (_) {
      // Dropped frame; the next one will be checked.
    } finally {
      _detecting = false;
    }
  }

  // --- per-stop capture ----------------------------------------------------

  /// Captures one still at [angleDegrees]: stop the stream, take a couple of
  /// pictures, build a [RotationFrame] from the most confident one, restart
  /// the stream for the next stop. Returns null when nothing usable came out.
  Future<RotationFrame?> _captureStop(double angleDegrees) async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return null;

    await _stopStream();

    final shots = <XFile>[];
    for (var i = 0; i < _shotsPerStop; i++) {
      if (!mounted) break;
      try {
        shots.add(await camera.takePicture());
      } on CameraException {
        // Skip this shot.
      }
      if (i < _shotsPerStop - 1) {
        await Future<void>.delayed(_burstGap);
      }
    }

    RotationFrame? best;
    double bestLikelihood = -1;
    for (final shot in shots) {
      try {
        final detected = await _stillPose.detectFromFile(shot.path);
        if (detected != null) {
          final mask = await _segmentation.maskFromFile(shot.path);
          if (mask != null) {
            final (pose, width, height) = detected;
            final likelihood = pose.minLikelihood(const [
              Landmark.leftShoulder,
              Landmark.rightShoulder,
              Landmark.leftHip,
              Landmark.rightHip,
            ]);
            if (likelihood > bestLikelihood) {
              bestLikelihood = likelihood;
              best = RotationFrame(
                angleDegrees: angleDegrees,
                frame: SilhouetteFrame(
                  mask: mask,
                  pose: pose,
                  imageWidth: width,
                  imageHeight: height,
                  view: CaptureView.front,
                ),
              );
            }
          }
        }
      } catch (_) {
        // Skip this shot.
      } finally {
        try {
          await File(shot.path).delete();
        } catch (_) {}
      }
    }

    if (mounted) await _startStream();
    return best;
  }

  // --- processing ----------------------------------------------------------

  void _onReadyToProcess(List<RotationFrame> frames) {
    unawaited(_computeAndNavigate(frames));
  }

  Future<void> _computeAndNavigate(List<RotationFrame> frames) async {
    await _stopStream();
    final profile = _profile ??= await _store.loadProfile();
    if (profile == null) {
      _turn.markFailed(
          'We could not find your profile. Please set your height first.');
      return;
    }
    try {
      final result =
          await compute(measureTurnInIsolate, (frames, profile));
      if (!mounted) return;
      _turn.markDone();
      Navigator.of(context)
          .pushReplacementNamed('/results', arguments: result);
    } on MeasurementException catch (e) {
      _turn.markFailed(e.message);
    } catch (_) {
      _turn.markFailed(
          'Something went wrong while measuring. Please try again.');
    }
  }

  Future<void> _retry() async {
    _turn.reset();
    await _startStream();
  }

  // --- UI ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: switch (_status) {
        _CameraStatus.initializing => const Center(
            child: CircularProgressIndicator(color: Colors.white70),
          ),
        _CameraStatus.permissionDenied =>
          _TurnMessageView.permission(onRetry: _initCamera, onBack: _back),
        _CameraStatus.error => _TurnMessageView.error(
            message: _errorMessage ?? 'The camera could not be started.',
            onRetry: _initCamera,
            onBack: _back,
          ),
        _CameraStatus.ready => ListenableBuilder(
            listenable: _turn,
            builder: (context, _) => _buildCapture(context),
          ),
      },
    );
  }

  void _back() => Navigator.of(context).maybePop();

  Widget _buildCapture(BuildContext context) {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white70),
      );
    }
    final stage = _turn.stage;
    final gatingOrCapturing =
        stage == TurnStage.positioning || stage == TurnStage.capturing;
    final ok = _turn.lastCheck?.okNow ?? false;

    return Stack(
      fit: StackFit.expand,
      children: [
        _CameraPreviewFill(controller: camera),
        if (gatingOrCapturing)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _TurnRingPainter(
                  progress: _turn.progress,
                  stops: _turn.stops,
                  activeStop: _turn.currentStop,
                  ok: ok,
                ),
              ),
            ),
          ),
        if (gatingOrCapturing) _instructionBanner(context),
        if (stage == TurnStage.capturing)
          const Align(
            alignment: Alignment(0, 0.52),
            child: _CapturingChip(),
          ),
        if (stage == TurnStage.intro) _introOverlay(context),
        if (stage == TurnStage.processing || stage == TurnStage.done)
          _scrim(const _ProcessingBody()),
        if (stage == TurnStage.failed) _failedOverlay(context),
        _topBar(context, showFlip: stage == TurnStage.intro),
      ],
    );
  }

  Widget _topBar(BuildContext context, {required bool showFlip}) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            IconButton.filledTonal(
              onPressed: _back,
              icon: const Icon(Icons.close),
              tooltip: 'Cancel',
            ),
            const Spacer(),
            _StopCounter(current: _turn.currentStop, total: _turn.stops),
            const Spacer(),
            if (showFlip)
              IconButton.filledTonal(
                onPressed: _flipCamera,
                icon: const Icon(Icons.cameraswitch_outlined),
                tooltip: 'Flip camera',
              )
            else
              const SizedBox(width: 48),
          ],
        ),
      ),
    );
  }

  Widget _instructionBanner(BuildContext context) {
    final ok = _turn.lastCheck?.okNow ?? false;
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: ok
                ? const Color(0xCC1B5E20)
                : Colors.black.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            _turn.instruction,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _introOverlay(BuildContext context) {
    return _scrim(
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.threesixty, color: Colors.white, size: 56),
          const SizedBox(height: 16),
          const Text(
            'Precision turn',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'You will turn slowly all the way around, pausing at each spoken '
            'cue while a photo is taken — ${_turn.stops} in total. More '
            'angles means a more accurate measurement than the two-photo '
            'scan. Everything stays on your phone.',
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.white70, fontSize: 15, height: 1.4),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _turn.confirmIntro,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start'),
          ),
        ],
      ),
    );
  }

  Widget _failedOverlay(BuildContext context) {
    return _scrim(
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.amber, size: 52),
          const SizedBox(height: 16),
          Text(
            _turn.instruction,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _retry,
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          ),
          TextButton(
            onPressed: _back,
            child:
                const Text('Back', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }

  Widget _scrim(Widget child) => Container(
        color: Colors.black.withValues(alpha: 0.72),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: SafeArea(child: SingleChildScrollView(child: child)),
      );
}

/// Fills the screen with the camera preview (cover fit), swapping the
/// sensor-orientation preview sides for portrait.
class _CameraPreviewFill extends StatelessWidget {
  const _CameraPreviewFill({required this.controller});

  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    final previewSize = controller.value.previewSize;
    if (previewSize == null) return const SizedBox.expand();
    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: previewSize.height,
          height: previewSize.width,
          child: CameraPreview(controller),
        ),
      ),
    );
  }
}

/// A circular progress ring of stop ticks around the frame edge: filled
/// ticks are captured stops, the current one pulses, remaining are faint.
class _TurnRingPainter extends CustomPainter {
  _TurnRingPainter({
    required this.progress,
    required this.stops,
    required this.activeStop,
    required this.ok,
  });

  final double progress;
  final int stops;
  final int activeStop;
  final bool ok;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide * 0.42;
    final done = Paint()..color = const Color(0xFF66E28A);
    final active = Paint()..color = ok ? const Color(0xFF66E28A) : Colors.white;
    final pending = Paint()..color = Colors.white24;

    for (var i = 0; i < stops; i++) {
      // Start at the top, go clockwise.
      final angle = -3.14159265 / 2 + i * 2 * 3.14159265 / stops;
      final tickCenter = center +
          Offset(radius * _cos(angle), radius * _sin(angle));
      final paint = i < activeStop
          ? done
          : (i == activeStop ? active : pending);
      final r = i == activeStop ? 9.0 : 6.0;
      canvas.drawCircle(tickCenter, r, paint);
    }
  }

  // Avoid importing dart:math just for cos/sin in a hot paint path.
  double _cos(double x) {
    // Use the framework's Offset.fromDirection instead.
    return Offset.fromDirection(x, 1).dx;
  }

  double _sin(double x) => Offset.fromDirection(x, 1).dy;

  @override
  bool shouldRepaint(_TurnRingPainter old) =>
      old.progress != progress ||
      old.activeStop != activeStop ||
      old.ok != ok;
}

class _StopCounter extends StatelessWidget {
  const _StopCounter({required this.current, required this.total});

  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black38,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        'Stop ${(current + 1).clamp(1, total)} of $total',
        style: const TextStyle(color: Colors.white, fontSize: 13),
      ),
    );
  }
}

class _CapturingChip extends StatelessWidget {
  const _CapturingChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          ),
          SizedBox(width: 10),
          Text('Capturing… hold still',
              style: TextStyle(color: Colors.white, fontSize: 14)),
        ],
      ),
    );
  }
}

class _ProcessingBody extends StatelessWidget {
  const _ProcessingBody();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: const [
        CircularProgressIndicator(color: Colors.white),
        SizedBox(height: 20),
        Text(
          'Calculating your measurements…',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// Shared permission/error screen for the turn flow.
class _TurnMessageView extends StatelessWidget {
  const _TurnMessageView({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.body,
    required this.onRetry,
    required this.onBack,
  });

  factory _TurnMessageView.permission({
    required Future<void> Function() onRetry,
    required VoidCallback onBack,
  }) =>
      _TurnMessageView(
        icon: Icons.no_photography_outlined,
        iconColor: Colors.white,
        title: 'FitSize needs the camera',
        body: 'Your measurements are taken from photos that never leave your '
            'phone. Please allow camera access to continue — you can enable '
            'it in your device settings if you previously declined.',
        onRetry: onRetry,
        onBack: onBack,
      );

  factory _TurnMessageView.error({
    required String message,
    required Future<void> Function() onRetry,
    required VoidCallback onBack,
  }) =>
      _TurnMessageView(
        icon: Icons.videocam_off_outlined,
        iconColor: Colors.amber,
        title: message,
        body: '',
        onRetry: onRetry,
        onBack: onBack,
      );

  final IconData icon;
  final Color iconColor;
  final String title;
  final String body;
  final Future<void> Function() onRetry;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.72),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: iconColor, size: 54),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ),
              ),
              if (body.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 15, height: 1.4),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
              TextButton(
                onPressed: onBack,
                child: const Text('Back',
                    style: TextStyle(color: Colors.white70)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
