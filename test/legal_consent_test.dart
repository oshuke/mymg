import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mymg/legal_documents.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'consent records a timestamp and requires current policy revision',
    () async {
      expect(await LegalConsent.isAccepted(), isFalse);
      await LegalConsent.accept();
      expect(await LegalConsent.isAccepted(), isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(LegalConsent.acceptedAtKey), greaterThan(0));
      await prefs.setString(LegalConsent.revisionKey, 'old');
      expect(await LegalConsent.isAccepted(), isFalse);
    },
  );

  testWidgets(
    'saved sessions do not build vehicle UI until explicit agreement',
    (tester) async {
      var builds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ConsentGate(
            builder: (_) {
              builds++;
              return const Scaffold(body: Text('vehicle'));
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(builds, 0);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      await tester.tap(find.text('同意并继续'));
      await tester.pumpAndSettle();
      expect(find.text('vehicle'), findsOneWidget);
      expect(await LegalConsent.isAccepted(), isTrue);
    },
  );
}
