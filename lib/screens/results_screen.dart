import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../engine/size_recommender.dart';
import '../models/models.dart';
import '../services/profile_store.dart';
import '../theme/app_theme.dart';
import '../widgets/measure_card.dart';

/// Footer appended to every shared / copied summary.
const String kShareFooter = 'Measured with FitSize · processed on-device';

/// Shopping-only disclaimer (wording pinned by the UI contract).
const String kSizeDisclaimer =
    'Size estimates for shopping — not for medical use.';

/// Label of the button that opens the brand size passport.
const String kBrandSizesCta = 'Your size at 12 brands →';

/// Route of the brand size passport; takes the [MeasurementResult] as its
/// argument.
const String kMySizesRoute = '/my-sizes';

/// Accepted range for a tape reading in the correction dialog, cm.
const double kMinTapeCm = 10;
const double kMaxTapeCm = 300;

/// The parts of [result] in display order: circumferences first (chest,
/// waist, hip, neck, thigh), then lengths (shoulder, sleeve, shirt sleeve,
/// inseam), each group in [BodyPart] declaration order. Parts the result does
/// not contain are skipped.
List<PartMeasurement> orderedParts(MeasurementResult result) {
  final present = <PartMeasurement>[
    for (final part in BodyPart.values) ?result.partFor(part),
  ];
  return [
    ...present.where((m) => m.part.isCircumference),
    ...present.where((m) => !m.part.isCircumference),
  ];
}

/// Text of the privacy receipt: every captured frame was analysed on this
/// phone and none was uploaded or kept.
String privacyReceiptText(MeasurementResult result) =>
    'Photos processed: ${result.frontFrameCount + result.sideFrameCount} · '
    'Uploaded: 0 · Stored: 0';

/// The profile offset to store after a tape correction.
///
/// The contract defines the offset as `tape − app value`, where the app
/// value is the RAW engine estimate. The engine already adds the profile's
/// current offset to every value it reports, so the number on screen is
/// `raw + previousOffset` and the raw value is `displayed − previousOffset`;
/// hence `tape − raw = previousOffset + (tape − displayed)`. With no offset in
/// force (the usual first correction) this is simply `tape − displayed`, and
/// correcting the same part twice converges on `tape − raw` rather than
/// double-counting.
double correctedOffsetCm({
  required double previousOffsetCm,
  required double displayedCm,
  required double tapeCm,
}) =>
    previousOffsetCm + (tapeCm - displayedCm);

/// [result] with the parts in [tapeCm] replaced by the user's tape readings.
///
/// A corrected part keeps its camera spread and confidence (they describe
/// the scan that was corrected) but is no longer `derived` — it is now a
/// direct measurement. Other parts and metadata are unchanged; the same
/// object is returned when there is nothing to apply.
MeasurementResult applyTapeCorrections(
  MeasurementResult result,
  Map<BodyPart, double> tapeCm,
) {
  if (tapeCm.isEmpty) return result;
  return MeasurementResult(
    parts: [
      for (final m in result.parts)
        tapeCm.containsKey(m.part)
            ? PartMeasurement(
                part: m.part,
                valueCm: tapeCm[m.part]!,
                stdDevCm: m.stdDevCm,
                confidence: m.confidence,
              )
            : m,
    ],
    scaleCmPerPx: result.scaleCmPerPx,
    frontFrameCount: result.frontFrameCount,
    sideFrameCount: result.sideFrameCount,
    timestamp: result.timestamp,
  );
}

/// Builds the plain-text summary behind "Share my sizes" and "Copy".
///
/// One line per measured part in display order (value in the user's units
/// with its ± spread, or "corrected with a tape" for parts in [corrected],
/// plus "estimated" for derived parts), the suggested top/bottom sizes tagged
/// with the fit preference, the garment line when [garments] has one, and
/// [kShareFooter]. Pure; exposed so it can be unit-tested without widgets.
String buildSizeSummary({
  required MeasurementResult result,
  required UnitSystem units,
  required SizeRecommendation recommendation,
  required FitPreference fit,
  GarmentSizes garments = GarmentSizes.none,
  Set<BodyPart> corrected = const {},
}) {
  final lines = <String>['My FitSize measurements'];
  for (final m in orderedParts(result)) {
    final notes = <String>[
      if (corrected.contains(m.part))
        'corrected with a tape'
      else
        '± ${formatLength(m.stdDevCm, units)}',
      if (m.derived) 'estimated',
    ];
    lines.add('${m.part.label}: ${formatLength(m.valueCm, units)} '
        '(${notes.join(', ')})');
  }
  lines
    ..add('')
    ..add('Suggested sizes · ${fit.label} fit')
    ..add('Tops: ${recommendation.topSize} · '
        'Bottoms: ${recommendation.bottomSize}');
  final garmentLine = garmentLineText(garments);
  if (garmentLine != null) lines.add(garmentLine);
  lines
    ..add('')
    ..add(kShareFooter);
  return lines.join('\n');
}

/// `'Jeans W34 L32 · Shirt 15½ × 34'` (either half alone when the other is
/// missing); null when neither garment could be sized.
String? garmentLineText(GarmentSizes garments) {
  if (!garments.hasAny) return null;
  return [
    if (garments.jeans != null) 'Jeans ${garments.jeans}',
    if (garments.shirt != null) 'Shirt ${garments.shirt}',
  ].join(' · ');
}

/// One-line explanation of what the selected [FitPreference] does.
String fitExplanation(FitPreference fit) => switch (fit) {
      FitPreference.slim =>
        'Slim picks the smaller size when you are between sizes',
      FitPreference.regular => 'Regular follows the size chart as measured',
      FitPreference.relaxed =>
        'Relaxed picks the larger size when you are between sizes',
    };

/// Shows the outcome of one measurement session.
///
/// Expects a [MeasurementResult] passed as the route's arguments
/// (`Navigator.pushNamed('/results', arguments: result)`). Renders one
/// [MeasureCard] per measured part (circumferences, then lengths; derived
/// parts tagged "estimated"), a fit-preference selector, the probabilistic
/// [SizeRecommender] suggestion with the garment line and a link to the brand
/// size passport, share/copy actions, a privacy receipt, the shopping-only
/// disclaimer, and actions to save the result or measure again.
///
/// Tapping a card opens the "Correct with a tape" dialog: the entered tape
/// value replaces the displayed value (marked "✎ corrected") and the
/// difference is stored on the profile as `offsetsCm[part]`, which the
/// engine adds to every future scan of that part.
class ResultsScreen extends StatefulWidget {
  /// Creates the results screen; the result arrives via route arguments.
  const ResultsScreen({super.key});

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  final ProfileStore _store = ProfileStore();

  UserProfile? _profile;
  bool _profileLoaded = false;
  bool _saving = false;

  /// Fit chosen on this screen. Null until the user taps a segment, in which
  /// case the saved profile's preference (or regular) applies.
  FitPreference? _fitOverride;

  /// Tape readings entered on this screen, cm, per part. Applied to the
  /// displayed result (and to what "Save & done" stores).
  final Map<BodyPart, double> _tapeCm = {};

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    UserProfile? profile;
    try {
      profile = await _store.loadProfile();
    } catch (_) {
      profile = null;
    }
    if (!mounted) return;
    setState(() {
      _profile = profile;
      _profileLoaded = true;
    });
  }

  Future<void> _saveAndDone(MeasurementResult result) async {
    setState(() => _saving = true);
    await _store.addResult(result);
    if (!mounted) return;
    Navigator.of(context).popUntil(ModalRoute.withName('/'));
  }

  void _measureAgain() {
    final navigator = Navigator.of(context);
    navigator.popUntil(ModalRoute.withName('/'));
    navigator.pushNamed('/capture');
  }

  void _openBrandSizes(MeasurementResult result) {
    Navigator.of(context).pushNamed(kMySizesRoute, arguments: result);
  }

  /// Applies [fit] immediately and persists it on the profile (best-effort:
  /// a failed write leaves the on-screen choice in place).
  Future<void> _setFit(FitPreference fit) async {
    setState(() => _fitOverride = fit);
    final profile = _profile;
    if (profile == null) return;
    final updated = profile.copyWith(fit: fit);
    setState(() => _profile = updated);
    try {
      await _store.saveProfile(updated);
    } catch (_) {
      // Preference persistence is a convenience; never block the screen.
    }
  }

  /// Opens the tape dialog for [shown] (the measurement as currently
  /// displayed) and, on save, corrects the display and the profile offset.
  Future<void> _correct(PartMeasurement shown) async {
    final units = _profile?.units ?? UnitSystem.metric;
    final messenger = ScaffoldMessenger.of(context);
    final tapeCm = await showDialog<double>(
      context: context,
      builder: (_) => _TapeDialog(measurement: shown, units: units),
    );
    if (tapeCm == null || !mounted) return;

    final part = shown.part;
    final profile = _profile;
    final previousOffset = profile?.offsetsCm[part] ?? 0;
    final newOffset = correctedOffsetCm(
      previousOffsetCm: previousOffset,
      displayedCm: shown.valueCm,
      tapeCm: tapeCm,
    );
    final updatedProfile = profile?.copyWith(
      offsetsCm: {...profile.offsetsCm, part: newOffset},
    );

    setState(() {
      _tapeCm[part] = tapeCm;
      if (updatedProfile != null) _profile = updatedProfile;
    });

    var persisted = false;
    if (updatedProfile != null) {
      try {
        await _store.saveProfile(updatedProfile);
        persisted = true;
      } catch (_) {
        persisted = false;
      }
    }
    if (!mounted) return;

    final delta = tapeCm - shown.valueCm;
    final deltaText =
        '${delta < 0 ? '−' : '+'}${formatLength(delta.abs(), units)}';
    messenger.showSnackBar(SnackBar(
      content: Text(persisted
          ? '${part.label} set to ${formatLength(tapeCm, units)} · '
              'future scans adjusted by $deltaText'
          : '${part.label} set to ${formatLength(tapeCm, units)} on this '
              'result. The correction could not be saved for future scans.'),
    ));
  }

  Future<void> _share(BuildContext buttonContext, String summary) async {
    final messenger = ScaffoldMessenger.of(context);
    // Anchor the iPad/macOS popover to the button; ignored elsewhere.
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box == null || !box.hasSize
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    try {
      await SharePlus.instance.share(ShareParams(
        text: summary,
        subject: 'My FitSize sizes',
        sharePositionOrigin: origin,
      ));
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(
        content: Text('Sharing is not available on this device — '
            'use Copy instead.'),
      ));
    }
  }

  Future<void> _copy(String summary) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: summary));
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('Copied to clipboard')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final args = ModalRoute.of(context)?.settings.arguments;
    final result = args is MeasurementResult ? args : null;

    if (result == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Results')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('No measurement to show.'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => Navigator.of(context)
                    .popUntil(ModalRoute.withName('/')),
                child: const Text('Back to home'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Your measurements')),
      body: SafeArea(
        child: _profileLoaded
            ? _buildBody(context, result)
            : const Center(child: CircularProgressIndicator()),
      ),
    );
  }

  Widget _buildBody(BuildContext context, MeasurementResult original) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final profile = _profile;
    final units = profile?.units ?? UnitSystem.metric;
    final sex = profile?.sex ?? Sex.other;
    final fit = _fitOverride ?? profile?.fit ?? FitPreference.regular;

    // Everything below works on the result as displayed, i.e. with any tape
    // corrections made on this screen applied.
    final result = applyTapeCorrections(original, _tapeCm);
    final recommendation =
        SizeRecommender.recommendWithProbabilities(result, sex, fit: fit);
    final garments = SizeRecommender.garmentSizes(result, fit: fit);
    final summary = buildSizeSummary(
      result: result,
      units: units,
      recommendation: recommendation,
      fit: fit,
      garments: garments,
      corrected: _tapeCm.keys.toSet(),
    );
    final ordered = orderedParts(result);

    final captionStyle =
        theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Measured from ${result.frontFrameCount} front and '
          '${result.sideFrameCount} side frames.',
          style: captionStyle,
        ),
        const SizedBox(height: 4),
        Text(
          'Tap a measurement to correct it with a tape.',
          style: captionStyle,
        ),
        const SizedBox(height: 8),
        for (final measurement in ordered)
          MeasureCard(
            measurement: measurement,
            units: units,
            corrected: _tapeCm.containsKey(measurement.part),
            onTap: _saving ? null : () => _correct(measurement),
          ),
        const SizedBox(height: 12),
        _FitSelector(
          fit: fit,
          enabled: !_saving,
          onChanged: _setFit,
        ),
        const SizedBox(height: 12),
        _SizePanel(
          recommendation: recommendation,
          fit: fit,
          garments: garments,
          onBrandSizes: _saving ? null : () => _openBrandSizes(result),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Builder(
                builder: (buttonContext) => FilledButton.tonalIcon(
                  onPressed:
                      _saving ? null : () => _share(buttonContext, summary),
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Share my sizes'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: 'Copy',
              onPressed: _saving ? null : () => _copy(summary),
              icon: const Icon(Icons.copy_rounded),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _PrivacyReceipt(result: result),
        const SizedBox(height: 16),
        Row(
          children: [
            Icon(Icons.info_outline, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                kSizeDisclaimer,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _saving ? null : () => _saveAndDone(result),
          icon: const Icon(Icons.check),
          label: const Text('Save & done'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _saving ? null : _measureAgain,
          icon: const Icon(Icons.replay),
          label: const Text('Measure again'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// "Correct with a tape": numeric entry in the profile units, pre-filled
/// with the displayed value. Pops the tape reading in cm, or null on cancel.
class _TapeDialog extends StatefulWidget {
  final PartMeasurement measurement;
  final UnitSystem units;

  const _TapeDialog({required this.measurement, required this.units});

  @override
  State<_TapeDialog> createState() => _TapeDialogState();
}

class _TapeDialogState extends State<_TapeDialog> {
  late final TextEditingController _controller;
  String? _error;

  bool get _metric => widget.units == UnitSystem.metric;
  String get _unit => _metric ? 'cm' : 'in';

  @override
  void initState() {
    super.initState();
    final shown = _metric
        ? widget.measurement.valueCm
        : cmToInches(widget.measurement.valueCm);
    _controller = TextEditingController(text: shown.toStringAsFixed(1));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The field's value in cm, or null when it is not a positive number.
  double? _parseCm(String raw) {
    final value = double.tryParse(raw.trim().replaceAll(',', '.'));
    if (value == null || !value.isFinite || value <= 0) return null;
    return _metric ? value : value * 2.54;
  }

  void _submit() {
    final cm = _parseCm(_controller.text);
    if (cm == null) {
      setState(() => _error = 'Enter a number');
      return;
    }
    if (cm < kMinTapeCm || cm > kMaxTapeCm) {
      setState(() => _error = 'Enter a value between '
          '${formatLength(kMinTapeCm, widget.units)} and '
          '${formatLength(kMaxTapeCm, widget.units)}');
      return;
    }
    Navigator.of(context).pop(cm);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = widget.measurement.part.label;
    return AlertDialog(
      title: const Text('Correct with a tape'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Measure your ${label.toLowerCase()} with a tape and enter the '
            'reading. FitSize will show it here and use the difference to '
            'calibrate your future scans.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpacing.lg),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
            ],
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            decoration: InputDecoration(
              labelText: 'Tape measurement',
              suffixText: _unit,
              helperText: 'FitSize measured '
                  '${formatLength(widget.measurement.valueCm, widget.units)}',
              errorText: _error,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Slim / Regular / Relaxed segmented control with a one-line explanation
/// of the selected option.
class _FitSelector extends StatelessWidget {
  final FitPreference fit;
  final bool enabled;
  final ValueChanged<FitPreference> onChanged;

  const _FitSelector({
    required this.fit,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Fit preference',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        SegmentedButton<FitPreference>(
          segments: [
            for (final option in FitPreference.values)
              ButtonSegment<FitPreference>(
                value: option,
                label: Text(option.label),
              ),
          ],
          selected: {fit},
          showSelectedIcon: false,
          expandedInsets: EdgeInsets.zero,
          onSelectionChanged:
              enabled ? (selection) => onChanged(selection.first) : null,
        ),
        const SizedBox(height: 6),
        Text(
          fitExplanation(fit),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// Generic size letters with their probabilities, the garment line and the
/// link to the brand size passport.
class _SizePanel extends StatelessWidget {
  final SizeRecommendation recommendation;
  final FitPreference fit;
  final GarmentSizes garments;
  final VoidCallback? onBrandSizes;

  const _SizePanel({
    required this.recommendation,
    required this.fit,
    required this.garments,
    required this.onBrandSizes,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final garmentLine = garmentLineText(garments);
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.checkroom, color: scheme.onSecondaryContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Suggested sizes',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: scheme.onSecondaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '${fit.label} fit',
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: scheme.onSecondaryContainer),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _SizeBox(
                    label: 'Tops',
                    size: recommendation.topSize,
                    detail: SizeRecommender.formatProbabilities(
                      recommendation.topProbabilities,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SizeBox(
                    label: 'Bottoms',
                    size: recommendation.bottomSize,
                    detail: SizeRecommender.formatProbabilities(
                      recommendation.bottomProbabilities,
                    ),
                  ),
                ),
              ],
            ),
            if (garmentLine != null) ...[
              const SizedBox(height: 12),
              _GarmentLine(text: garmentLine),
            ],
            const SizedBox(height: 12),
            FilledButton(
              onPressed: onBrandSizes,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text(kBrandSizesCta),
            ),
            const SizedBox(height: 10),
            Text(
              'Charts vary between brands — check the shop\'s size guide '
              'against your measurements above when in doubt.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSecondaryContainer),
            ),
          ],
        ),
      ),
    );
  }
}

/// `Jeans W34 L32 · Shirt 15½ × 34` inside the size panel.
class _GarmentLine extends StatelessWidget {
  final String text;

  const _GarmentLine({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Garment sizes',
            style: theme.textTheme.labelMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            text,
            style: theme.textTheme.titleMedium?.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _SizeBox extends StatelessWidget {
  final String label;
  final String size;

  /// Probability text under the letter (`'M (78%) · L (22%)'`); empty hides
  /// the line.
  final String detail;

  const _SizeBox({
    required this.label,
    required this.size,
    this.detail = '',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            size,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: scheme.primary,
            ),
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// "Privacy receipt": how many frames were analysed, none uploaded or kept.
class _PrivacyReceipt extends StatelessWidget {
  final MeasurementResult result;

  const _PrivacyReceipt({required this.result});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(AppRadii.chip),
              ),
              child: Icon(
                Icons.lock_outline_rounded,
                size: 20,
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Privacy receipt',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    privacyReceiptText(result),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
