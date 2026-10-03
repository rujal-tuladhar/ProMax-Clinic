import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../services/profile_store.dart';
import '../theme/app_theme.dart';

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
      setState(
        () => _error =
            'Height must be between 100 and 230 cm (about 3\'3" to 7\'7").',
      );
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
    final firstRun = widget.onDone != null;

    return Scaffold(
      // First run: no app bar, the page heading carries the screen. Editing
      // later (pushed as a route): a bar with the back arrow.
      appBar: firstRun ? null : AppBar(title: const Text('Your profile')),
      body: SafeArea(
        // A plain column in a scroll view (not a lazy ListView) so the whole
        // short form, privacy note included, is always built.
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.sm,
            AppSpacing.gutter,
            AppSpacing.xl,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _StepHint(current: 1),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Two photos.\nYour real size.',
                style: theme.textTheme.headlineLarge,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'FitSize turns pixels into centimetres using your height, so '
                'enter it accurately — measured standing tall, without shoes.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              _FormSection(
                icon: Icons.height_rounded,
                title: 'Height',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SegmentedButton<UnitSystem>(
                      segments: const [
                        ButtonSegment(
                          value: UnitSystem.metric,
                          label: Text('cm'),
                          icon: Icon(Icons.straighten_rounded),
                        ),
                        ButtonSegment(
                          value: UnitSystem.imperial,
                          label: Text('ft + in'),
                          icon: Icon(Icons.square_foot_rounded),
                        ),
                      ],
                      selected: {_units},
                      showSelectedIcon: false,
                      onSelectionChanged: (selection) =>
                          _switchUnits(selection.first),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    if (_units == UnitSystem.metric)
                      TextField(
                        controller: _cmController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')),
                        ],
                        style: theme.textTheme.headlineSmall,
                        decoration: const InputDecoration(
                          labelText: 'Height',
                          hintText: '170',
                          suffixText: 'cm',
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
                              style: theme.textTheme.headlineSmall,
                              decoration: const InputDecoration(
                                labelText: 'Feet',
                                hintText: '5',
                                suffixText: 'ft',
                              ),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: TextField(
                              controller: _inchesController,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(
                                  RegExp(r'[\d.]'),
                                ),
                              ],
                              style: theme.textTheme.headlineSmall,
                              decoration: const InputDecoration(
                                labelText: 'Inches',
                                hintText: '7',
                                suffixText: 'in',
                              ),
                            ),
                          ),
                        ],
                      ),
                    if (_error != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Row(
                        children: [
                          Icon(
                            Icons.error_outline_rounded,
                            size: 16,
                            color: scheme.error,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _error!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.error,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              _FormSection(
                icon: Icons.person_outline_rounded,
                title: 'Sex',
                subtitle: 'Used only to pick the matching size chart.',
                child: SegmentedButton<Sex>(
                  segments: const [
                    ButtonSegment(value: Sex.female, label: Text('Female')),
                    ButtonSegment(value: Sex.male, label: Text('Male')),
                    ButtonSegment(value: Sex.other, label: Text('Other')),
                  ],
                  selected: {_sex},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) =>
                      setState(() => _sex = selection.first),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(AppRadii.field),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.lock_outline_rounded,
                      size: 20,
                      color: scheme.onSecondaryContainer,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text(
                        'Private by design: your photos are processed on your '
                        'phone and never uploaded. Only your measurements are '
                        'kept, on this device.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSecondaryContainer,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          AppSpacing.sm,
          AppSpacing.gutter,
          AppSpacing.lg,
        ),
        child: FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: const Icon(Icons.arrow_forward_rounded),
          label: Text(firstRun ? 'Save and continue' : 'Save changes'),
        ),
      ),
    );
  }
}

/// "Step 1 of 3" pill with three progress dots and what comes next.
class _StepHint extends StatelessWidget {
  final int current;

  const _StepHint({required this.current});

  static const List<String> _steps = ['About you', 'Photos', 'Your size'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        for (var i = 1; i <= _steps.length; i++) ...[
          if (i > 1) const SizedBox(width: 6),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: i == current ? 22 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: i <= current ? scheme.primary : scheme.outlineVariant,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ],
        const SizedBox(width: AppSpacing.md),
        Text(
          'Step $current of ${_steps.length} · ${_steps[current - 1]}',
          style: theme.textTheme.labelMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            letterSpacing: 0.3,
          ),
        ),
        const Spacer(),
        if (current < _steps.length)
          Text(
            'Next: ${_steps[current]}',
            style: theme.textTheme.labelMedium?.copyWith(color: scheme.primary),
          ),
      ],
    );
  }
}

/// A titled card wrapping one group of inputs.
class _FormSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget child;

  const _FormSection({
    required this.icon,
    required this.title,
    required this.child,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: scheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Text(title, style: theme.textTheme.titleMedium),
              ],
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                subtitle!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            child,
          ],
        ),
      ),
    );
  }
}
