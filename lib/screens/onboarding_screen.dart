import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../services/profile_store.dart';

/// Collects the user profile FitSize needs before it can measure anything:
/// standing height (the single scale reference — must be accurate), sex
/// (used for the size charts) and preferred units.
///
/// Used in two ways:
/// * embedded as the first screen on a fresh install (pass [onDone] so the
///   app shell can switch to home after saving), and
/// * pushed as the `/onboarding` route to edit the profile later (it then
///   pops itself after saving).
class OnboardingScreen extends StatefulWidget {
  /// Called after the profile has been saved when this screen is shown
  /// outside the navigator stack (first run). When null, the screen pops
  /// itself instead.
  final VoidCallback? onDone;

  /// Creates the onboarding / profile-editing screen.
  const OnboardingScreen({super.key, this.onDone});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final ProfileStore _store = ProfileStore();

  final TextEditingController _cmController = TextEditingController();
  final TextEditingController _feetController = TextEditingController();
  final TextEditingController _inchesController = TextEditingController();

  UnitSystem _units = UnitSystem.metric;
  Sex _sex = Sex.female;
  String? _error;
  bool _saving = false;

  static const double _minHeightCm = 100;
  static const double _maxHeightCm = 230;

  @override
  void initState() {
    super.initState();
    _prefillFromSavedProfile();
  }

  @override
  void dispose() {
    _cmController.dispose();
    _feetController.dispose();
    _inchesController.dispose();
    super.dispose();
  }

  Future<void> _prefillFromSavedProfile() async {
    final profile = await _store.loadProfile();
    if (!mounted || profile == null) return;
    setState(() {
      _units = profile.units;
      _sex = profile.sex;
      _fillHeightFields(profile.heightCm);
    });
  }

  /// Height currently entered, converted to cm, or null when unparsable.
  double? _enteredHeightCm() {
    if (_units == UnitSystem.metric) {
      return double.tryParse(_cmController.text.trim().replaceAll(',', '.'));
    }
    final feet = double.tryParse(_feetController.text.trim());
    final inchesText = _inchesController.text.trim();
    final inches = inchesText.isEmpty ? 0.0 : double.tryParse(inchesText);
    if (feet == null || inches == null) return null;
    return (feet * 12 + inches) * 2.54;
  }

  void _fillHeightFields(double cm) {
    if (_units == UnitSystem.metric) {
      _cmController.text = _trimTrailingZero(cm.toStringAsFixed(1));
    } else {
      final totalInches = cmToInches(cm);
      var feet = totalInches ~/ 12;
      var inches = double.parse((totalInches - feet * 12).toStringAsFixed(1));
      if (inches >= 12) {
        feet += 1;
        inches = 0;
      }
      _feetController.text = '$feet';
      _inchesController.text = _trimTrailingZero(inches.toStringAsFixed(1));
    }
  }

  static String _trimTrailingZero(String s) =>
      s.endsWith('.0') ? s.substring(0, s.length - 2) : s;

  void _switchUnits(UnitSystem next) {
    if (next == _units) return;
    final cm = _enteredHeightCm();
    setState(() {
      _units = next;
      if (cm != null) _fillHeightFields(cm);
    });
  }

  Future<void> _save() async {
    final cm = _enteredHeightCm();
    if (cm == null) {
      setState(() => _error = 'Please enter your height.');
      return;
    }
    if (cm < _minHeightCm || cm > _maxHeightCm) {
      setState(() => _error =
          'Height must be between 100 and 230 cm (about 3\'3" to 7\'7").');
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    final roundedCm = (cm * 10).roundToDouble() / 10;
    await _store.saveProfile(
      UserProfile(heightCm: roundedCm, sex: _sex, units: _units),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (widget.onDone != null) {
      widget.onDone!();
    } else if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('About you')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'Two photos. Your real size.',
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'FitSize uses your height to turn pixels into centimetres, '
              'so enter it accurately — measured without shoes.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            Text('Height', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<UnitSystem>(
              segments: const [
                ButtonSegment(
                  value: UnitSystem.metric,
                  label: Text('cm'),
                  icon: Icon(Icons.straighten),
                ),
                ButtonSegment(
                  value: UnitSystem.imperial,
                  label: Text('ft + in'),
                  icon: Icon(Icons.square_foot),
                ),
              ],
              selected: {_units},
              onSelectionChanged: (selection) => _switchUnits(selection.first),
            ),
            const SizedBox(height: 12),
            if (_units == UnitSystem.metric)
              TextField(
                controller: _cmController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Height',
                  suffixText: 'cm',
                  border: OutlineInputBorder(),
                ),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _feetController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Feet',
                        suffixText: 'ft',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _inchesController,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[\d.]')),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Inches',
                        suffixText: 'in',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.error),
              ),
            ],
            const SizedBox(height: 24),
            Text('Sex', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Used only to pick the matching size chart.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            SegmentedButton<Sex>(
              segments: const [
                ButtonSegment(value: Sex.female, label: Text('Female')),
                ButtonSegment(value: Sex.male, label: Text('Male')),
                ButtonSegment(value: Sex.other, label: Text('Other')),
              ],
              selected: {_sex},
              onSelectionChanged: (selection) =>
                  setState(() => _sex = selection.first),
            ),
            const SizedBox(height: 28),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.lock_outline, color: scheme.onSecondaryContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Private by design: your photos are processed on your '
                      'phone and never uploaded. Only your measurements are '
                      'kept, on this device.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.check),
              label: const Text('Save and continue'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
