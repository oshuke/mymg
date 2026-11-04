import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mymg/src/rust/vehicle/model.dart';
import 'package:mymg/theme_controller.dart';
import 'package:mymg/ui/glass_surface.dart';
import 'package:mymg/ui/vehicle_alert_message.dart';

void main() {
  test(
    'text descriptions are trimmed and retained without invented meanings',
    () {
      expect(
        formatVehicleAlert(
          alertData: '  请检查车辆\n详细情况请查看仪表提示。 \n',
          alertId: 1,
          alertType: 2,
        ),
        '请检查车辆\n详细情况请查看仪表提示。',
      );
    },
  );

  for (final data in <Object?>[
    null,
    '',
    ' \n\t ',
    0,
    -1,
    1.5,
    ' 001 ',
    '1e3',
    '0x0A',
  ]) {
    test(
      'missing or numeric data $data keeps codes and unconfirmed meaning',
      () {
        final message = formatVehicleAlert(
          alertData: data,
          alertId: 0,
          alertType: 7,
        );
        expect(message, contains('告警 ID：0'));
        expect(message, contains('类型：7'));
        expect(message, contains('含义待确认'));
        expect(message, isNot(contains('正常')));
        expect(message, isNot(contains('胎压')));
        expect(message, isNot(contains('车门')));
        if (data == null || data.toString().trim().isEmpty) {
          expect(message, isNot(contains('数据：')));
        } else {
          expect(message, contains('数据：${data.toString().trim()}'));
        }
      },
    );
  }

  test('missing ID still shows the type code without assigning meaning', () {
    expect(formatVehicleAlert(alertType: 0), '类型：0\n含义待确认');
    expect(formatVehicleAlert(), '车辆提醒（未提供代码）\n含义待确认');
  });

  testWidgets('the model adapter preserves zero and numeric data', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VehicleAlertMessage.fromAlert(
            const VehicleAlert(alertId: 0, alertType: 7, alertData: 8),
          ),
        ),
      ),
    );
    expect(find.text('告警 ID：0 · 类型：7 · 数据：8\n含义待确认'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [2.0, 3.2]) {
      testWidgets('long alert reflows at 320dp, scale $scale, $brightness', (
        tester,
      ) async {
        final description = '${'车辆上报的提醒内容，请核对仪表提示。' * 12}\n${'LONGTOKEN' * 20}';
        await tester.binding.setSurfaceSize(const Size(320, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: Scaffold(
              body: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  GlassSurface(
                    child: VehicleAlertMessage(alertData: '  $description \n'),
                  ),
                  const Text('下一条提醒'),
                ],
              ),
            ),
          ),
        );

        final message = find.text(description);
        expect(message, findsOneWidget);
        final paragraph = tester.renderObject<RenderParagraph>(message);
        expect(paragraph.didExceedMaxLines, isFalse);
        expect(paragraph.size.height, greaterThan(640));
        final bounds = tester.getRect(message);
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(320));
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(find.text('下一条提醒'), 500);
        expect(find.text('下一条提醒').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
