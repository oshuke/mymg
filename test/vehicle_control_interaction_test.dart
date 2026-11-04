import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mymg/quick_control_sheet.dart';
import 'package:mymg/climate_page.dart';
import 'package:mymg/vehicle_control_page.dart';
import 'package:mymg/src/rust/frb_generated.dart';
import 'package:mymg/src/rust/vehicle/control.dart';
import 'package:mymg/src/rust/vehicle/summary.dart';
import 'package:mymg/summary_cache.dart';
import 'package:mymg/ui/home_return_navigator.dart';

// Mock only the hardware/network boundaries. The actual widget, PIN dialog,
// busy state and command dispatch run unchanged, with no FFI or vehicle access.
class _VehicleApi implements RustLibApi {
  final commands = <Invocation>[];
  ControlOutcome outcome = const ControlOutcome(
    accepted: false,
    message: '操作失败',
  );
  Completer<ControlOutcome>? pending;
  Completer<ControlStatusResult>? poll;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #crateApiFetchSummary) {
      return Future<VehicleSummary>.value(const VehicleSummary(acOn: false));
    }
    if (invocation.memberName == #crateApiVehicleGetControlStatus) {
      return poll?.future ??
          Future<ControlStatusResult>.value(
            const ControlStatusResult(done: true, success: true, raw: '{}'),
          );
    }
    if (invocation.memberName.toString().contains('crateApiVehicle')) {
      commands.add(invocation);
      return pending?.future ?? Future<ControlOutcome>.value(outcome);
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _VehicleApi api;
  late int storageReads;
  late bool askForPin;

  setUp(() {
    api = _VehicleApi();
    RustLib.initMock(api: api);
    storageReads = 0;
    askForPin = false;
    SharedPreferences.setMockInitialValues({
      'mymg.token': 'widget-test-access-token',
      'mymg.vin': 'TEST0000000000001',
      'mymg.user_id': 'test-user',
      'mymg.mobile': 'test-mobile',
      'mymg.ble.prefer': false,
    });
    SummaryCache.put(const VehicleSummary(acOn: false, acTargetTemp: 24));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('mymg/ble'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        if (call.method == 'read') {
          storageReads++;
          return askForPin && storageReads > 1 ? null : '1234';
        }
        if (call.method == 'containsKey') return true;
        if (call.method == 'readAll') return <String, String>{};
        return null;
      },
    );
  });

  tearDown(RustLib.dispose);

  Future<void> openClimate(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ClimatePage(
          token: 'widget-test-access-token',
          vin: 'TEST0000000000001',
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('in-app quick control stays inside the authenticated navigator', (
    tester,
  ) async {
    late BuildContext pageContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (context) {
              pageContext = context;
              return Scaffold(
                body: TextButton(
                  onPressed: () => showQuickControlSheet(context),
                  child: const Text('open-quick'),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-quick'));
    await tester.pumpAndSettle();
    expect(find.byType(QuickControlHostPage), findsOneWidget);
    expect(Navigator.of(pageContext, rootNavigator: true).canPop(), isFalse);
    expect(Navigator.of(pageContext).canPop(), isTrue);
    expect(api.commands, isEmpty);
    await tester.tap(find.byTooltip('关闭控车'));
    await tester.pumpAndSettle();
    expect(find.byType(QuickControlHostPage), findsNothing);
    expect(find.text('open-quick'), findsOneWidget);
  });

  testWidgets('closing a quick-control overlay preserves the originating tab', (
    tester,
  ) async {
    var home = false;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => HomeReturnNavigator(
            isHome: home,
            onHome: () => setState(() => home = true),
            child: Scaffold(
              body: Builder(
                builder: (context) => Column(
                  children: [
                    Text(home ? 'home-tab' : 'location-tab'),
                    TextButton(
                      onPressed: () => showQuickControlSheet(context),
                      child: const Text('open-quick'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-quick'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(QuickControlHostPage), findsNothing);
    expect(find.text('location-tab'), findsOneWidget);
    expect(home, isFalse);
    expect(api.commands, isEmpty);
  });

  testWidgets('opening an action shortcut never sends a vehicle command', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: QuickControlSheet(initialAction: 'unlock')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    expect(api.commands, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('an overdue reservation is not executed when opening control', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('mymg.res.enabled', true);
    await prefs.setString('mymg.res.type', 'ac');
    await prefs.setInt(
      'mymg.res.at_ms',
      DateTime.now().millisecondsSinceEpoch - 1000,
    );
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: QuickControlSheet())),
    );
    await tester.pumpAndSettle();
    expect(api.commands, isEmpty);
    expect(prefs.getBool('mymg.res.enabled'), isTrue);
  });

  testWidgets('PIN cancellation is silent and restores the action button', (
    tester,
  ) async {
    askForPin = true;
    await openClimate(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('climate-apply')));
    await tester.tap(find.byKey(const ValueKey('climate-apply')));
    // The request spinner intentionally remains active while PIN entry is
    // pending. Finish the dialog entrance, not every animation in the app.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('输入控车密码'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('climate-apply')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(api.commands, isEmpty);
    expect(find.textContaining('已取消'), findsNothing);
    expect(find.textContaining('失败'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('climate-apply')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('two immediate taps open only one PIN dialog', (tester) async {
    askForPin = true;
    await openClimate(tester);
    final button = find.byKey(const ValueKey('climate-apply'));
    await tester.ensureVisible(button);
    // Both callbacks arrive before a rebuild can disable the button. Pointer
    // taps after the first await would hit the modal barrier instead.
    final submit = tester.widget<FilledButton>(button).onPressed!;
    submit();
    submit();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(api.commands, isEmpty);
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  for (final action in ['lock', 'unlock', 'trunk', 'find']) {
    testWidgets('the $action shortcut highlights intent without executing', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: QuickControlSheet(initialAction: action)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      for (final candidate in ['lock', 'unlock', 'trunk', 'find']) {
        final target = tester.widget<Semantics>(
          find.byKey(ValueKey('vehicle-action-$candidate')),
        );
        expect(target.properties.selected, candidate == action);
      }
      expect(api.commands, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
    });
  }

  testWidgets(
    'temperature selection sends only after explicit apply and preserves errors',
    (tester) async {
      await openClimate(tester);
      await tester.ensureVisible(find.byTooltip('升高温度'));
      await tester.tap(find.byTooltip('升高温度'));
      await tester.pumpAndSettle();
      expect(api.commands, isEmpty);
      expect(find.text('25.0°C'), findsNWidgets(2));
      await tester.ensureVisible(find.byKey(const ValueKey('climate-apply')));
      await tester.tap(find.byKey(const ValueKey('climate-apply')));
      await tester.pumpAndSettle();
      expect(api.commands.single.memberName, #crateApiVehicleAcOn);
      expect(api.commands.single.namedArguments[#targetTempC], 25);
      expect(find.text('操作失败'), findsOneWidget);
      expect(find.text('空调已关闭'), findsOneWidget);
      expect(find.text('空调运行中'), findsNothing);
    },
  );

  testWidgets('accepted command does not claim the AC is running', (
    tester,
  ) async {
    api.outcome = const ControlOutcome(accepted: true);
    await openClimate(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('climate-apply')));
    await tester.tap(find.byKey(const ValueKey('climate-apply')));
    await tester.pumpAndSettle();
    expect(find.text('「设置温度」已下发'), findsOneWidget);
    expect(find.text('空调已关闭'), findsOneWidget);
    expect(find.text('空调运行中'), findsNothing);
  });

  testWidgets(
    'remote polling holds the duplicate guard and releases on result',
    (tester) async {
      api.outcome = const ControlOutcome(accepted: true, commandId: 1);
      api.poll = Completer<ControlStatusResult>();
      await openClimate(tester);
      final button = find.byKey(const ValueKey('climate-apply'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(api.commands, hasLength(1));
      api.poll!.complete(
        const ControlStatusResult(done: true, success: true, raw: '{}'),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      expect(find.text('「设置温度」执行成功'), findsOneWidget);
    },
  );

  testWidgets('seat heating is read only and has no scheduling choices', (
    tester,
  ) async {
    SummaryCache.put(
      const VehicleSummary(
        acOn: false,
        seatHeatDriver: true,
        seatHeatPassenger: false,
        seatHeatDriverLevel: 2,
      ),
    );
    await openClimate(tester);
    await tester.ensureVisible(find.text('座椅加热'));
    await tester.tap(find.text('座椅加热'));
    await tester.pumpAndSettle();
    expect(find.text('主驾  2 档'), findsOneWidget);
    expect(find.text('副驾  关闭'), findsOneWidget);
    expect(api.commands, isEmpty);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('仅查看'), findsOneWidget);
  });

  testWidgets(
    'vehicle diagram actions and climate render on small dark and large text screens',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: const VehicleControlPage(
            token: 'widget-test-access-token',
            vin: 'TEST0000000000001',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('车锁'), findsOneWidget);
      expect(find.text('车窗'), findsOneWidget);
      expect(find.text('后备箱'), findsOneWidget);
      expect(find.text('寻车'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(api.commands, isEmpty);
    },
  );
}
