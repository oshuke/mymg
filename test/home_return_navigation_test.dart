import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mymg/ui/home_return_navigator.dart';

class NavigationHarness extends StatefulWidget {
  const NavigationHarness({super.key});
  @override
  State<NavigationHarness> createState() => _NavigationHarnessState();
}

class _NavigationHarnessState extends State<NavigationHarness> {
  bool home = true;
  @override
  Widget build(BuildContext context) => HomeReturnNavigator(
    isHome: home,
    onHome: () => setState(() => home = true),
    child: Scaffold(
      body: Builder(
        builder: (context) => Column(
          children: [
            Text(home ? 'home-content' : 'other-tab-content'),
            TextButton(
              onPressed: () => setState(() => home = false),
              child: const Text('other-tab'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const DetailScreen(title: 'detail-one'),
                ),
              ),
              child: const Text('open-detail'),
            ),
            TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) =>
                    const AlertDialog(content: Text('confirmation')),
              ),
              child: const Text('open-dialog'),
            ),
          ],
        ),
      ),
    ),
  );
}

class DetailScreen extends StatelessWidget {
  const DetailScreen({super.key, required this.title});
  final String title;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: TextButton(
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const DetailScreen(title: 'detail-two'),
        ),
      ),
      child: const Text('deeper'),
    ),
  );
}

void main() {
  final messages = <MethodCall>[];
  setUp(() {
    messages.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('mymg/navigation'), (
          call,
        ) async {
          messages.add(call);
          return true;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('mymg/navigation'), null),
  );

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: NavigationHarness()));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'back from another tab returns home without exiting or arming exit',
    (tester) async {
      await open(tester);
      await tester.tap(find.text('other-tab'));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('home-content'), findsOneWidget);
      expect(messages, isEmpty);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text('再按一次返回桌面'), findsOneWidget);
      expect(messages, isEmpty);
    },
  );

  for (final toolbar in [false, true]) {
    testWidgets(
      'deep page ${toolbar ? 'toolbar' : 'system'} back returns one level at a time',
      (tester) async {
        await open(tester);
        await tester.tap(find.text('other-tab'));
        await tester.pump();
        await tester.tap(find.text('open-detail'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('deeper'));
        await tester.pumpAndSettle();
        if (toolbar) {
          await tester.tap(find.byType(BackButton));
        } else {
          await tester.binding.handlePopRoute();
        }
        await tester.pumpAndSettle();
        expect(find.text('detail-one'), findsOneWidget);
        expect(find.text('detail-two'), findsNothing);
        expect(messages, isEmpty);
        if (toolbar) {
          await tester.tap(find.byType(BackButton));
        } else {
          await tester.binding.handlePopRoute();
        }
        await tester.pumpAndSettle();
        expect(find.text('other-tab-content'), findsOneWidget);
        expect(find.text('detail-one'), findsNothing);
        expect(messages, isEmpty);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('home-content'), findsOneWidget);
        expect(messages, isEmpty);
      },
    );
  }

  testWidgets(
    'dialog back only dismisses the dialog and preserves current tab',
    (tester) async {
      await open(tester);
      await tester.tap(find.text('other-tab'));
      await tester.pump();
      await tester.tap(find.text('open-dialog'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('confirmation'), findsNothing);
      expect(find.text('other-tab-content'), findsOneWidget);
      expect(messages, isEmpty);
    },
  );

  testWidgets('two home backs within two seconds move task to desktop once', (
    tester,
  ) async {
    await open(tester);
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 300));
    expect(messages, isEmpty);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(messages.map((call) => call.method), ['moveToBackground']);
  });

  testWidgets(
    'home back confirmation expires and resets after page navigation',
    (tester) async {
      await open(tester);
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(seconds: 3));
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(messages, isEmpty);
      await tester.tap(find.text('open-detail'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(messages, isEmpty);
    },
  );

  testWidgets('a rejected background request shows an actionable hint', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('mymg/navigation'),
          (_) async => false,
        );
    await open(tester);
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('暂时无法返回桌面，请使用系统主页键'), findsOneWidget);
  });
}
