import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mymg/main.dart';
import 'package:mymg/legal_documents.dart';
import 'package:mymg/product_shell.dart';
import 'package:mymg/quick_control_sheet.dart';
import 'package:mymg/widget_control_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final route in ['/', '/quick_control', '/widget_control/5']) {
    testWidgets('$route blocks saved credentials with an outdated agreement', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'mymg.token': 'synthetic-only',
        'mymg.vin': 'TEST0000000000001',
        LegalConsent.revisionKey: 'old',
        LegalConsent.acceptedAtKey: 1,
      });
      await tester.pumpWidget(MyApp(initialRoute: route));
      await tester.pumpAndSettle();
      expect(find.text('欢迎使用 MYMG'), findsOneWidget);
      expect(find.byType(ProductShell), findsNothing);
      expect(find.byType(QuickControlHostPage), findsNothing);
      expect(find.byType(WidgetControlHostPage), findsNothing);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
    });
  }
}
