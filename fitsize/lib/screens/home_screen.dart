import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/profile_store.dart';

/// Landing screen: the "Measure me" call to action, setup tips that make the
/// photos accurate, the latest measurement at a glance, past measurements,
/// and a row to edit the profile.
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final units = _profile?.units ?? UnitSystem.metric;
    final latest = _history.isEmpty ? null : _history.first;

    return Scaffold(
      appBar: AppBar(title: const Text('FitSize')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _HeroCard(
                    onMeasure: _startMeasurement,
                    onPrecisionMeasure: _startPrecisionMeasurement,
                  ),
                  const SizedBox(height: 20),
                  if (latest != null) ...[
                    _SectionHeader(
                      title: 'Latest measurements',
                      subtitle: _formatDate(latest.timestamp),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        for (final part in BodyPart.values)
                          if (latest.partFor(part) case final m?)
                            Expanded(
                              child: _SummaryTile(
                                measurement: m,
                                units: units,
                              ),
                            ),
                      ],
                    ),
                    const SizedBox(height: 20),
                  ] else ...[
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Icon(Icons.auto_awesome, color: scheme.primary),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'No measurements yet — your first one takes '
                                'about a minute.',
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                  const _SectionHeader(title: 'Before you measure'),
                  const SizedBox(height: 8),
                  const _TipsCard(),
                  if (_history.length > 1) ...[
                    const SizedBox(height: 20),
                    const _SectionHeader(title: 'History'),
                    const SizedBox(height: 4),
                    for (final result in _history.skip(1))
                      _HistoryTile(result: result, units: units),
                  ],
                  const SizedBox(height: 20),
                  const _SectionHeader(title: 'Settings'),
                  const SizedBox(height: 4),
                  Card(
                    margin: EdgeInsets.zero,
                    child: ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: const Text('Your profile'),
                      subtitle: Text(_profileSummary()),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _editProfile,
                    ),
                  ),
                  const SizedBox(height: 24),
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
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _formatDate(DateTime t) {
  final local = t.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '${local.day} ${_monthNames[local.month - 1]} ${local.year}, $hh:$mm';
}

class _HeroCard extends StatelessWidget {
  final VoidCallback onMeasure;
  final VoidCallback onPrecisionMeasure;

  const _HeroCard({
    required this.onMeasure,
    required this.onPrecisionMeasure,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.straighten,
                    size: 36, color: scheme.onPrimaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Know your size before you buy',
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Chest, waist and hip, processed entirely on your phone.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onPrimaryContainer),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onMeasure,
                icon: const Icon(Icons.camera_alt_outlined),
                label: const Text('Quick measure · 2 photos'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onPrecisionMeasure,
                icon: const Icon(Icons.threesixty),
                label: const Text('Precision measure · full turn'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: scheme.onPrimaryContainer,
                  side: BorderSide(
                    color: scheme.onPrimaryContainer.withValues(alpha: 0.5),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Precision takes a slow turn with more angles — more accurate, '
              'about a minute longer.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onPrimaryContainer.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;

  const _SectionHeader({required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          title,
          style: theme.textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        if (subtitle != null) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              subtitle!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    );
  }
}

class _SummaryTile extends StatelessWidget {
  final PartMeasurement measurement;
  final UnitSystem units;

  const _SummaryTile({required this.measurement, required this.units});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Column(
          children: [
            Text(
              measurement.part.label,
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                formatLength(measurement.valueCm, units),
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TipsCard extends StatelessWidget {
  const _TipsCard();

  static const List<(IconData, String)> _tips = [
    (Icons.checkroom, 'Wear tight-fitting clothing (or underwear).'),
    (Icons.face_retouching_natural, 'Tie long hair up, off your shoulders.'),
    (Icons.wallpaper, 'Stand in front of a clear, uncluttered background.'),
    (
      Icons.smartphone,
      'Prop the phone upright at hip height — about 1 m from the ground.'
    ),
    (Icons.social_distance, 'Stand 2–3 m away so your whole body is visible.'),
    (Icons.group_outlined, 'A friend can also hold the phone for you.'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        child: Column(
          children: [
            for (final (icon, text) in _tips)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(icon, size: 22, color: theme.colorScheme.primary),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(text, style: theme.textTheme.bodyMedium),
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

class _HistoryTile extends StatelessWidget {
  final MeasurementResult result;
  final UnitSystem units;

  const _HistoryTile({required this.result, required this.units});

  @override
  Widget build(BuildContext context) {
    final parts = [
      for (final part in BodyPart.values)
        if (result.partFor(part) case final m?)
          '${m.part.label} ${formatLength(m.valueCm, units)}',
    ];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: const Icon(Icons.history),
        title: Text(_formatDate(result.timestamp)),
        subtitle: Text(parts.isEmpty ? 'No parts measured' : parts.join(' · ')),
      ),
    );
  }
}
