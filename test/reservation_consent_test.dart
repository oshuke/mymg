import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mymg/reservation_service.dart';
import 'package:mymg/src/rust/frb_generated.dart';

class _NoVehicleCalls implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Vehicle call before consent');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'reservation execution cannot read PIN before current agreement',
    () async {
      SharedPreferences.setMockInitialValues({});
      RustLib.initMock(api: _NoVehicleCalls());
      addTearDown(RustLib.dispose);
      var vaultReads = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async {
              vaultReads++;
              return call.method == 'containsKey' ? false : null;
            },
          );
      final result = await runReservationOnce(
        const ReservationConfig(
          enabled: true,
          type: 'ac',
          hour: 8,
          minute: 0,
          atMs: 1,
        ),
      );
      expect(result, isFalse);
      expect(vaultReads, 0);
      expect(
        (await SharedPreferences.getInstance()).getString('mymg.res.last_err'),
        isNull,
      );
    },
  );

  test(
    'expired foreground reservation is not rescheduled before agreement',
    () async {
      SharedPreferences.setMockInitialValues({
        'mymg.res.enabled': true,
        'mymg.res.at_ms': 1,
      });
      final result = await ReservationConfig.tryRunDueInForeground();
      expect(result, isFalse);
      expect(
        (await SharedPreferences.getInstance()).getInt('mymg.res.at_ms'),
        1,
      );
    },
  );
}
