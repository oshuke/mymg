import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mymg/about_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'about displays installed version and policy/license destinations',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('mymg/app_info'), (
            call,
          ) async {
            if (call.method != 'getVersion')
              throw StateError('Unexpected app info call');
            return {'versionName': '1.1.0', 'versionCode': 2};
          });
      await tester.binding.setSurfaceSize(const Size(430, 3000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const MaterialApp(home: AboutPage()));
      await tester.pumpAndSettle();
      expect(find.text('1.1.0 (2)'), findsOneWidget);
      await tester.tap(find.text('隐私政策'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('开源许可与感谢'));
      await tester.pumpAndSettle();
      expect(find.byType(LicensePage), findsOneWidget);
    },
  );
}
