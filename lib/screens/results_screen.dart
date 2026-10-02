import 'package:flutter/material.dart';

import '../engine/size_recommender.dart';
import '../models/models.dart';
import '../services/profile_store.dart';
import '../widgets/measure_card.dart';

/// Shows the outcome of one measurement session.
///
/// Expects a [MeasurementResult] passed as the route's arguments
/// (`Navigator.pushNamed('/results', arguments: result)`). Renders one
/// [MeasureCard] per measured part, the [SizeRecommender] suggestion, a
/// shopping-only disclaimer, and actions to save the result or measure again.
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
            final units = profile?.units ?? UnitSystem.metric;
            final sex = profile?.sex ?? Sex.other;
            return _buildBody(context, result, units, sex);
          },
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    MeasurementResult result,
    UnitSystem units,
    Sex sex,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final recommendation = SizeRecommender.recommend(result, sex);

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
        _SizePanel(recommendation: recommendation),
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

class _SizePanel extends StatelessWidget {
  final SizeRecommendation recommendation;

  const _SizePanel({required this.recommendation});

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
                Text(
                  'Suggested sizes',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: scheme.onSecondaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
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
