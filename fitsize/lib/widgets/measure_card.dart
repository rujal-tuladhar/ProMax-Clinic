import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme/app_theme.dart';

/// Card that presents a single [PartMeasurement]: the body part name, the
/// value as a large tabular number with its unit, the ± spread across
/// frames, and a colour-coded confidence chip.
///
/// Confidence colouring:
/// * `>= 0.7` — green (good agreement between frames)
/// * `>= 0.4` — amber (usable, but take it with a grain of salt)
/// * `< 0.4`  — red, plus a "retake recommended" hint
class MeasureCard extends StatelessWidget {
  /// The measurement to display.
  final PartMeasurement measurement;

  /// Units the value is formatted in (cm or inches).
  final UnitSystem units;

  /// Creates a card for one measured body part.
  const MeasureCard({
    super.key,
    required this.measurement,
    this.units = UnitSystem.metric,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tone = _ConfidenceTone.of(context, measurement.confidence);
    final retakeRecommended = measurement.confidence < 0.4;

    final valueText = _numberText(measurement.valueCm);
    final spreadText = formatLength(measurement.stdDevCm, units);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _PartBadge(part: measurement.part),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    measurement.part.label.toUpperCase(),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                _ConfidenceChip(confidence: measurement.confidence, tone: tone),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      valueText,
                      style: theme.textTheme.displayMedium?.copyWith(
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _unitLabel,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                _SpreadPill(text: '± $spreadText'),
              ],
            ),
            if (retakeRecommended) ...[
              const SizedBox(height: AppSpacing.md),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(AppRadii.chip),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.replay_rounded,
                      size: 18,
                      color: scheme.onErrorContainer,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        'Low confidence — retake recommended.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onErrorContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String get _unitLabel => units == UnitSystem.metric ? 'cm' : 'in';

  String _numberText(double cm) {
    final v = units == UnitSystem.metric ? cm : cmToInches(cm);
    return v.toStringAsFixed(1);
  }
}

/// Small tinted square with the body-part icon.
class _PartBadge extends StatelessWidget {
  final BodyPart part;

  const _PartBadge({required this.part});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(AppRadii.chip),
      ),
      child: Icon(_iconFor(part), size: 20, color: scheme.onPrimaryContainer),
    );
  }

  static IconData _iconFor(BodyPart part) => switch (part) {
    BodyPart.chest => Icons.accessibility_new_rounded,
    BodyPart.waist => Icons.straighten_rounded,
    BodyPart.hip => Icons.airline_seat_recline_normal_rounded,
  };
}

/// The "± spread" pill next to the big number.
class _SpreadPill extends StatelessWidget {
  final String text;

  const _SpreadPill({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: scheme.onSurfaceVariant,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// Foreground/background pair for one confidence band.
class _ConfidenceTone {
  final Color fg;
  final Color bg;
  final String label;

  const _ConfidenceTone(this.fg, this.bg, this.label);

  static _ConfidenceTone of(BuildContext context, double confidence) {
    final extras = FitSizeColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (confidence >= 0.7) {
      return _ConfidenceTone(extras.good, extras.goodContainer, 'High');
    }
    if (confidence >= 0.4) {
      return _ConfidenceTone(extras.caution, extras.cautionContainer, 'Medium');
    }
    return _ConfidenceTone(scheme.error, scheme.errorContainer, 'Low');
  }
}

class _ConfidenceChip extends StatelessWidget {
  final double confidence;
  final _ConfidenceTone tone;

  const _ConfidenceChip({required this.confidence, required this.tone});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final percent = (confidence.clamp(0.0, 1.0) * 100).round();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: tone.bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: tone.fg, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            '${tone.label} · $percent%',
            style: theme.textTheme.labelMedium?.copyWith(
              color: tone.fg,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
