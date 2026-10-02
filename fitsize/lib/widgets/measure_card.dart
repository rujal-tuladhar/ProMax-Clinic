import 'package:flutter/material.dart';

import '../models/models.dart';

/// Card that presents a single [PartMeasurement]: the body part name, the
/// value in the user's preferred units, the ± spread across frames, and a
/// colour-coded confidence chip.
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
    final confidence = measurement.confidence;
    final chipColor = _confidenceColor(context, confidence);
    final retakeRecommended = confidence < 0.4;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  foregroundColor: scheme.onPrimaryContainer,
                  child: Icon(_iconFor(measurement.part)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        measurement.part.label,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text.rich(
                        TextSpan(
                          text: formatLength(measurement.valueCm, units),
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                          children: [
                            TextSpan(
                              text:
                                  '  ± ${formatLength(measurement.stdDevCm, units)}',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                _ConfidenceChip(confidence: confidence, color: chipColor),
              ],
            ),
            if (retakeRecommended) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.replay, size: 16, color: chipColor),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Low confidence — retake recommended.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: chipColor),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  static IconData _iconFor(BodyPart part) => switch (part) {
        BodyPart.chest => Icons.accessibility_new,
        BodyPart.waist => Icons.straighten,
        BodyPart.hip => Icons.airline_seat_recline_normal,
      };

  static Color _confidenceColor(BuildContext context, double confidence) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (confidence >= 0.7) {
      return dark ? Colors.green.shade400 : Colors.green.shade700;
    }
    if (confidence >= 0.4) {
      return dark ? Colors.amber.shade400 : Colors.amber.shade800;
    }
    return Theme.of(context).colorScheme.error;
  }
}

class _ConfidenceChip extends StatelessWidget {
  final double confidence;
  final Color color;

  const _ConfidenceChip({required this.confidence, required this.color});

  @override
  Widget build(BuildContext context) {
    final label = confidence >= 0.7
        ? 'High'
        : confidence >= 0.4
            ? 'Medium'
            : 'Low';
    final percent = (confidence.clamp(0.0, 1.0) * 100).round();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
          Text(
            '$percent%',
            style:
                Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
