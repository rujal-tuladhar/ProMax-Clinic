import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../engine/size_recommender.dart';
import '../models/models.dart';
import '../services/profile_store.dart';
import '../widgets/measure_card.dart';

/// Footer appended to every shared / copied summary.
const String kShareFooter = 'Measured with FitSize · processed on-device';

/// Builds the plain-text summary behind "Share my sizes" and "Copy".
///
/// One line per measured part (value in the user's units with its ± spread),
/// the suggested top/bottom sizes tagged with the fit preference, and
/// [kShareFooter]. Pure; exposed so it can be unit-tested without widgets.
String buildSizeSummary({
  required MeasurementResult result,
  required UnitSystem units,
  required SizeRecommendation recommendation,
  required FitPreference fit,
}) {
  final lines = <String>['My FitSize measurements'];
  for (final part in BodyPart.values) {
    final m = result.partFor(part);
    if (m == null) continue;
    lines.add('${part.label}: ${formatLength(m.valueCm, units)} '
        '(± ${formatLength(m.stdDevCm, units)})');
  }
  lines
    ..add('')
    ..add('Suggested sizes · ${fit.label} fit')
    ..add('Tops: ${recommendation.topSize} · '
        'Bottoms: ${recommendation.bottomSize}')
    ..add('')
    ..add(kShareFooter);
  return lines.join('\n');
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
/// [MeasureCard] per measured part, a fit-preference selector, the
/// [SizeRecommender] suggestion, share/copy actions, a shopping-only
/// disclaimer, and actions to save the result or measure again.
class ResultsScreen extends StatefulWidget {
  /// Creates the results screen; the result arrives via route arguments.
  const ResultsScreen({super.key});

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  final ProfileStore _store = ProfileStore();

  late final Future<UserProfile?> _profileFuture = _store.loadProfile();
  bool _saving = false;

  /// Fit chosen on this screen. Null until the user taps a segment, in which
  /// case the saved profile's preference (or regular) applies.
  FitPreference? _fitOverride;

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

  /// Applies [fit] immediately and persists it on the profile (best-effort:
  /// a failed write leaves the on-screen choice in place).
  Future<void> _setFit(FitPreference fit, UserProfile? profile) async {
    setState(() => _fitOverride = fit);
    if (profile == null) return;
    try {
      await _store.saveProfile(profile.copyWith(fit: fit));
    } catch (_) {
      // Preference persistence is a convenience; never block the screen.
    }
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
        child: FutureBuilder<UserProfile?>(
          future: _profileFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final profile = snapshot.data;
            return _buildBody(context, result, profile);
          },
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    MeasurementResult result,
    UserProfile? profile,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final units = profile?.units ?? UnitSystem.metric;
    final sex = profile?.sex ?? Sex.other;
    final fit = _fitOverride ?? profile?.fit ?? FitPreference.regular;
    final recommendation = SizeRecommender.recommend(result, sex, fit: fit);
    final summary = buildSizeSummary(
      result: result,
      units: units,
      recommendation: recommendation,
      fit: fit,
    );

    // Canonical chest/waist/hip order, then anything unexpected.
    final ordered = <PartMeasurement>[
      for (final part in BodyPart.values) ?result.partFor(part),
    ];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Measured from ${result.frontFrameCount} front and '
          '${result.sideFrameCount} side frames.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        for (final measurement in ordered)
          MeasureCard(measurement: measurement, units: units),
        const SizedBox(height: 12),
        _FitSelector(
          fit: fit,
          enabled: !_saving,
          onChanged: (next) => _setFit(next, profile),
        ),
        const SizedBox(height: 12),
        _SizePanel(recommendation: recommendation, fit: fit),
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
        const SizedBox(height: 16),
        Row(
          children: [
            Icon(Icons.info_outline, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Size estimates for shopping — not for medical use.',
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

class _SizePanel extends StatelessWidget {
  final SizeRecommendation recommendation;
  final FitPreference fit;

  const _SizePanel({required this.recommendation, required this.fit});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
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
              children: [
                Expanded(
                  child: _SizeBox(
                    label: 'Tops',
                    size: recommendation.topSize,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SizeBox(
                    label: 'Bottoms',
                    size: recommendation.bottomSize,
                  ),
                ),
              ],
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

class _SizeBox extends StatelessWidget {
  final String label;
  final String size;

  const _SizeBox({required this.label, required this.size});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
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
        ],
      ),
    );
  }
}
