import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mymg/coord.dart';
import 'package:mymg/map_page.dart';
import 'package:mymg/src/rust/vehicle/summary.dart';
import 'package:mymg/theme_controller.dart';

const _position = VehicleSummary(
  latitude: '31.2304',
  longitude: '121.4737',
  updateTime: 1793754000000,
);

Future<void> _show(
  WidgetTester tester,
  MapSummaryLoader loader, {
  Future<String?> Function(double, double)? resolveAddress,
  Future<void> Function(BuildContext)? openFindControls,
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
      home: MapPage(
        token: 'test-token',
        vin: 'test-vehicle',
        loadSummary: loader,
        resolveAddress: resolveAddress ?? (lat, lng) async => '测试停车位置',
        openFindControls: openFindControls,
        loadMapTiles: false,
      ),
    ),
  );
  await tester.pump();
}

Future<void> _tapReposition(WidgetTester tester) async {
  await tester.ensureVisible(find.text('重新定位'));
  await tester.tap(find.text('重新定位'));
  await tester.pump();
}

void main() {
  testWidgets(
    'marker uses converted coordinate and address resolver gets original coordinate',
    (tester) async {
      double? receivedLat;
      double? receivedLng;
      await _show(
        tester,
        ({required token, required vin, required force}) async => _position,
        resolveAddress: (lat, lng) async {
          receivedLat = lat;
          receivedLng = lng;
          return '测试停车位置';
        },
      );
      await tester.pumpAndSettle();
      final expected = wgs84ToGcj02(31.2304, 121.4737);
      final marker = tester
          .widget<MarkerLayer>(find.byType(MarkerLayer))
          .markers
          .single;
      expect(marker.point.latitude, closeTo(expected.lat, 0.0000001));
      expect(marker.point.longitude, closeTo(expected.lng, 0.0000001));
      expect(receivedLat, 31.2304);
      expect(receivedLng, 121.4737);
      expect(find.text('测试停车位置'), findsOneWidget);
      expect(find.textContaining('GCJ'), findsNothing);
      expect(find.textContaining('已纠偏'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final coordinates in [
    ('', ''),
    ('NaN', '121'),
    ('Infinity', '121'),
    ('91', '121'),
    ('31', '181'),
    ('0', '0'),
    ('86', '121'),
  ]) {
    testWidgets('invalid coordinates $coordinates disable navigation', (
      tester,
    ) async {
      var resolutions = 0;
      await _show(
        tester,
        ({required token, required vin, required force}) async =>
            VehicleSummary(latitude: coordinates.$1, longitude: coordinates.$2),
        resolveAddress: (lat, lng) async {
          resolutions++;
          return '不应解析';
        },
      );
      await tester.pumpAndSettle();
      expect(find.byType(FlutterMap), findsNothing);
      expect(find.text('车辆未提供有效位置，请稍后重新定位'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '导航到车'))
            .onPressed,
        isNull,
      );
      expect(resolutions, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'refresh failure labels old position and persists until successful retry',
    (tester) async {
      var calls = 0;
      final retry = Completer<VehicleSummary>();
      await _show(tester, ({required token, required vin, required force}) {
        calls++;
        if (calls == 1) return Future.value(_position);
        if (calls == 2) return Future.error(Exception('车辆暂时离线'));
        return retry.future;
      });
      await tester.pumpAndSettle();
      await _tapReposition(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('刷新失败，正在显示上次车辆位置'), findsOneWidget);
      expect(find.text('上次车辆位置'), findsOneWidget);
      expect(find.byType(MarkerLayer), findsOneWidget);
      await _tapReposition(tester);
      expect(find.textContaining('车辆暂时离线'), findsOneWidget);
      retry.complete(_position);
      await tester.pumpAndSettle();
      expect(find.textContaining('车辆暂时离线'), findsNothing);
    },
  );

  testWidgets(
    'invalid refresh cannot silently relabel previous location as current',
    (tester) async {
      var calls = 0;
      await _show(
        tester,
        ({required token, required vin, required force}) async => ++calls == 1
            ? _position
            : const VehicleSummary(latitude: '0', longitude: '0'),
      );
      await tester.pumpAndSettle();
      final before = tester
          .widget<MarkerLayer>(find.byType(MarkerLayer))
          .markers
          .single
          .point;
      await _tapReposition(tester);
      await tester.pumpAndSettle();
      expect(find.text('本次位置无效，正在显示上次车辆位置'), findsOneWidget);
      expect(find.text('上次车辆位置'), findsOneWidget);
      final after = tester
          .widget<MarkerLayer>(find.byType(MarkerLayer))
          .markers
          .single
          .point;
      expect(after, before);
    },
  );

  testWidgets(
    'late address for old location does not overwrite new parking address',
    (tester) async {
      final oldAddress = Completer<String?>();
      var loads = 0;
      await _show(
        tester,
        ({required token, required vin, required force}) async => ++loads == 1
            ? _position
            : const VehicleSummary(latitude: '32.0', longitude: '118.8'),
        resolveAddress: (lat, lng) =>
            lat == 31.2304 ? oldAddress.future : Future.value('新的停车位置'),
      );
      await tester.pumpAndSettle();
      await _tapReposition(tester);
      await tester.pumpAndSettle();
      expect(find.text('新的停车位置'), findsOneWidget);
      oldAddress.complete('旧的停车位置');
      await tester.pumpAndSettle();
      expect(find.text('新的停车位置'), findsOneWidget);
      expect(find.text('旧的停车位置'), findsNothing);
    },
  );

  testWidgets(
    'missing address remains navigable without exposing technical fallback',
    (tester) async {
      await _show(
        tester,
        ({required token, required vin, required force}) async => _position,
        resolveAddress: (lat, lng) async => '坐标 31.0000, 121.0000',
      );
      await tester.pumpAndSettle();
      expect(find.text('已定位车辆，详细地址暂不可用'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '导航到车'))
            .onPressed,
        isNotNull,
      );
      await tester.ensureVisible(find.text('导航到车'));
      await tester.tap(find.text('导航到车'));
      await tester.pumpAndSettle();
      expect(find.text('高德地图'), findsOneWidget);
      expect(find.text('百度地图'), findsOneWidget);
      expect(find.text('腾讯地图'), findsOneWidget);
    },
  );

  testWidgets('find entry opens controls only on explicit tap', (tester) async {
    var opened = 0;
    await _show(
      tester,
      ({required token, required vin, required force}) async => _position,
      openFindControls: (context) async {
        opened++;
      },
    );
    await tester.pumpAndSettle();
    expect(opened, 0);
    expect(find.text('闪灯'), findsNothing);
    expect(find.text('鸣笛'), findsNothing);
    await tester.ensureVisible(find.text('闪灯鸣笛寻车'));
    await tester.tap(find.text('闪灯鸣笛寻车'));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  for (final brightness in Brightness.values) {
    testWidgets('320dp text 200 percent map actions fit in $brightness', (
      tester,
    ) async {
      await _show(
        tester,
        ({required token, required vin, required force}) async => _position,
        size: const Size(320, 640),
        scale: 2,
        brightness: brightness,
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('闪灯鸣笛寻车'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('late loading completion after closing page is safe', (
    tester,
  ) async {
    final pending = Completer<VehicleSummary>();
    await _show(
      tester,
      ({required token, required vin, required force}) => pending.future,
    );
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    pending.complete(_position);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('late geocode after map disposal is safe', (tester) async {
    final pending = Completer<String?>();
    await _show(
      tester,
      ({required token, required vin, required force}) async => _position,
      resolveAddress: (lat, lng) => pending.future,
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    pending.complete('晚到的位置');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
