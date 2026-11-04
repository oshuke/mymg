import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mymg/ui/app_shell.dart';
import 'package:mymg/ui/home_dashboard.dart';
import 'package:mymg/theme_controller.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double bottomInset = 24,
    double topInset = 0,
    double textScale = 1,
    Brightness brightness = Brightness.light,
    Widget? body,
    ValueChanged<int>? onSelect,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        darkTheme: buildAppTheme(Brightness.dark),
        themeMode: brightness == Brightness.dark
            ? ThemeMode.dark
            : ThemeMode.light,
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            padding: EdgeInsets.only(top: topInset, bottom: bottomInset),
            textScaler: TextScaler.linear(textScale),
          ),
          child: AppShell(
            currentIndex: 2,
            onIndexChanged: onSelect ?? (_) {},
            body: body ?? const SizedBox.expand(key: ValueKey('page-content')),
          ),
        ),
      ),
    );
  }

  testWidgets('capsule floats inside screen and above system navigation area', (
    tester,
  ) async {
    await mount(tester);
    final dock = tester.getRect(find.byKey(const ValueKey('main-navigation')));
    expect(dock.left, 16);
    expect(dock.right, 374);
    expect(dock.height, 68);
    expect(dock.bottom, 844 - 24 - 8);
    expect(
      tester.getRect(find.byKey(const ValueKey('page-content'))).bottom,
      844,
    );
  });

  testWidgets('page paints all the way behind the status bar', (tester) async {
    await mount(tester, topInset: 30);
    expect(tester.getRect(find.byKey(const ValueKey('page-content'))).top, 0);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'transparent app bar in $brightness keeps title and icons legible',
      (tester) async {
        await mount(
          tester,
          topInset: 30,
          brightness: brightness,
          body: Scaffold(
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              title: const Text('页面标题'),
            ),
          ),
        );
        expect(tester.getRect(find.text('页面标题')).top, greaterThanOrEqualTo(30));
        final style = tester.binding.renderViews.first.debugLayer!
            .find<SystemUiOverlayStyle>(const Offset(195, 15));
        expect(style?.statusBarColor, Colors.transparent);
        expect(
          style?.statusBarIconBrightness,
          brightness == Brightness.light ? Brightness.dark : Brightness.light,
        );
      },
    );
  }

  testWidgets('four destinations remain accessible without a settings tab', (
    tester,
  ) async {
    final selected = <int>[];
    final semantics = tester.ensureSemantics();
    try {
      await mount(tester, onSelect: selected.add);
      for (final label in ['首页', '车控', '车况', '位置']) {
        final button = find.bySemanticsLabel(label);
        expect(button, findsOneWidget);
        expect(tester.getSize(button).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
        await tester.tap(button);
      }
      expect(selected, [0, 1, 2, 3]);
      expect(find.text('设置'), findsNothing);
      final selectedColor = tester.widget<Text>(find.text('车况')).style!.color!;
      expect(
        (1.0 + 0.05) / (selectedColor.computeLuminance() + 0.05),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('车况')),
        matchesSemantics(
          label: '车况',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          hasTapAction: true,
        ),
      );
    } finally {
      semantics.dispose();
    }
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0, 3.2]) {
      testWidgets('320dp $brightness ${scale}x text keeps labels visible', (
        tester,
      ) async {
        await mount(
          tester,
          size: const Size(320, 640),
          textScale: scale,
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
        final dock = tester.getRect(
          find.byKey(const ValueKey('main-navigation')),
        );
        for (final label in ['首页', '车控', '车况', '位置']) {
          final text = tester.getRect(find.text(label));
          expect(dock.contains(text.topLeft), isTrue);
          expect(dock.contains(text.bottomRight), isTrue);
        }
      });
    }
  }

  testWidgets(
    'last page action scrolls fully above dock and remains tappable',
    (tester) async {
      var tapped = false;
      await mount(
        tester,
        body: Scaffold(
          body: Builder(
            builder: (context) => ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                16 + MediaQuery.paddingOf(context).bottom,
              ),
              children: [
                const SizedBox(height: 1400),
                FilledButton(
                  onPressed: () => tapped = true,
                  child: const Text('底部操作'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.drag(find.byType(ListView), const Offset(0, -1800));
      await tester.pumpAndSettle();
      final action = tester.getRect(find.byType(FilledButton));
      final dock = tester.getRect(
        find.byKey(const ValueKey('main-navigation')),
      );
      expect(action.bottom, lessThan(dock.top));
      await tester.tap(find.text('底部操作'));
      expect(tapped, isTrue);
    },
  );

  testWidgets('home scrolls behind capsule but final action can clear it', (
    tester,
  ) async {
    var tapped = false;
    await mount(
      tester,
      topInset: 30,
      body: Scaffold(
        body: HomeDashboard(
          summary: null,
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
          details: Column(
            children: [
              const SizedBox(height: 900),
              FilledButton(
                onPressed: () => tapped = true,
                child: const Text('首页末尾操作'),
              ),
            ],
          ),
        ),
      ),
    );
    expect(tester.getRect(find.byType(ListView)).bottom, 844);
    expect(tester.getRect(find.byType(ListView)).top, 0);
    expect(tester.getRect(find.text('MYMG 汽车')).top, greaterThanOrEqualTo(50));
    expect(
      tester.binding.renderViews.first.debugLayer!
          .find<SystemUiOverlayStyle>(const Offset(195, 15))
          ?.statusBarIconBrightness,
      Brightness.light,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -250));
    await tester.pumpAndSettle();
    expect(
      tester.binding.renderViews.first.debugLayer!
          .find<SystemUiOverlayStyle>(const Offset(195, 15))
          ?.statusBarIconBrightness,
      Brightness.dark,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(
      tester.binding.renderViews.first.debugLayer!
          .find<SystemUiOverlayStyle>(const Offset(195, 15))
          ?.statusBarIconBrightness,
      Brightness.dark,
    );
    final dock = tester.getRect(find.byKey(const ValueKey('main-navigation')));
    expect(
      tester.getRect(find.widgetWithText(FilledButton, '首页末尾操作')).bottom,
      lessThan(dock.top),
    );
    await tester.tap(find.text('首页末尾操作'));
    expect(tapped, isTrue);
  });
}
