import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mymg/src/rust/vehicle/model.dart';
import 'package:mymg/src/rust/vehicle/summary.dart';
import 'package:mymg/theme_controller.dart';
import 'package:mymg/vehicle_status_page.dart';

Future<void> _show(
  WidgetTester tester,
  VehicleStatusLoader loader, {
  Size size = const Size(390, 844),
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: VehicleStatusPage(
        token: 'test-token',
        vin: 'test-vehicle',
        loadSummary: loader,
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('empty alerts never imply healthy unknown vehicle', (
    tester,
  ) async {
    await _show(
      tester,
      ({required token, required vin, required force}) async =>
          const VehicleSummary(alerts: []),
    );
    await tester.pumpAndSettle();
    expect(find.text('部分状态待确认'), findsOneWidget);
    expect(find.textContaining('车门状态未知'), findsOneWidget);
    expect(find.textContaining('门锁状态未知'), findsOneWidget);
    expect(find.text('车窗状态未知'), findsOneWidget);
    expect(find.text('左前  未提供'), findsOneWidget);
    expect(find.text('右后  未提供'), findsOneWidget);
    expect(find.textContaining('一切正常'), findsNothing);
    expect(find.text('正常'), findsNothing);
    expect(find.byIcon(Icons.shield_outlined), findsNothing);
  });

  testWidgets('unlocked open vehicle stays a warning even with no alerts', (
    tester,
  ) async {
    await _show(
      tester,
      ({required token, required vin, required force}) async =>
          const VehicleSummary(
            allLocked: false,
            allDoorsClosed: false,
            allWindowsClosed: false,
            tyreKpa: [220, 230, 240, 250],
            alerts: [],
          ),
    );
    await tester.pumpAndSettle();
    expect(find.text('请检查车辆'), findsOneWidget);
    expect(find.textContaining('有车门未关'), findsWidgets);
    expect(find.textContaining('车辆未锁'), findsWidgets);
    expect(find.textContaining('有车窗未关'), findsWidgets);
    expect(find.textContaining('一切正常'), findsNothing);
  });

  testWidgets('four actual tyre readings are not classified by presence', (
    tester,
  ) async {
    await _show(
      tester,
      ({required token, required vin, required force}) async =>
          const VehicleSummary(
            allLocked: true,
            allDoorsClosed: true,
            allWindowsClosed: true,
            tyreKpa: [0, 160, 245, 390],
            odometerKm: 12680,
          ),
    );
    await tester.pumpAndSettle();
    expect(find.text('左前  0 kPa'), findsOneWidget);
    expect(find.text('右前  160 kPa'), findsOneWidget);
    expect(find.text('左后  245 kPa'), findsOneWidget);
    expect(find.text('右后  390 kPa'), findsOneWidget);
    expect(find.text('胎压请核对车辆建议值'), findsOneWidget);
    expect(find.text('正常'), findsNothing);
    expect(find.text('12V 电压'), findsOneWidget);
    expect(find.text('未提供'), findsOneWidget);
    expect(find.text('12680 km'), findsOneWidget);
  });

  testWidgets('short tyre arrays and mixed unknown states stay explicit', (
    tester,
  ) async {
    await _show(
      tester,
      ({required token, required vin, required force}) async =>
          const VehicleSummary(
            allLocked: false,
            allDoorsClosed: true,
            tyreKpa: [235, null],
            alerts: [],
          ),
    );
    await tester.pumpAndSettle();
    expect(find.text('左前  235 kPa'), findsOneWidget);
    expect(find.text('右前  未提供'), findsOneWidget);
    expect(find.text('左后  未提供'), findsOneWidget);
    expect(find.text('右后  未提供'), findsOneWidget);
    expect(find.text('车窗状态未知'), findsOneWidget);
    expect(find.textContaining('车辆未锁'), findsWidgets);
    expect(find.textContaining('车窗、胎压状态待确认'), findsOneWidget);
  });

  testWidgets('reported alerts remain visible with closed locked vehicle', (
    tester,
  ) async {
    await _show(
      tester,
      ({required token, required vin, required force}) async =>
          const VehicleSummary(
            allLocked: true,
            allDoorsClosed: true,
            allWindowsClosed: true,
            tyreKpa: [235, 235, 240, 240],
            alerts: [VehicleAlert(alertId: 1)],
          ),
    );
    await tester.pumpAndSettle();
    expect(find.text('请检查车辆'), findsOneWidget);
    expect(find.textContaining('有 1 条车辆提醒'), findsOneWidget);
  });

  testWidgets(
    'overview renders every alert payload and marks numeric meanings unconfirmed',
    (tester) async {
      await _show(
        tester,
        ({required token, required vin, required force}) async =>
            const VehicleSummary(
              allLocked: true,
              allDoorsClosed: true,
              allWindowsClosed: true,
              tyreKpa: [235, 235, 240, 240],
              alerts: [
                VehicleAlert(alertId: 31, alertType: 4, alertData: 8),
                VehicleAlert(alertId: 32, alertType: 5, alertData: 0),
                VehicleAlert(alertId: 33),
                VehicleAlert(),
              ],
            ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('有 4 条车辆提醒'), findsOneWidget);
      expect(find.text('告警 ID：31 · 类型：4 · 数据：8\n含义待确认'), findsOneWidget);
      expect(find.text('告警 ID：32 · 类型：5 · 数据：0\n含义待确认'), findsOneWidget);
      expect(find.text('告警 ID：33\n含义待确认'), findsOneWidget);
      expect(find.text('车辆提醒（未提供代码）\n含义待确认'), findsOneWidget);
      expect(find.text('请检查车辆'), findsOneWidget);
      expect(find.text('门窗已关 · 车辆已锁'), findsNothing);
      expect(find.text('正常'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'refresh error preserves readings and survives next pending retry',
    (tester) async {
      var calls = 0;
      final retry = Completer<VehicleSummary>();
      const summary = VehicleSummary(tyreKpa: [231, 232, 233, 234]);
      await _show(tester, ({required token, required vin, required force}) {
        calls++;
        if (calls == 1) return Future.value(summary);
        if (calls == 2) return Future.error(Exception('网络中断'));
        return retry.future;
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('刷新车况'));
      await tester.pumpAndSettle();
      expect(find.text('刷新失败，以下为上次车况'), findsOneWidget);
      expect(find.text('网络中断'), findsOneWidget);
      expect(find.text('左前  231 kPa'), findsOneWidget);
      await tester.tap(find.byTooltip('刷新车况'));
      await tester.pump();
      expect(find.text('网络中断'), findsOneWidget);
      retry.complete(summary);
      await tester.pumpAndSettle();
      expect(find.text('网络中断'), findsNothing);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets('320dp text 200 percent fits in $brightness', (tester) async {
      await _show(
        tester,
        ({required token, required vin, required force}) async =>
            const VehicleSummary(
              allLocked: false,
              tyreKpa: [225, null, 235, 240],
              odometerKm: 123456,
            ),
        size: const Size(320, 640),
        scale: 2,
        brightness: brightness,
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('行驶里程'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('123456 km'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('late summary after disposal does not update state', (
    tester,
  ) async {
    final pending = Completer<VehicleSummary>();
    await _show(
      tester,
      ({required token, required vin, required force}) => pending.future,
    );
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    pending.complete(const VehicleSummary());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
