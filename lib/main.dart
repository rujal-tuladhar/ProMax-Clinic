import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/models.dart';
import 'screens/capture_screen.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/results_screen.dart';
import 'services/profile_store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // The capture guide, tilt gate and preview math all assume portrait.
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const FitSizeApp());
}

/// Root widget of FitSize: Material 3, seeded teal colour scheme with light
/// and dark themes, and the app's named routes.
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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      routes: {
        '/': (_) => const _StartupGate(),
        '/onboarding': (_) => const OnboardingScreen(),
        '/capture': (_) => const CaptureScreen(),
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
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.straighten, size: 56, color: scheme.primary),
            const SizedBox(height: 12),
            Text(
              'FitSize',
              style: Theme.of(context)
                  .textTheme
                  .headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 24),
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
          ],
        ),
      ),
    );
  }
}
