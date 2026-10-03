import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/models.dart';
import 'screens/capture_screen.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/results_screen.dart';
import 'screens/turn_capture_screen.dart';
import 'services/profile_store.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // The capture guide, tilt gate and preview math all assume portrait.
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const FitSizeApp());
}

/// Root widget of FitSize: the [AppTheme] (Material 3, teal on sand / teal
/// on near-black) in light and dark, and the app's named routes.
///
/// The `/` route is a gate that loads the saved [UserProfile] and shows
/// [OnboardingScreen] on first run (no profile yet) or [HomeScreen]
/// otherwise.
class FitSizeApp extends StatelessWidget {
  /// Creates the FitSize application shell.
  const FitSizeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FitSize',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      routes: {
        '/': (_) => const _StartupGate(),
        '/onboarding': (_) => const OnboardingScreen(),
        '/capture': (_) => const CaptureScreen(),
        '/capture-turn': (_) => const TurnCaptureScreen(),
        '/results': (_) => const ResultsScreen(),
      },
    );
  }
}

/// Decides what the `/` route shows: a brief splash while the profile loads,
/// [OnboardingScreen] when no profile is saved yet, [HomeScreen] otherwise.
class _StartupGate extends StatefulWidget {
  const _StartupGate();

  @override
  State<_StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<_StartupGate> {
  final ProfileStore _store = ProfileStore();
  late Future<UserProfile?> _profileFuture;

  @override
  void initState() {
    super.initState();
    _profileFuture = _store.loadProfile();
  }

  void _reload() {
    setState(() {
      _profileFuture = _store.loadProfile();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<UserProfile?>(
      future: _profileFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _SplashScreen();
        }
        if (snapshot.data == null) {
          return OnboardingScreen(onDone: _reload);
        }
        return const HomeScreen();
      },
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Brand mark: teal rounded square with the tape icon, matching
            // the launcher icon.
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(AppRadii.card),
              ),
              child: Icon(Icons.straighten, size: 40, color: scheme.onPrimary),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'FitSize',
              style: theme.textTheme.headlineMedium?.copyWith(
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Your size, measured.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            const SizedBox(width: 120, child: TapeDivider()),
            const SizedBox(height: AppSpacing.xl),
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ],
        ),
      ),
    );
  }
}
