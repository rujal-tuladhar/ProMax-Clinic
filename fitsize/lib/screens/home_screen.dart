import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/profile_store.dart';
import '../theme/app_theme.dart';

/// Landing screen: a hero with the two measure CTAs, the privacy badge, the
/// latest measurement as big-number tiles, a three-step "how it works"
/// strip, compact setup tips, past measurements, and the profile row.
class HomeScreen extends StatefulWidget {
  /// Creates the home screen.
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ProfileStore _store = ProfileStore();

  UserProfile? _profile;
  List<MeasurementResult> _history = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profile = await _store.loadProfile();
    final history = await _store.loadHistory();
    if (!mounted) return;
    setState(() {
      _profile = profile;
      _history = history;
      _loading = false;
    });
  }

  Future<void> _startMeasurement() async {
    await Navigator.of(context).pushNamed('/capture');
    // A result may have been saved while we were away.
    await _load();
  }

  Future<void> _startPrecisionMeasurement() async {
    await Navigator.of(context).pushNamed('/capture-turn');
    await _load();
  }

  Future<void> _editProfile() async {
    await Navigator.of(context).pushNamed('/onboarding');
    await _load();
  }

  Future<void> _openMySizes(MeasurementResult result) async {
    await Navigator.of(context).pushNamed('/my-sizes', arguments: result);
    // The fit preference can be changed on that screen.
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final units = _profile?.units ?? UnitSystem.metric;
    final latest = _history.isEmpty ? null : _history.first;

    return Scaffold(
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.gutter,
                  AppSpacing.sm,
                  AppSpacing.gutter,
                  AppSpacing.xxl,
                ),
                children: [
                  _TopBar(onProfile: _editProfile),
                  const SizedBox(height: AppSpacing.lg),
                  _Hero(
                    onMeasure: _startMeasurement,
                    onPrecisionMeasure: _startPrecisionMeasurement,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  const _PrivacyBadge(),
                  const SizedBox(height: AppSpacing.xl),
                  if (latest != null) ...[
                    _SectionHeader(
                      title: 'Latest measurements',
                      trailing: _formatDate(latest.timestamp),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _LatestTiles(result: latest, units: units),
                    const SizedBox(height: AppSpacing.md),
                    _BrandSizesCard(onTap: () => _openMySizes(latest)),
                  ] else
                    const _EmptyState(),
                  const SizedBox(height: AppSpacing.xl),
                  const _SectionHeader(title: 'How it works'),
                  const SizedBox(height: AppSpacing.md),
                  const _HowItWorks(),
                  const SizedBox(height: AppSpacing.xl),
                  const _SectionHeader(title: 'Before you measure'),
                  const SizedBox(height: AppSpacing.md),
                  const _TipChips(),
                  if (_history.length > 1) ...[
                    const SizedBox(height: AppSpacing.xl),
                    const TapeDivider(),
                    const SizedBox(height: AppSpacing.lg),
                    const _SectionHeader(title: 'History'),
                    const SizedBox(height: AppSpacing.md),
                    Card(
                      child: Column(
                        children: [
                          for (final (i, result)
                              in _history.skip(1).indexed) ...[
                            if (i > 0) const Divider(indent: 18, endIndent: 18),
                            _HistoryTile(result: result, units: units),
                          ],
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.xl),
                  const _SectionHeader(title: 'Settings'),
                  const SizedBox(height: AppSpacing.md),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.person_outline_rounded),
                      title: const Text('Your profile'),
                      subtitle: Text(_profileSummary()),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: _editProfile,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  String _profileSummary() {
    final profile = _profile;
    if (profile == null) return 'Not set up yet';
    final height = formatLength(profile.heightCm, profile.units);
    final sex = switch (profile.sex) {
      Sex.female => 'Female',
      Sex.male => 'Male',
      Sex.other => 'Other',
    };
    return 'Height $height · $sex';
  }
}

const List<String> _monthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _formatDate(DateTime t) {
  final local = t.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '${local.day} ${_monthNames[local.month - 1]} ${local.year}, $hh:$mm';
}

/// Brand row: mark + wordmark on the left, profile button on the right.
class _TopBar extends StatelessWidget {
  final VoidCallback onProfile;

  const _TopBar({required this.onProfile});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: scheme.primary,
            borderRadius: BorderRadius.circular(AppRadii.chip),
          ),
          child: Icon(Icons.straighten, size: 20, color: scheme.onPrimary),
        ),
        const SizedBox(width: AppSpacing.md),
        Text(
          'FitSize',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
          ),
        ),
        const Spacer(),
        IconButton(
          tooltip: 'Your profile',
          onPressed: onProfile,
          icon: const Icon(Icons.person_outline_rounded),
          style: IconButton.styleFrom(
            backgroundColor: scheme.surfaceContainerHigh,
            foregroundColor: scheme.onSurface,
          ),
        ),
      ],
    );
  }
}

/// Gradient teal hero with the two measure CTAs.
class _Hero extends StatelessWidget {
  final VoidCallback onMeasure;
  final VoidCallback onPrecisionMeasure;

  const _Hero({required this.onMeasure, required this.onPrecisionMeasure});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final top = isDark ? const Color(0xFF13584B) : const Color(0xFF187F6C);
    final bottom = isDark ? const Color(0xFF0A3A31) : AppColors.tealDeep;
    const ink = Colors.white;

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.card + 4),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [top, bottom],
          ),
        ),
        child: Stack(
          children: [
            // Faint tape ticks along the bottom edge — the brand motif.
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: TapeDivider(
                height: 18,
                spacing: 7,
                color: Color(0x33FFFFFF),
              ),
            ),
            Positioned(
              right: -28,
              top: -28,
              child: Container(
                width: 150,
                height: 150,
                decoration: const BoxDecoration(
                  color: Color(0x14FFFFFF),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 24, 22, 30),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'CHEST · WAIST · HIP',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: ink.withValues(alpha: 0.78),
                      letterSpacing: 1.6,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Know your size\nbefore you buy',
                    style: theme.textTheme.headlineLarge?.copyWith(color: ink),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Three measurements from guided photos, computed '
                    'entirely on your phone.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: ink.withValues(alpha: 0.85),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: onMeasure,
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: const Text('Quick measure · 2 photos'),
                      style: FilledButton.styleFrom(
                        backgroundColor: ink,
                        foregroundColor: AppColors.tealDeep,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: onPrecisionMeasure,
                      icon: const Icon(Icons.threesixty_rounded),
                      label: const Text('Precision measure · full turn'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: ink,
                        side: BorderSide(
                          color: ink.withValues(alpha: 0.55),
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Row(
                    children: [
                      Icon(
                        Icons.timer_outlined,
                        size: 15,
                        color: ink.withValues(alpha: 0.75),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Quick takes about a minute. Precision adds a slow '
                          'turn for more angles and tighter numbers.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: ink.withValues(alpha: 0.75),
                          ),
                        ),
                      ),
                    ],
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

/// "On-device only" promise, shown right under the hero.
class _PrivacyBadge extends StatelessWidget {
  const _PrivacyBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(AppRadii.field),
      ),
      child: Row(
        children: [
          Icon(
            Icons.lock_outline_rounded,
            size: 18,
            color: scheme.onSecondaryContainer,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'On-device only · photos never leave your phone',
              style: theme.textTheme.labelLarge?.copyWith(
                color: scheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final String? trailing;

  const _SectionHeader({required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (trailing != null)
          Text(
            trailing!,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }
}

/// Three big-number tiles for the latest result.
class _LatestTiles extends StatelessWidget {
  final MeasurementResult result;
  final UnitSystem units;

  const _LatestTiles({required this.result, required this.units});

  @override
  Widget build(BuildContext context) {
    final tiles = <PartMeasurement>[
      for (final part in BodyPart.values) ?result.partFor(part),
    ];
    if (tiles.isEmpty) return const _EmptyState();
    return Row(
      children: [
        for (final (i, m) in tiles.indexed) ...[
          if (i > 0) const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: _BigNumberTile(measurement: m, units: units),
          ),
        ],
      ],
    );
  }
}

class _BigNumberTile extends StatelessWidget {
  final PartMeasurement measurement;
  final UnitSystem units;

  const _BigNumberTile({required this.measurement, required this.units});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final extras = FitSizeColors.of(context);
    final c = measurement.confidence;
    final dot = c >= 0.7
        ? extras.good
        : c >= 0.4
        ? extras.caution
        : scheme.error;
    final value = units == UnitSystem.metric
        ? measurement.valueCm
        : cmToInches(measurement.valueCm);
    final unit = units == UnitSystem.metric ? 'cm' : 'in';

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    measurement.part.label.toUpperCase(),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      letterSpacing: 1.1,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value.toStringAsFixed(1),
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: scheme.onSurface,
                ),
              ),
            ),
            Text(
              unit,
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Entry to the brand size passport (`/my-sizes`); shown once a result
/// exists.
class _BrandSizesCard extends StatelessWidget {
  final VoidCallback onTap;

  const _BrandSizesCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(AppRadii.chip),
                ),
                child: Icon(
                  Icons.storefront_rounded,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Your size at 12 brands',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Nike, Zara, H&M, Uniqlo and more — from their '
                      'published charts.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Icon(
                Icons.chevron_right_rounded,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(AppRadii.chip),
              ),
              child: Icon(
                Icons.auto_awesome_rounded,
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'No measurements yet',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Your first one takes about a minute.',
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
    );
  }
}

/// Three numbered steps in a row.
class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  static const List<(IconData, String, String)> _steps = [
    (
      Icons.phone_iphone_rounded,
      'Prop the phone',
      'Upright, hip height, 2–3 m away.',
    ),
    (
      Icons.accessibility_new_rounded,
      'Strike the pose',
      'Follow the voice and outline guide.',
    ),
    (Icons.checkroom_rounded, 'Get your size', 'Chest, waist, hip and a size.'),
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, step) in _steps.indexed) ...[
          if (i > 0) const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: _StepCard(
              index: i + 1,
              icon: step.$1,
              title: step.$2,
              body: step.$3,
            ),
          ),
        ],
      ],
    );
  }
}

class _StepCard extends StatelessWidget {
  final int index;
  final IconData icon;
  final String title;
  final String body;

  const _StepCard({
    required this.index,
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '$index',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Spacer(),
                Icon(icon, size: 20, color: scheme.primary),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text(title, style: theme.textTheme.titleSmall, maxLines: 2),
            const SizedBox(height: 2),
            Text(
              body,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Setup tips as compact icon chips.
class _TipChips extends StatelessWidget {
  const _TipChips();

  static const List<(IconData, String)> _tips = [
    (Icons.checkroom_rounded, 'Tight clothing or underwear'),
    (Icons.face_retouching_natural_rounded, 'Hair up, off the shoulders'),
    (Icons.wallpaper_rounded, 'Plain, uncluttered background'),
    (Icons.smartphone_rounded, 'Phone upright at hip height'),
    (Icons.social_distance_rounded, 'Stand 2–3 m back, whole body in frame'),
    (Icons.group_outlined, 'Or let a friend hold the phone'),
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        for (final (icon, text) in _tips)
          Chip(avatar: Icon(icon), label: Text(text)),
      ],
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final MeasurementResult result;
  final UnitSystem units;

  const _HistoryTile({required this.result, required this.units});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = [
      for (final part in BodyPart.values)
        if (result.partFor(part) case final m?)
          '${m.part.label} ${formatLength(m.valueCm, units)}',
    ];
    return ListTile(
      leading: const Icon(Icons.history_rounded),
      title: Text(_formatDate(result.timestamp)),
      subtitle: Text(
        parts.isEmpty ? 'No parts measured' : parts.join(' · '),
        style: theme.textTheme.bodyMedium?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
