import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mymg/src/rust/vehicle/model.dart';
import 'package:mymg/src/rust/vehicle/summary.dart';
import 'package:mymg/theme_controller.dart';
import 'package:mymg/ui/home_dashboard.dart';

void main() {
  testWidgets('shows a gasoline MG5 hero and never labels range as charging', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(393, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var commands = 0;
    var historyOpens = 0;
    final summary = VehicleSummary(
      fuelPercent: 68,
      rangeKm: 426,
      odometerKm: 28640,
      fuelConsumption: 6.9,
      allLocked: true,
      allDoorsClosed: true,
      allWindowsClosed: true,
      tyreKpa: [230, 235, 230, 235],
      alerts: [],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(
          body: HomeDashboard(
            summary: summary,
            plate: '',
            onRefresh: () async {},
            onMessages: () {},
            onSettings: () {},
            onImage: () {},
            onLock: () => commands++,
            onClimate: () {},
            onTrunk: () => commands++,
            onFind: () => commands++,
            onStatus: () {},
            onLocation: () {},
            onHistory: () => historyOpens++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('MG5'), findsOneWidget);
    expect(find.text('2021 · 燃油版'), findsOneWidget);
    expect(find.text('426 km'), findsOneWidget);
    expect(find.text('68 %'), findsOneWidget);
    expect(find.text('剩余油量'), findsOneWidget);
    expect(find.textContaining('充电'), findsNothing);
    expect(find.textContaining('OTA'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('车锁'));
    expect(commands, 1);
    await tester.ensureVisible(find.text('历史记录'));
    expect(
      tester.getTopLeft(find.text('历史记录')).dy,
      lessThan(tester.getTopLeft(find.text('车辆健康')).dy),
    );
    await tester.tap(find.text('历史记录'));
    expect(historyOpens, 1);
    expect(find.text('数字钥匙'), findsNothing);
  });

  testWidgets('unknown vehicle safety signals are not presented as healthy', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(393, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(
          body: HomeDashboard(
            summary: const VehicleSummary(
              alerts: [VehicleAlert(alertId: 23, alertType: 1, alertData: 2)],
            ),
            plate: '',
            onRefresh: () async {},
            onMessages: () {},
            onSettings: () {},
            onImage: () {},
            onLock: () {},
            onClimate: () {},
            onTrunk: () {},
            onFind: () {},
            onStatus: () {},
            onLocation: () {},
            onHistory: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('车辆有提醒'), findsOneWidget);
    expect(find.textContaining('告警 ID：23 · 类型：1 · 数据：2'), findsOneWidget);
    expect(find.textContaining('含义待确认'), findsOneWidget);
    expect(find.text('一切正常'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
