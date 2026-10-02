import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

/// `shared_preferences`-backed persistence for the user profile and the
/// measurement history (newest first, capped at [maxHistory] entries).
///
/// Values are stored as JSON strings; corrupt or missing data degrades to
/// `null` / an empty history instead of throwing, so the app can always
/// start.
class ProfileStore {
  static const String _profileKey = 'fitsize.profile';
  static const String _historyKey = 'fitsize.history';

  /// Maximum number of results kept in history.
  static const int maxHistory = 20;

  /// Loads the saved [UserProfile], or `null` when none is saved (first run)
  /// or the stored value cannot be parsed.
  Future<UserProfile?> loadProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_profileKey);
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      return UserProfile.fromJson(
          decoded is Map<String, dynamic> ? decoded : null);
    } catch (_) {
      return null;
    }
  }

  /// Persists [profile], replacing any previous one.
  Future<void> saveProfile(UserProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_profileKey, jsonEncode(profile.toJson()));
  }

  /// Loads the measurement history, newest first. Corrupt entries are
  /// skipped; a missing or unreadable store yields an empty list.
  Future<List<MeasurementResult>> loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_historyKey);
      if (raw == null) return <MeasurementResult>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <MeasurementResult>[];
      final results = <MeasurementResult>[];
      for (final entry in decoded) {
        if (entry is Map<String, dynamic>) {
          try {
            results.add(MeasurementResult.fromJson(entry));
          } catch (_) {
            // Skip a corrupt entry rather than losing the whole history.
          }
        }
      }
      return results;
    } catch (_) {
      return <MeasurementResult>[];
    }
  }

  /// Prepends [result] to the history and persists it, keeping at most
  /// [maxHistory] entries (oldest dropped).
  Future<void> addResult(MeasurementResult result) async {
    final history = await loadHistory();
    history.insert(0, result);
    if (history.length > maxHistory) {
      history.removeRange(maxHistory, history.length);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _historyKey,
      jsonEncode(history.map((r) => r.toJson()).toList()),
    );
  }
}
