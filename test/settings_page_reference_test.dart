import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mymg/car_image_settings_page.dart';
import 'package:mymg/digital_key_section.dart';
import 'package:mymg/login_page.dart';
import 'package:mymg/message_center_page.dart';
import 'package:mymg/settings_page.dart';
import 'package:mymg/src/rust/vehicle/summary.dart';
import 'package:mymg/summary_cache.dart';
import 'package:mymg/theme_controller.dart';
import 'package:mymg/ui/frosted_page.dart';
import 'package:mymg/ui/glass_surface.dart';

const _settings = SettingsPage(
  token: 'settings-test',
  vin: 'TEST0000000000001',
);

Future<void> _show(
  WidgetTester tester, {
  double scale = 1,
  Brightness brightness = Brightness.light,
  bool nested = false,
  bool tall = false,
}) async {
  await tester.binding.setSurfaceSize(Size(320, tall ? 3000 : 640));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: nested
          ? Navigator(
              onGenerateRoute: (_) =>
                  MaterialPageRoute<void>(builder: (_) => _settings),
            )
          : _settings,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester, String title) async {
  await tester.scrollUntilVisible(
    find.text(title),
    220,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 40,
  );
  await tester.tap(find.text(title));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'mymg.token': 'settings-test',
      'mymg.vin': 'TEST0000000000001',
      'mymg.user_id': 'test-user',
      'mymg.auto_refresh': true,
      'mymg.interval_min': 5,
    });
    SummaryCache.put(const VehicleSummary(odometerKm: 42000));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => switch (call.method) {
        'containsKey' => false,
        'readAll' => <String, String>{},
        _ => null,
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('mymg/ble'),
      (_) async => null,
    );
    await ThemeController.instance.load();
  });

  testWidgets(
    'settings retains every category and consolidates utility entries',
    (tester) async {
      await _show(tester, tall: true);
      for (final title in [
        '账号',
        '外观',
        '消息中心',
        '车辆图片',
        '蓝牙数字钥匙',
        '数据刷新',
        '地图与位置',
        '远程控车',
        'AI 智能分析',
        '坚果云备份',
        '告警推送',
        '地理围栏 / 异常移动',
        '保养提醒',
        '后台轮询',
        '桌面小组件',
        '本机数据',
        '关于',
        '账户',
      ]) {
        expect(find.text(title), findsOneWidget, reason: title);
        expect(
          find.ancestor(
            of: find.text(title),
            matching: find.byType(GlassSurface),
          ),
          findsOneWidget,
          reason: '$title uses the shared glass row',
        );
      }
      expect(find.text('数字钥匙'), findsNothing);
      expect(find.text('蓝牙钥匙'), findsNothing);
      expect(find.text('历史记录'), findsNothing);
      expect(find.textContaining('更多'), findsNothing);
      expect(find.textContaining('OTA'), findsNothing);
      expect(find.byType(FrostedBackground), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('message entry opens existing center on the nearest navigator', (
    tester,
  ) async {
    await _show(tester, nested: true, tall: true);
    expect(find.text('消息中心'), findsOneWidget);
    final settingsContext = tester.element(find.byType(SettingsPage));
    final root = Navigator.of(settingsContext, rootNavigator: true);
    final nearest = Navigator.of(settingsContext);
    await _open(tester, '消息中心');
    final page = tester.widget<MessageCenterPage>(
      find.byType(MessageCenterPage),
    );
    expect(page.token, 'settings-test');
    expect(page.vin, 'TEST0000000000001');
    expect(nearest.canPop(), isTrue);
    expect(root.canPop(), isFalse);
    nearest.pop();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
  });

  testWidgets('vehicle images are directly accessible from settings', (
    tester,
  ) async {
    await _show(tester, tall: true);
    expect(find.text('车辆图片'), findsOneWidget);
    await _open(tester, '车辆图片');
    expect(find.byType(CarImageSettingsPage), findsOneWidget);
    expect(find.text('从相册选择'), findsOneWidget);
  });

  testWidgets('one glass bluetooth entry opens the existing digital key page', (
    tester,
  ) async {
    await _show(tester);
    await tester.scrollUntilVisible(find.text('蓝牙数字钥匙'), 220);
    expect(
      find.ancestor(
        of: find.text('蓝牙数字钥匙'),
        matching: find.byType(GlassSurface),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('蓝牙数字钥匙'));
    await tester.pumpAndSettle();
    expect(find.byType(DigitalKeyPage), findsOneWidget);
  });

  testWidgets(
    'frosted refresh details update immediately and persist on reopen',
    (tester) async {
      await _show(tester);
      await _open(tester, '数据刷新');
      expect(find.byType(FrostedBackground), findsOneWidget);
      expect(find.byType(GlassSurface), findsOneWidget);
      await tester.tap(find.text('自动刷新'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭自动刷新'));
      await tester.pumpAndSettle();
      expect(find.text('已关闭'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('mymg.auto_refresh'), isFalse);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await _open(tester, '数据刷新');
      expect(find.text('已关闭'), findsOneWidget);
    },
  );

  testWidgets(
    'logout replaces the root authentication tree after confirmation',
    (tester) async {
      await _show(tester, nested: true);
      final root = Navigator.of(
        tester.element(find.byType(SettingsPage)),
        rootNavigator: true,
      );
      await _open(tester, '账户');
      await tester.tap(find.text('退出登录 / 重新登录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('mymg.token'), 'settings-test');
      await tester.tap(find.text('退出登录 / 重新登录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('退出'));
      await tester.pumpAndSettle();
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.byType(SettingsPage, skipOffstage: false), findsNothing);
      expect(find.byType(Navigator), findsOneWidget);
      expect(root.canPop(), isFalse);
      expect(prefs.getString('mymg.token'), isNull);
      expect(prefs.getString('mymg.vin'), isNull);
    },
  );

  for (final embedded in [false, true]) {
    testWidgets('pushed settings leading respects embedded=$embedded', (
      tester,
    ) async {
      await _show(tester);
      Navigator.of(tester.element(find.byType(SettingsPage))).push(
        MaterialPageRoute<void>(
          builder: (_) => SettingsPage(
            token: 'settings-test',
            vin: 'TEST0000000000001',
            embedded: embedded,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), embedded ? findsNothing : findsOneWidget);
      await _open(tester, '账号');
      expect(find.byType(BackButton), findsOneWidget);
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      'settings and account details fit 320dp at 200% in $brightness',
      (tester) async {
        await _show(tester, scale: 2, brightness: brightness);
        await _open(tester, '账号');
        expect(tester.takeException(), isNull);
        expect(find.byType(FrostedBackground), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('账户'), 300, maxScrolls: 40);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
