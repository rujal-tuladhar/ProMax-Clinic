import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../capture/capture_controller.dart';
import '../engine/measurement_engine.dart';
import '../engine/quality.dart';
import '../models/models.dart';
import '../services/pose_service.dart';
import '../services/profile_store.dart';
import '../services/segmentation_service.dart';
import '../services/tilt_service.dart';
import '../services/tts_service.dart';
import '../widgets/pose_overlay.dart';

/// Isolate entry point: runs the (pure Dart) measurement engine off the UI
/// thread. Takes a simple record because [SilhouetteFrame]/[BinaryMask] are
/// isolate-sendable ([Float32List] included). Must stay top-level for
/// [compute].
MeasurementResult measureInIsolate(
    (List<SilhouetteFrame>, List<SilhouetteFrame>, UserProfile) args) {
  final (front, side, profile) = args;
  return const MeasurementEngine()
      .compute(front: front, side: side, profile: profile);
}

/// Minimum interval between live pose detections fed to ML Kit.
const Duration _detectInterval = Duration(milliseconds: 150);

/// Mean brightness (0..255) of a live frame for the low-light gate, sampled
/// from `planes[0]` with [meanLuma].
///
/// Both stream formats have a usable first plane. On Android (NV21) it is
/// the Y plane, so the sampled mean is luma itself. On iOS (BGRA8888) it is
/// the interleaved B,G,R,A bytes: the mean of the colour bytes approximates
/// luma well enough for a brightness threshold, but the alpha byte is a
/// constant 255 that would lift an all-bytes mean by ~64 and keep the gate
/// from ever firing, so sampling starts at the first G byte and steps a
/// multiple of 4 — every sample is green (≈59% of luma), never alpha.
///
/// A frame with no bytes to judge reads as bright so the gate never blocks
/// on malformed input; pose detection then fails on its own terms.
double _frameLuma(CameraImage image) {
  if (image.planes.isEmpty) return 255;
  final bytes = image.planes[0].bytes;
  if (image.format.group == ImageFormatGroup.bgra8888) {
    if (bytes.length < 2) return 255;
    return meanLuma(Uint8List.sublistView(bytes, 1), stride: 100);
  }
  return meanLuma(bytes);
}

/// Pause between the stills of one burst.
const Duration _burstGap = Duration(milliseconds: 120);

enum _CameraStatus { initializing, ready, permissionDenied, error }

/// The guided capture screen: camera preview + live pose gating + burst
/// capture, driven by [CaptureController]. Navigates to `/results` with a
/// [MeasurementResult] as route arguments when measurement succeeds.
class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen>
    with WidgetsBindingObserver {
  final TtsService _tts = TtsService();
  final TiltService _tilt = TiltService();

  /// Fast stream-mode detector for live gating.
  final PoseService _livePose = PoseService();

  /// Accurate single-image detector for captured stills.
  final PoseService _stillPose = PoseService(streamMode: false);

  final SegmentationService _segmentation = SegmentationService();
  final ProfileStore _store = ProfileStore();

  late final CaptureController _capture;

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
    _capture = CaptureController(tts: _tts)
      ..burstCaptor = _runBurst
      ..onReadyToProcess = _onReadyToProcess;
    unawaited(_boot());
  }

  Future<void> _boot() async {
    await _tts.init();
    _tilt.start();
    _profile = await _store.loadProfile();
    if (!mounted) return;
    _capture.start();
    await _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _capture.dispose();
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
      // Returning from the system settings after granting permission.
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

    // Tear down any previous controller (e.g. on flip or retry).
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
    } catch (e) {
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
      // Stream could not start (e.g. mid-dispose); gating simply pauses.
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
    final view = _capture.gatingView;
    if (view == null) return; // not in a positioning/countdown stage
    if (_detecting) return; // never run detections concurrently
    final now = DateTime.now();
    if (now.difference(_lastDetection) < _detectInterval) return;
    final camera = _camera;
    if (camera == null) return;
    _lastDetection = now;
    _detecting = true;
    unawaited(_detect(image, camera, view));
  }

  Future<void> _detect(
      CameraImage image, CameraController camera, CaptureView view) async {
    try {
      // Low-light gate first: a dark frame cannot be segmented reliably and
      // running pose detection on it is wasted work, so skip ML Kit and
      // coach the person towards light instead. The controller treats this
      // like any failing check (resets the stability window, aborts a
      // countdown) and speaks instructionFor(lowLight).
      if (isTooDark(_frameLuma(image))) {
        _capture.onPoseCheck(
          const PoseCheckResult([PoseIssue.lowLight]),
          view,
          pitchDegrees: _tilt.latestPitch,
        );
        return;
      }
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
        check = view == CaptureView.front
            ? checkFrontPose(pose, width, height)
            : checkSidePose(pose, width, height);
      }
      _capture.onPoseCheck(check, view, pitchDegrees: _tilt.latestPitch);
    } catch (_) {
      // A dropped frame is fine; the next one will be checked.
    } finally {
      _detecting = false;
    }
  }

  // --- burst capture -------------------------------------------------------

  /// Runs one still burst for [view]: stop the stream, take
  /// [CaptureController.framesPerBurst] pictures ~120 ms apart, then turn
  /// each file into a [SilhouetteFrame] (accurate pose + segmentation mask),
  /// skipping failures and deleting the temp files. Restarts the stream when
  /// more live gating is pending (front done, or empty burst to retry).
  Future<List<SilhouetteFrame>> _runBurst(CaptureView view) async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return const [];

    await _stopStream();

    final shots = <XFile>[];
    for (var i = 0; i < _capture.framesPerBurst; i++) {
      if (!mounted) break;
      try {
        shots.add(await camera.takePicture());
      } on CameraException {
        // Skip this shot; keep bursting.
      }
      if (i < _capture.framesPerBurst - 1) {
        await Future<void>.delayed(_burstGap);
      }
    }

    final frames = <SilhouetteFrame>[];
    for (final shot in shots) {
      try {
        final detected = await _stillPose.detectFromFile(shot.path);
        if (detected != null) {
          final mask = await _segmentation.maskFromFile(shot.path);
          if (mask != null) {
            final (pose, width, height) = detected;
            frames.add(SilhouetteFrame(
              mask: mask,
              pose: pose,
              imageWidth: width,
              imageHeight: height,
              view: view,
            ));
          }
        }
      } catch (_) {
        // Skip frames where detection or segmentation fails.
      } finally {
        try {
          await File(shot.path).delete();
        } catch (_) {}
      }
    }

    // More views pending (side still to come), or the burst failed and the
    // controller will drop back to positioning: live gating needs the stream.
    if (mounted && (view == CaptureView.front || frames.isEmpty)) {
      await _startStream();
    }
    return frames;
  }

  // --- processing ----------------------------------------------------------

  void _onReadyToProcess(
      List<SilhouetteFrame> front, List<SilhouetteFrame> side) {
    unawaited(_computeAndNavigate(front, side));
  }

  Future<void> _computeAndNavigate(
      List<SilhouetteFrame> front, List<SilhouetteFrame> side) async {
    await _stopStream();
    final profile = _profile ??= await _store.loadProfile();
    if (profile == null) {
      _capture.markFailed(
          'We could not find your profile. Please set your height first.');
      return;
    }
    try {
      final result =
          await compute(measureInIsolate, (front, side, profile));
      if (!mounted) return;
      _capture.markDone();
      Navigator.of(context)
          .pushReplacementNamed('/results', arguments: result);
    } on MeasurementException catch (e) {
      _capture.markFailed(e.message);
    } catch (_) {
      _capture.markFailed(
          'Something went wrong while measuring. Please try again.');
    }
  }

  Future<void> _retry() async {
    _capture.reset();
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
        _CameraStatus.permissionDenied => _PermissionDeniedView(
            onRetry: _initCamera,
          ),
        _CameraStatus.error => _ErrorView(
            message:
                _errorMessage ?? 'The camera could not be started.',
            onRetry: _initCamera,
          ),
        _CameraStatus.ready => ListenableBuilder(
            listenable: _capture,
            builder: (context, _) => _buildCapture(context),
          ),
      },
    );
  }

  Widget _buildCapture(BuildContext context) {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white70),
      );
    }
    final stage = _capture.stage;
    final showGuide = stage == CaptureStage.positioningFront ||
        stage == CaptureStage.countdownFront ||
        stage == CaptureStage.capturingFront ||
        stage == CaptureStage.positioningSide ||
        stage == CaptureStage.countdownSide ||
        stage == CaptureStage.capturingSide;
    final countingDown = stage == CaptureStage.countdownFront ||
        stage == CaptureStage.countdownSide;
    final positioning = stage == CaptureStage.positioningFront ||
        stage == CaptureStage.positioningSide;

    return Stack(
      fit: StackFit.expand,
      children: [
        _CameraPreviewFill(controller: camera),
        if (showGuide)
          PoseOverlay(check: _capture.lastCheck, view: _capture.displayView),
        if (showGuide) _instructionBanner(context),
        if (countingDown)
          Center(
            child: Text(
              '${_capture.countdownValue}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 148,
                fontWeight: FontWeight.w700,
                shadows: [Shadow(blurRadius: 24, color: Colors.black54)],
              ),
            ),
          ),
        if (stage == CaptureStage.capturingFront ||
            stage == CaptureStage.capturingSide)
          const Align(
            alignment: Alignment(0, 0.55),
            child: _CapturingChip(),
          ),
        if (stage == CaptureStage.intro) _introOverlay(context),
        if (stage == CaptureStage.processing ||
            stage == CaptureStage.done)
          _processingOverlay(context),
        if (stage == CaptureStage.failed) _failedOverlay(context),
        _topBar(context, showFlip: stage == CaptureStage.intro || positioning),
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
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close),
              tooltip: 'Cancel',
            ),
            const Spacer(),
            _progressDots(),
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

  /// Two dots showing which of the front/side views are done or active.
  Widget _progressDots() {
    final stageIndex = _capture.stage.index;
    Color dotColor(CaptureView view) {
      final doneAfter = view == CaptureView.front
          ? CaptureStage.capturingFront.index
          : CaptureStage.capturingSide.index;
      final activeFrom = view == CaptureView.front
          ? CaptureStage.positioningFront.index
          : CaptureStage.positioningSide.index;
      if (stageIndex > doneAfter) return const Color(0xFF66E28A);
      if (stageIndex >= activeFrom) return Colors.white;
      return Colors.white38;
    }

    Widget dot(CaptureView view, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dotColor(view),
              ),
            ),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ],
        );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black38,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          dot(CaptureView.front, 'Front'),
          const SizedBox(width: 14),
          dot(CaptureView.side, 'Side'),
        ],
      ),
    );
  }

  Widget _instructionBanner(BuildContext context) {
    final ok = _capture.lastCheck?.okNow ?? false;
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: ok
                ? const Color(0xCC1B5E20) // deep green, translucent
                : Colors.black.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            _capture.instruction,
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
    return _ScrimOverlay(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.accessibility_new, color: Colors.white, size: 56),
          const SizedBox(height: 16),
          const Text(
            'Let’s get your measurements',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Prop your phone upright at hip height, step 2–3 metres '
            'back and make sure your whole body is visible. Tight clothing '
            'gives the most accurate result.\n\n'
            'Voice coaching will guide you through a front and a side photo. '
            'For the front photo stand with your feet a little apart — the '
            'gap between your legs is how we measure your inseam. '
            'Everything stays on your phone.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 15, height: 1.4),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _capture.confirmIntro,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start'),
          ),
        ],
      ),
    );
  }

  Widget _processingOverlay(BuildContext context) {
    return _ScrimOverlay(
      child: Column(
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
      ),
    );
  }

  Widget _failedOverlay(BuildContext context) {
    return _ScrimOverlay(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.amber, size: 52),
          const SizedBox(height: 16),
          Text(
            _capture.instruction,
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
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Back',
                style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }
}

/// Fills the screen with the camera preview (cover fit, centre crop), which
/// keeps the preview aspect ratio correct in portrait.
class _CameraPreviewFill extends StatelessWidget {
  const _CameraPreviewFill({required this.controller});

  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    final previewSize = controller.value.previewSize;
    if (previewSize == null) return const SizedBox.expand();
    // previewSize is reported in sensor (landscape) orientation; the app runs
    // portrait, so swap the sides for the on-screen box.
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

/// Centred content over a darkening scrim.
class _ScrimOverlay extends StatelessWidget {
  const _ScrimOverlay({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.72),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: SafeArea(
        child: SingleChildScrollView(child: child),
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
          Text(
            'Capturing… hold still',
            style: TextStyle(color: Colors.white, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

/// Friendly screen shown when camera permission is denied.
class _PermissionDeniedView extends StatelessWidget {
  const _PermissionDeniedView({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return _ScrimOverlay(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.no_photography_outlined,
              color: Colors.white, size: 56),
          const SizedBox(height: 16),
          const Text(
            'FitSize needs the camera',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Your measurements are taken from two photos that never leave '
            'your phone. Please allow camera access to continue — you '
            'can enable it in your device settings if you previously '
            'declined.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 15, height: 1.4),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.camera_alt_outlined),
            label: const Text('Try again'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child:
                const Text('Back', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }
}

/// Generic camera-error screen with a retry button.
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return _ScrimOverlay(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.videocam_off_outlined,
              color: Colors.amber, size: 56),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.white, fontSize: 16, height: 1.4),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child:
                const Text('Back', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }
}
