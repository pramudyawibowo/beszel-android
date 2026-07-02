import 'package:beszel_pro/main.dart';
import 'package:beszel_pro/providers/app_provider.dart';
import 'package:beszel_pro/services/alert_manager.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders splash and opens language setup on first run', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'is_first_run': true});
    await EasyLocalization.ensureInitialized();
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: const [
          Locale('en'),
          Locale('ru'),
          Locale('zh', 'CN'),
        ],
        path: 'assets/translations',
        fallbackLocale: const Locale('en'),
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => AppProvider(prefs)),
            ChangeNotifierProvider(create: (_) => AlertManager()),
          ],
          child: const MyApp(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Beszel Pro'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(find.byIcon(Icons.language), findsWidgets);
  });
}
