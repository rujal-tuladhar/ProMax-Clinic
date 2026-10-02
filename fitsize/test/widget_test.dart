import 'dart:convert';

import 'package:fitsize/main.dart';
import 'package:fitsize/models/models.dart';
import 'package:fitsize/screens/home_screen.dart';
import 'package:fitsize/screens/onboarding_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('first run (no saved profile) shows onboarding',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const FitSizeApp());
    await tester.pumpAndSettle();

    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    // The privacy promise is part of the onboarding contract.
    expect(find.textContaining('never uploaded'), findsOneWidget);
  });

  testWidgets('saved profile goes straight to home',
      (WidgetTester tester) async {
    const profile = UserProfile(
      heightCm: 172,
      sex: Sex.female,
      units: UnitSystem.metric,
    );
    SharedPreferences.setMockInitialValues({
      'fitsize.profile': jsonEncode(profile.toJson()),
    });

    await tester.pumpWidget(const FitSizeApp());
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(OnboardingScreen), findsNothing);
    expect(find.text('Quick measure · 2 photos'), findsOneWidget);
    expect(find.text('Precision measure · full turn'), findsOneWidget);
  });
}
