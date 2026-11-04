import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mymg/ble_key_bridge.dart';
import 'package:mymg/digital_key_section.dart';
import 'package:mymg/quick_control_sheet.dart';
import 'package:mymg/src/rust/frb_generated.dart';
import 'package:mymg/src/rust/vehicle/control.dart';
import 'package:mymg/src/rust/vehicle/summary.dart';
import 'package:mymg/summary_cache.dart';

// All material here is synthetic. Mock only platform/network boundaries.
const _material = <String, Object>{
  'tboxMac': '001122334455',
  'connectMac': '44:55:22:33:00:11',
  'keyReference': 1,
  'aesKey': 'test-aes',
  'secretKey': 'test-secret',
  'userId': 'test-user',
};

class _KeysApi implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #crateApiVehicleFetchBluetoothKeys) {
      return Future.value(
        const BluetoothKeysResponse(
          raw: '',
          bluetoothKeyList: [
            BluetoothKeyInfo(
              mac: '001122334455',
              aesKey: 'test-aes',
              secretKey: 'test-secret',
              raw: {'key_reference': 1},
            ),
          ],
        ),
      );
    }
    if (invocation.memberName == #crateApiFetchSummary) {
      return Future.value(const VehicleSummary());
    }
    throw StateError('Unexpected API call: ${invocation.memberName}');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mymg/ble');
  final bridge = BleKeyBridge.instance;
  late List<String> calls;
  late bool? granted;
  late bool permissionError;
  Completer<bool>? permission;

  setUp(() async {
    calls = [];
    granted = false;
    permissionError = false;
    permission = null;
    SharedPreferences.setMockInitialValues({
      'mymg.token': 'test-token',
      'mymg.vin': 'TEST0000000000001',
      'mymg.user_id': 'test-user',
      'mymg.mobile': 'test-mobile',
      'mymg.ble.prefer': true,
    });
    SummaryCache.put(const VehicleSummary());
    RustLib.initMock(api: _KeysApi());
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'requestPermissions' && permissionError) {
        throw PlatformException(code: 'ACTIVITY_UNAVAILABLE');
      }
      return switch (call.method) {
        'requestPermissions' => permission?.future ?? granted,
        'hasScanPermission' => granted,
        'cachedMaterial' => _material,
        'isConnected' => false,
        'openAppSettings' => true,
        _ => true,
      };
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => switch (call.method) {
        'containsKey' => true,
        'read' => null,
        'readAll' => <String, String>{},
        _ => null,
      },
    );
    bridge.state = BleBridgeState.idle;
    await bridge.init();
    calls.clear();
  });

  tearDown(() async {
    permission?.complete(false);
    permission = null;
    RustLib.dispose();
  });

  test('send requests permissions and cannot dispatch after denial', () async {
    expect(await bridge.send('unlock'), isFalse);
    expect(calls, contains('requestPermissions'));
    expect(calls, isNot(contains('unlock')));
    expect(bridge.state, BleBridgeState.error);
    expect(bridge.message, contains('权限'));
  });

  test('connect cannot probe after denial and can retry after grant', () async {
    await bridge.connect();
    expect(calls, isNot(contains('probe')));
    expect(bridge.state, BleBridgeState.error);
    granted = true;
    calls.clear();
    await bridge.connect();
    expect(calls.where((m) => m == 'probe'), hasLength(1));
  });

  test('null result fails closed and does not prevent a later retry', () async {
    granted = null;
    expect(await bridge.send('lock'), isFalse);
    expect(calls, isNot(contains('lock')));
    granted = true;
    expect(await bridge.send('lock'), isTrue);
    expect(calls.where((m) => m == 'lock'), hasLength(1));
  });

  test('platform failure releases permission request for retry', () async {
    permissionError = true;
    expect(await bridge.send('unlock'), isFalse);
    expect(calls, isNot(contains('unlock')));
    permissionError = false;
    granted = true;
    expect(await bridge.send('unlock'), isTrue);
    expect(calls.where((m) => m == 'requestPermissions'), hasLength(2));
  });

  test('permission requests merge and finish only after the result', () async {
    permission = Completer<bool>();
    var completed = 0;
    final a = bridge.requestBlePermissions().then((_) => completed++);
    final b = bridge.requestBlePermissions().then((_) => completed++);
    await Future<void>.delayed(Duration.zero);
    final count = calls.where((m) => m == 'requestPermissions').length;
    final beforeResult = completed;
    permission!.complete(false);
    permission = null;
    await Future.wait([a, b]);
    expect(beforeResult, 0);
    expect(count, 1);
    expect(completed, 2);
    granted = true;
    calls.clear();
    await bridge.requestBlePermissions();
    expect(calls.where((m) => m == 'requestPermissions'), hasLength(1));
  });

  test(
    'duplicate send while permissions are pending dispatches only once',
    () async {
      permission = Completer<bool>();
      final a = bridge.send('unlock');
      final b = bridge.send('unlock');
      await Future<void>.delayed(Duration.zero);
      final beforeResult = calls.where((m) => m == 'unlock').length;
      permission!.complete(true);
      permission = null;
      final outcomes = await Future.wait([a, b]);
      expect(beforeResult, 0);
      expect(outcomes.where((ok) => ok), hasLength(1));
      expect(calls.where((m) => m == 'unlock'), hasLength(1));
    },
  );

  Future<void> showKeys(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: DigitalKeyPage()));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'permission wait disables key actions and merges immediate taps',
    (tester) async {
      await showKeys(tester);
      permission = Completer<bool>();
      final button = find.ancestor(
        of: find.text('蓝牙解锁'),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      );
      final press = tester.widget<ButtonStyleButton>(button).onPressed!;
      press();
      press();
      await tester.pump();
      final disabledWhilePending =
          tester.widget<ButtonStyleButton>(button).onPressed == null;
      permission!.complete(true);
      permission = null;
      await tester.pumpAndSettle();
      expect(disabledWhilePending, isTrue);
      expect(calls.where((m) => m == 'requestPermissions'), hasLength(1));
      expect(calls.where((m) => m == 'unlock'), hasLength(1));
    },
  );

  testWidgets('scan starts after a real grant without requiring a second tap', (
    tester,
  ) async {
    await showKeys(tester);
    permission = Completer<bool>();
    await tester.ensureVisible(find.text('附近蓝牙扫描'));
    await tester.tap(find.text('附近蓝牙扫描'));
    await tester.pump();
    expect(calls, isNot(contains('startScan')));
    permission!.complete(true);
    permission = null;
    await tester.pumpAndSettle();
    expect(calls.where((m) => m == 'startScan'), hasLength(1));
  });

  for (final label in ['GATT 探测', '蓝牙解锁', '蓝牙锁车', '开后备箱', '启动（120秒打火）']) {
    testWidgets('$label does not dispatch after denial and remains retryable', (
      tester,
    ) async {
      await showKeys(tester);
      calls.clear();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(
        calls.toSet().intersection({
          'probe',
          'unlock',
          'lock',
          'trunk',
          'drive',
        }),
        isEmpty,
      );
      expect(find.textContaining('权限'), findsWidgets);
      expect(find.text('打开应用设置'), findsWidgets);
      final button = find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      );
      expect(tester.widget<ButtonStyleButton>(button).onPressed, isNotNull);
    });
  }

  testWidgets('denied scanning exposes working app settings and retry', (
    tester,
  ) async {
    await showKeys(tester);
    await tester.ensureVisible(find.text('附近蓝牙扫描'));
    await tester.tap(find.text('附近蓝牙扫描'));
    await tester.pumpAndSettle();
    expect(calls, isNot(contains('startScan')));
    expect(find.text('打开应用设置'), findsWidgets);
    await tester.tap(find.text('打开应用设置').last);
    await tester.pumpAndSettle();
    expect(calls, contains('openAppSettings'));
    granted = true;
    await tester.tap(find.text('附近蓝牙扫描'));
    await tester.pumpAndSettle();
    expect(calls.where((m) => m == 'startScan'), hasLength(1));
  });

  testWidgets('quick control denial clears busy and retry dispatches once', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(500, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: QuickControlSheet())),
    );
    await tester.pumpAndSettle();
    calls.clear();
    await tester.tap(find.text('解锁').first);
    await tester.pumpAndSettle();
    expect(calls, isNot(contains('unlock')));
    expect(find.textContaining('权限'), findsWidgets);
    expect(find.text('打开应用设置'), findsOneWidget);
    await tester.tap(find.text('打开应用设置'));
    await tester.pumpAndSettle();
    expect(calls, contains('openAppSettings'));
    granted = true;
    await tester.tap(find.text('解锁').first);
    await tester.pumpAndSettle();
    expect(calls.where((m) => m == 'unlock'), hasLength(1));
    // Let the existing command watchdog finish inside the test clock.
    await tester.pump(const Duration(seconds: 11));
  });
}
