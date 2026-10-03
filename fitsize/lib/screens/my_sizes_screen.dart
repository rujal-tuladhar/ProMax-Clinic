import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/brand_sizes.dart';
import '../models/models.dart';
import '../services/profile_store.dart';
import '../theme/app_theme.dart';

/// Disclaimer at the foot of the screen (wording pinned by the UI contract).
const String kBrandChartsDisclaimer =
    'From published size charts (Oct 2026). Verify on the brand site before '
    'ordering.';

/// Bundled brand charts (declared under `flutter: assets:` in pubspec.yaml).
const String kBrandChartsAsset = 'assets/data/brand_charts.json';

/// The brand size passport: the shopper's size at every brand in the
/// catalog, from their latest measurement.
///
/// Route `/my-sizes`. Takes a [MeasurementResult] as the route argument;
/// when absent, the newest [ProfileStore] history entry is used. Charts are
/// loaded from [kBrandChartsAsset] with `rootBundle`. Per brand: top and
/// bottom size with probability text, a 'Between X and Y' chip with the
/// fit-preference hint, the chart confidence tag, source and retrieval date,
/// and any caveat. A search box filters brands by name.
class MySizesScreen extends StatefulWidget {
  /// Creates the screen; the result arrives via route arguments.
  const MySizesScreen({super.key});

  @override
  State<MySizesScreen> createState() => _MySizesScreenState();
}

class _MySizesScreenState extends State<MySizesScreen> {
  final ProfileStore _store = ProfileStore();
  final TextEditingController _search = TextEditingController();

  bool _started = false;
  bool _loading = true;
  String? _error;
  UserProfile? _profile;
  MeasurementResult? _result;
  BrandCatalog? _catalog;
  BrandSizeResolver? _resolver;

  /// Fit chosen on this screen; null means the saved profile's (or regular).
  FitPreference? _fitOverride;
  String _query = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final args = ModalRoute.of(context)?.settings.arguments;
    _load(args is MeasurementResult ? args : null);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load(MeasurementResult? fromRoute) async {
    final profile = await _store.loadProfile();
    var result = fromRoute;
    if (result == null) {
      final history = await _store.loadHistory();
      if (history.isNotEmpty) result = history.first;
    }

    BrandCatalog? catalog;
    String? error;
    try {
      // `cache: false`: the catalog is parsed on every open anyway, so there
      // is nothing to gain from rootBundle holding the string (and the cached
      // Future would be bound to the first caller's zone, which stalls later
      // widget tests that load the same asset).
      final json = await rootBundle.loadString(kBrandChartsAsset, cache: false);
      catalog = BrandCatalog.fromJson(json);
    } catch (_) {
      error = 'The brand charts could not be loaded. Please reinstall the '
          'app or try again later.';
    }

    if (!mounted) return;
    setState(() {
      _profile = profile;
      _result = result;
      _catalog = catalog;
      _resolver = catalog == null ? null : BrandSizeResolver(catalog);
      _error = error;
      _loading = false;
    });
  }

  Future<void> _measure() async {
    await Navigator.of(context).pushNamed('/capture');
    if (!mounted) return;
    setState(() => _loading = true);
    await _load(null);
  }

  /// Applies [fit] now and persists it on the profile (best-effort).
  Future<void> _setFit(FitPreference fit) async {
    setState(() => _fitOverride = fit);
    final profile = _profile;
    if (profile == null) return;
    try {
      await _store.saveProfile(profile.copyWith(fit: fit));
    } catch (_) {
      // Preference persistence is a convenience; never block the screen.
    }
  }

  Future<void> _copySource(Brand brand) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: brand.source));
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text('${brand.brand} size guide link copied')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My sizes')),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null) {
      return _Message(
        icon: Icons.error_outline_rounded,
        title: 'Charts unavailable',
        body: error,
      );
    }
    final result = _result;
    final resolver = _resolver;
    final catalog = _catalog;
    if (result == null || resolver == null || catalog == null) {
      return _Message(
        icon: Icons.straighten_rounded,
        title: 'Measure first',
        body: 'Your brand sizes come from your chest, waist and hip. '
            'Take a measurement and come back.',
        action: FilledButton.icon(
          onPressed: _measure,
          icon: const Icon(Icons.camera_alt_outlined),
          label: const Text('Measure now'),
        ),
      );
    }

    final profile = _profile;
    final units = profile?.units ?? UnitSystem.metric;
    final sex = profile?.sex ?? Sex.other;
    final fit = _fitOverride ?? profile?.fit ?? FitPreference.regular;
    final matches = resolver.matchAll(result, sex, fit: fit);
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty
        ? matches
        : [
            for (final m in matches)
              if (m.brand.brand.toLowerCase().contains(q)) m,
          ];
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.sm,
        AppSpacing.gutter,
        AppSpacing.xxl,
      ),
      children: [
        _Header(
          result: result,
          units: units,
          brandCount: catalog.brands.length,
          fit: fit,
          onFitChanged: _setFit,
        ),
        const SizedBox(height: AppSpacing.lg),
        TextField(
          controller: _search,
          onChanged: (v) => setState(() => _query = v),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Search brands',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () {
                      _search.clear();
                      setState(() => _query = '');
                    },
                  ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
            child: Text(
              'No brands match "${_query.trim()}".',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          )
        else
          for (final (i, match) in shown.indexed) ...[
            if (i > 0) const SizedBox(height: AppSpacing.md),
            _BrandCard(
              match: match,
              fit: fit,
              onCopySource: () => _copySource(match.brand),
            ),
          ],
        const SizedBox(height: AppSpacing.xl),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.info_outline_rounded,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                kBrandChartsDisclaimer,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Chart data v${catalog.version} · '
          '${catalog.brands.length} brands',
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Headline, the measurements the sizes derive from, and the fit selector.
class _Header extends StatelessWidget {
  final MeasurementResult result;
  final UnitSystem units;
  final int brandCount;
  final FitPreference fit;
  final ValueChanged<FitPreference> onFitChanged;

  const _Header({
    required this.result,
    required this.units,
    required this.brandCount,
    required this.fit,
    required this.onFitChanged,
  });

  static const List<BodyPart> _parts = [
    BodyPart.chest,
    BodyPart.waist,
    BodyPart.hip,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final summary = [
      for (final part in _parts)
        if (result.partFor(part) case final m?)
          '${part.label} ${formatLength(m.valueCm, units)}',
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Your size at $brandCount brands',
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          summary.isEmpty ? 'No torso measurements in this result.' : summary,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
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
          onSelectionChanged: (selection) => onFitChanged(selection.first),
        ),
        const SizedBox(height: 6),
        Text(
          _fitHint(fit),
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  static String _fitHint(FitPreference fit) => switch (fit) {
        FitPreference.slim =>
          'Slim: when you are between sizes, we lean to the smaller one.',
        FitPreference.regular =>
          'Regular: sizes follow each brand\'s chart as measured.',
        FitPreference.relaxed =>
          'Relaxed: when you are between sizes, we lean to the larger one.',
      };
}

/// One brand: sizes, between chip, confidence, caveats and provenance.
class _BrandCard extends StatelessWidget {
  final BrandSizeMatch match;
  final FitPreference fit;
  final VoidCallback onCopySource;

  const _BrandCard({
    required this.match,
    required this.fit,
    required this.onCopySource,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brand = match.brand;
    final hasAnySize = match.top != null || match.bottom != null;
    final betweens = <(String, SizeLookup)>[
      if (match.top case final t? when t.between) ('Top', t),
      if (match.bottom case final b? when b.between) ('Bottom', b),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    brand.brand,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                _ConfidenceTag(confidence: brand.confidence),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              hasAnySize
                  ? "${_capitalise(match.gender)}'s chart"
                  : 'No chart for this profile',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: _SizeTile(title: 'Top', lookup: match.top),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: _SizeTile(title: 'Bottom', lookup: match.bottom),
                ),
              ],
            ),
            if (betweens.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final (what, lookup) in betweens)
                    _BetweenChip(what: what, lookup: lookup, fit: fit),
                ],
              ),
            ],
            if (match.note case final note?) ...[
              const SizedBox(height: AppSpacing.md),
              _NoteRow(icon: Icons.info_outline_rounded, text: note),
            ],
            if (brand.notes.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              _NoteRow(icon: Icons.notes_rounded, text: brand.notes),
            ],
            const SizedBox(height: AppSpacing.md),
            InkWell(
              onTap: onCopySource,
              borderRadius: BorderRadius.circular(AppRadii.chip),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(Icons.link_rounded, size: 16, color: scheme.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${_host(brand.source)} · retrieved '
                        '${_formatIsoDate(brand.retrieved)}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.primary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      Icons.copy_rounded,
                      size: 14,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Top" / "Bottom" tile: the size large, probabilities small.
class _SizeTile extends StatelessWidget {
  final String title;
  final SizeLookup? lookup;

  const _SizeTile({required this.title, required this.lookup});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l = lookup;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppRadii.chip),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              l?.label ?? '–',
              style: theme.textTheme.headlineMedium?.copyWith(
                color: l == null ? scheme.onSurfaceVariant : scheme.primary,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            l == null ? 'Not available' : formatSizeProbabilities(l.probabilities),
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// 'Between M and L' with how the fit preference broke the tie.
class _BetweenChip extends StatelessWidget {
  final String what;
  final SizeLookup lookup;
  final FitPreference fit;

  const _BetweenChip({
    required this.what,
    required this.lookup,
    required this.fit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final extras = FitSizeColors.of(context);
    final pair = lookup.betweenPair;
    final text = pair == null
        ? '$what: between sizes'
        : '$what: between ${pair.$1} and ${pair.$2}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: extras.cautionContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.swap_horiz_rounded, size: 16, color: extras.caution),
          const SizedBox(width: 6),
          Text(
            '$text · ${fit.label.toLowerCase()} fit picks ${lookup.label}',
            style: theme.textTheme.labelMedium?.copyWith(
              color: extras.caution,
            ),
          ),
        ],
      ),
    );
  }
}

/// High / Medium / Low chart-confidence pill.
class _ConfidenceTag extends StatelessWidget {
  final String confidence;

  const _ConfidenceTag({required this.confidence});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final extras = FitSizeColors.of(context);
    final (fg, bg, label) = switch (confidence) {
      'high' => (extras.good, extras.goodContainer, 'High confidence'),
      'medium' => (extras.caution, extras.cautionContainer, 'Medium confidence'),
      _ => (scheme.error, scheme.errorContainer, 'Low confidence'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(color: fg),
          ),
        ],
      ),
    );
  }
}

class _NoteRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _NoteRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// Centred icon + title + body (+ optional action) for empty/error states.
class _Message extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: scheme.primary),
            const SizedBox(height: AppSpacing.lg),
            Text(title, style: theme.textTheme.titleLarge),
            const SizedBox(height: AppSpacing.sm),
            Text(
              body,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: AppSpacing.xl),
              action!,
            ],
          ],
        ),
      ),
    );
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

/// '2026-10-03' -> '3 Oct 2026'; anything unparseable is shown as-is.
String _formatIsoDate(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  return '${d.day} ${_monthNames[d.month - 1]} ${d.year}';
}

/// 'https://www.nike.com/size-fit/...' -> 'nike.com'.
String _host(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  if (host.isEmpty) return url;
  return host.replaceFirst(RegExp(r'^(www\d?|shop)\.'), '');
}

String _capitalise(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
