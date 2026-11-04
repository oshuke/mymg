import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mymg/login_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'SMS and token entry require explicit agreement before credentials are used',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var externalCalls = 0;
      for (final name in ['mymg/captcha', 'mymg/debug']) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(MethodChannel(name), (_) async {
              externalCalls++;
              return null;
            });
      }
      await tester.pumpWidget(const MaterialApp(home: LoginPage()));
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
      await tester.enterText(
        find.widgetWithText(TextField, '手机号'),
        '13800138000',
      );
      await tester.enterText(find.widgetWithText(TextField, '短信验证码'), '123456');
      await tester.tap(find.text('获取验证码'));
      await tester.pump();
      expect(find.text('请先阅读并同意用户协议和隐私政策'), findsOneWidget);
      expect(externalCalls, 0);
      await tester.tap(find.text('验证码登录'));
      await tester.pump();
      expect(find.text('请先阅读并同意用户协议和隐私政策'), findsOneWidget);
      expect(externalCalls, 0);
      await tester.tap(find.text('备用：粘贴 Token 登录'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'ACCESS_TOKEN'),
        'synthetic-only',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'VIN（17 位）'),
        'TEST0000000000001',
      );
      await tester.ensureVisible(find.text('用 Token 进入'));
      await tester.tap(find.text('用 Token 进入'));
      await tester.pump();
      expect(find.text('请先阅读并同意用户协议和隐私政策'), findsOneWidget);
      expect(externalCalls, 0);
      expect(
        (await SharedPreferences.getInstance()).getString('mymg.token'),
        isNull,
      );
    },
  );

  testWidgets('reading a policy does not opt the user in', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('隐私政策'));
    await tester.tap(find.text('隐私政策'));
    await tester.pumpAndSettle();
    expect(find.text('隐私政策'), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
  });
}
