import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mymg/login_page.dart';
import 'package:mymg/product_shell.dart';
import 'package:mymg/settings_page.dart';
import 'package:mymg/src/rust/frb_generated.dart';
import 'package:mymg/src/rust/vehicle/summary.dart';
import 'package:mymg/theme_controller.dart';

class _LoginApi implements RustLibApi {
  @override
  Future<VehicleSummary> crateApiFetchSummary({
    required String token,
    required String vin,
  }) async => const VehicleSummary(alerts: []);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('No vehicle command in login test');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'mymg.user_id': 'test-user',
      'mymg.mobile': 'test-mobile',
      'mymg.auto_refresh': false,
      'mymg.maint.enabled': false,
      'mymg.alerts.enabled': false,
    });
    RustLib.initMock(api: _LoginApi());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('mymg/debug'),
          (call) async => 'ui-test-device',
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'read' ? '1234' : null,
        );
  });
  tearDown(RustLib.dispose);

  testWidgets(
    'successful saved-token login enters the shell and retains home-back protection',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ThemeScope(
          controller: ThemeController.instance,
          child: MaterialApp(
            theme: buildAppTheme(Brightness.light),
            home: const LoginPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      await tester.tap(find.text('备用：粘贴 Token 登录'));
      await tester.pumpAndSettle();
      final token = find.widgetWithText(TextField, 'ACCESS_TOKEN');
      final vin = find.widgetWithText(TextField, 'VIN（17 位）');
      await tester.enterText(token, 'preview-only');
      await tester.enterText(vin, 'TEST0000000000001');
      await tester.ensureVisible(find.text('用 Token 进入'));
      await tester.tap(find.text('用 Token 进入'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.byType(ProductShell),
        findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((text) => text.data)
            .join('\n'),
      );
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(find.byKey(const ValueKey('main-navigation')), findsNothing);
      expect(find.byType(BackButton), findsOneWidget);
      await tester.tap(find.text('数据刷新'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('账号'), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('MYMG 汽车'), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text('再按一次返回桌面'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 3));
    },
  );
}
