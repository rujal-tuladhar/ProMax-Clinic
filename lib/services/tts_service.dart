import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

/// Wraps `flutter_tts` for spoken capture coaching.
///
/// Queue-free: [speak] with `interrupt: true` (the default) cuts off the
/// current utterance and speaks the new text immediately. Every platform
/// call is guarded — on a device with no TTS engine/voice the service fails
/// silently and never throws.
///
/// [coach] is the high-frequency channel for live pose instructions: it is
/// debounced by 150 ms (only a phrase that stays current for 150 ms is
/// spoken, so rapidly changing instructions do not stutter) and it skips a
/// phrase identical to the one it last spoke, so a steady instruction is not
/// repeated over and over.
class TtsService {
  FlutterTts? _tts;
  bool _ready = false;

  Timer? _coachTimer;
  String? _pendingCoach;
  String? _lastCoached;

  /// Debounce window for [coach].
  static const Duration _coachDebounce = Duration(milliseconds: 150);

  /// Initializes the platform TTS engine (language, rate, volume).
  ///
  /// Safe to call on platforms without TTS: the service simply stays muted.
  Future<void> init() async {
    try {
      final tts = FlutterTts();
      await tts.setLanguage('en-US');
      // Plugin rates are 0..1; ~0.5 is a natural pace on both platforms.
      await tts.setSpeechRate(0.5);
      await tts.setVolume(1.0);
      // speak() resolves when the utterance starts, not when it ends, so an
      // interrupting speak never waits on the previous one.
      await tts.awaitSpeakCompletion(false);
      _tts = tts;
      _ready = true;
    } catch (_) {
      _tts = null;
      _ready = false; // No TTS voice available: stay silent, never throw.
    }
  }

  /// Speaks [text]. When [interrupt] is true (default) the current utterance
  /// is stopped first; queue-free either way (the platform replaces rather
  /// than queues). Silently does nothing when TTS is unavailable.
  Future<void> speak(String text, {bool interrupt = true}) async {
    final tts = _tts;
    if (!_ready || tts == null || text.isEmpty) return;
    try {
      if (interrupt) {
        await tts.stop();
      }
      await tts.speak(text);
    } catch (_) {
      // Fail silent: coaching must never crash the capture flow.
    }
  }

  /// Debounced coaching: speaks [text] once it has been the current phrase
  /// for 150 ms, skipping a phrase identical to the last one spoken via
  /// [coach]. Intended to be fed on every instruction change (5-15 Hz).
  Future<void> coach(String text) async {
    if (text.isEmpty || text == _lastCoached) return;
    _pendingCoach = text;
    _coachTimer?.cancel();
    _coachTimer = Timer(_coachDebounce, () {
      final phrase = _pendingCoach;
      _pendingCoach = null;
      if (phrase == null || phrase == _lastCoached) return;
      _lastCoached = phrase;
      // Fire and forget; speak() already swallows platform errors.
      speak(phrase, interrupt: true);
    });
  }

  /// Stops any current or pending speech (does not tear the engine down).
  Future<void> stop() async {
    _coachTimer?.cancel();
    _coachTimer = null;
    _pendingCoach = null;
    try {
      await _tts?.stop();
    } catch (_) {
      // Fail silent.
    }
  }

  /// Stops speech and releases the service; further calls are no-ops.
  Future<void> dispose() async {
    await stop();
    _ready = false;
    _tts = null;
    _lastCoached = null;
  }
}
