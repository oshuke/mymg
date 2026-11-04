import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel, SystemNavigator;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'package:mymg/src/rust/api.dart';
import 'package:mymg/src/rust/frb_generated.dart';

import 'alert_rules.dart';
import 'background.dart';
import 'login_page.dart';
import 'legal_documents.dart';
import 'consented_services.dart';
import 'notification_service.dart';
import 'quick_control_sheet.dart';
import 'product_shell.dart';
import 'widget_control_host.dart';
import 'reservation_service.dart';
import 'shortcut_router.dart';
import 'theme_controller.dart';
import 'widget_sync.dart';

const _kTokenKey = 'mymg.token';
const _kVinKey = 'mymg.vin';

/// 调试模式：传 `--dart-define=MYMG_DEBUG_PROBE=...` 触发。
///
/// 配合 `adb logcat -s mymg_core` 看真实请求体/响应体，用于反推
/// 14700/21102 等服务端拒绝的真实字段缺失原因。
///
/// 支持的探针类型：
///   `send_sms`         - 用测试手机号触发 21102 校验失败（缺易盾滑块）
///   `vehicle_status`   - 用占位 token 触发登录态失效
///   `lock`             - 用占位 token/PIN/VIN 触发登录态失效
///   `user_lock`        - 用真实 token/PIN/VIN 触发你车上业务错误（专门用于看
///                        14700 等业务码的"客户端少了哪个字段"）
///
/// `user_lock` 的账号信息通过 `MYMG_TOKEN` / `MYMG_VIN` / `MYMG_PIN` 传入：
///   flutter build apk --dart-define=MYMG_DEBUG_PROBE=user_lock \
///                     --dart-define=MYMG_TOKEN=<访问令牌> \
///                     --dart-define=MYMG_VIN=<17 位 VIN> \
///                     --dart-define=MYMG_PIN=123456
const _kDebugProbe = String.fromEnvironment(
  'MYMG_DEBUG_PROBE',
  defaultValue: '',
);

const _kUserToken = String.fromEnvironment('MYMG_TOKEN', defaultValue: '');
const _kUserVin = String.fromEnvironment('MYMG_VIN', defaultValue: '');
const _kUserPin = String.fromEnvironment('MYMG_PIN', defaultValue: '');

/// Rust 初始化失败时保存的错误信息，供错误页展示
Object? rustInitError;
StackTrace? rustInitStack;

Future<({String? token, String? vin})> _loadCreds() async {
  final p = await SharedPreferences.getInstance();
  return (token: p.getString(_kTokenKey), vin: p.getString(_kVinKey));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, this.initialRoute});

  final String? initialRoute;

  @override
  Widget build(BuildContext context) {
    final platformRoute =
        WidgetsBinding.instance.platformDispatcher.defaultRouteName;
    final isQuick =
        initialRoute == '/quick_control' || platformRoute == '/quick_control';
    // 小组件 ↻：全程透明空白壳，不展示主页
    final isWidgetRefresh =
        initialRoute == '/widget_refresh' || platformRoute == '/widget_refresh';
    // 小组件直接控车：指纹验证后下发，不进完整 UI
    final isWidgetControl =
        (initialRoute?.startsWith('/widget_control') ?? false) ||
        platformRoute.startsWith('/widget_control');

    return ThemeScope(
      controller: ThemeController.instance,
      child: ListenableBuilder(
        listenable: ThemeController.instance,
        builder: (context, _) {
          final themeCtrl = ThemeController.instance;
          return MaterialApp(
            title: 'MYMG',
            theme: buildAppTheme(Brightness.light),
            darkTheme: buildAppTheme(Brightness.dark),
            themeMode: themeCtrl.materialMode,
            // 透明壳时强制透明底，避免主题色挡住桌面
            builder: (context, child) {
              if (!(isQuick || isWidgetRefresh || isWidgetControl))
                return child!;
              return Theme(
                data: Theme.of(context)
                    .copyWith(scaffoldBackgroundColor: Colors.transparent),
                child: child!,
              );
            },
            // ★ 关键：initialRoute='/quick_control' 时 Navigator 会额外生成 '/'，
            //   若 onGenerateRoute 把每条路由都画成控车壳，就会叠出两层弹窗。
            //   这里强制只生成一条路由。
            onGenerateInitialRoutes: (String initial) {
              if (isQuick || initial == '/quick_control') {
                return [
                  MaterialPageRoute(
                    builder: (_) => ConsentGate(
                      onAccepted: startConsentedServices,
                      builder: (_) =>
                          const QuickControlHostPage(standalone: true),
                    ),
                  ),
                ];
              }
              if (isWidgetRefresh || initial == '/widget_refresh') {
                return [
                  MaterialPageRoute(
                    builder: (_) => const ColoredBox(color: Colors.transparent),
                  ),
                ];
              }
              if (isWidgetControl || initial.startsWith('/widget_control')) {
                final code = int.tryParse(initial.split('/').last);
                return [
                  MaterialPageRoute(
                    settings: RouteSettings(name: initial),
                    builder: (_) => ConsentGate(
                      onAccepted: startConsentedServices,
                      builder: (_) => WidgetControlHostPage(controlCode: code),
                    ),
                  ),
                ];
              }
              return [
                MaterialPageRoute(
                  builder: (_) => rustInitError != null
                      ? const _FatalErrorPage()
                      : const _Gate(),
                ),
              ];
            },
            onGenerateRoute: (settings) {
              final name = settings.name ?? '/';
              if (name == '/quick_control') {
                return MaterialPageRoute(
                  builder: (_) => ConsentGate(
                    onAccepted: startConsentedServices,
                    builder: (_) =>
                        const QuickControlHostPage(standalone: true),
                  ),
                );
              }
              if (name == '/widget_refresh') {
                return MaterialPageRoute(
                  builder: (_) => const ColoredBox(color: Colors.transparent),
                );
              }
              if (name.startsWith('/widget_control')) {
                final code = int.tryParse(name.split('/').last);
                return MaterialPageRoute(
                  settings: settings,
                  builder: (_) => ConsentGate(
                    onAccepted: startConsentedServices,
                    builder: (_) => WidgetControlHostPage(controlCode: code),
                  ),
                );
              }
              return MaterialPageRoute(
                builder: (_) => rustInitError != null
                    ? const _FatalErrorPage()
                    : const _Gate(),
              );
            },
            initialRoute: isQuick
                ? '/quick_control'
                : isWidgetRefresh
                ? '/widget_refresh'
                : isWidgetControl
                ? (initialRoute ?? platformRoute)
                : '/',
          );
        },
      ),
    );
  }
}

class _Gate extends StatelessWidget {
  const _Gate();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<({String? token, String? vin})>(
      future: _loadCreds(),
      builder: (ctx, snap) {
        if (snap.hasError) {
          return _FatalErrorPage(error: snap.error, stack: snap.stackTrace);
        }
        if (!snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        // 测试版优先用编译注入的 DEBUG token（--dart-define=MYMG_TOKEN/_VIN）；
        // 正式版走 SharedPreferences（LoginPage 兜底保存）。
        final useDebug = _kUserToken.isNotEmpty || _kUserVin.isNotEmpty;
        final t = useDebug ? _kUserToken : (snap.data?.token ?? '');
        final v = useDebug ? _kUserVin : (snap.data?.vin ?? '');
        developer.log(
          '[MYMG] _Gate debug=$useDebug tokenLen=${t.length} vin=$v',
          name: 'mymg_core',
        );
        final vt = (v.length == 17) ? v : null;
        if (t.isEmpty || vt == null) {
          return const LoginPage();
        }
        return ConsentGate(
          onAccepted: startConsentedServices,
          builder: (_) => ProductShell(token: t, vin: vt),
        );
      },
    );
  }
}

/// 致命错误页：把异常和堆栈完整显示出来，便于在没有 adb 的情况下定位问题
class _FatalErrorPage extends StatelessWidget {
  const _FatalErrorPage({this.error, this.stack});

  final Object? error;
  final StackTrace? stack;

  @override
  Widget build(BuildContext context) {
    final e = error ?? rustInitError;
    final s = stack ?? rustInitStack;
    return Scaffold(
      appBar: AppBar(
        title: const Text('启动失败'),
        backgroundColor: Theme.of(context).colorScheme.errorContainer,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Rust 核心初始化失败，请截图反馈此页面。',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  color: Colors.black.withValues(alpha: 0.05),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      '${e ?? "未知错误"}\n\n${s ?? ""}',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> main() async {
  // 捕获 Flutter 框架内的错误（构建 / 布局 / 绘制异常）
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('[MYMG] FlutterError: ${details.exception}\n${details.stack}');
  };

  // 捕获 Dart 层未被 catch 的异步错误
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      try {
        await RustLib.init();
      } catch (e, st) {
        rustInitError = e;
        rustInitStack = st;
        debugPrint('[MYMG] RustLib.init() 失败: $e\n$st');
      }

      // ★ 路线 A Day 5/6b：告警 + 后台轮询启动
      //
      // NotificationService.init() 内部会请求 POST_NOTIFICATIONS（Android 13+）；
      // 用户拒绝时静默吞掉，告警照样可记录，只是不弹系统通知。
      if (await LegalConsent.isAccepted())
        await NotificationService.instance.init();
      await AlertRules.reload();

      // ★ 长按图标快捷方式：注册通道 + 拉一次冷启动遗留的 action
      //   （真正的跳转由 HomePage 在拿到 token/vin 后执行）
      ShortcutRouter.init();
      await ShortcutRouter.pullInitial();
      // AlarmManager 预约：监听原生到点拉起
      listenReservationAlarm();

      // 注册 WorkManager（一次即可，重复 init 会抛"already initialized"）
      try {
        await Workmanager().initialize(callbackDispatcher);
      } catch (e) {
        debugPrint('[MYMG] Workmanager.initialize 失败: $e');
      }
      // 按当前开关决定是否注册周期任务（默认关）
      unawaited(_applyBackground());

      // 主题偏好（跟随系统/浅色/深色）
      await ThemeController.instance.load();
      runApp(const MyApp());
      _runDebugProbeIfRequested();
      // 小组件 ↻：透明壳已挂 getPending/done，此处静默拉网写回
      unawaited(_handleWidgetSilentRefresh());
    },
    (e, st) {
      debugPrint('[MYMG] 未捕获异常: $e\n$st');
    },
  );
}

/// 小组件 ↻ 静默刷新（透明壳 WidgetRefreshActivity）：
/// getPending=true → 拉车况 → WidgetSync.push → done（原生 finish）。
/// 只在透明壳里跑，全程不展示主页。
///
/// ★ 重要：只有真正进入刷新分支才 invoke `done`。
///   MainActivity 对 `done` 会 finish()——无条件调用会让普通冷启动
///   在 600ms 后把自己关掉。
Future<void> _handleWidgetSilentRefresh() async {
  const ch = MethodChannel('mymg/widget_refresh');
  // 原生 warm-start 兜底：MainActivity 会 invokeMethod('run')
  try {
    ch.setMethodCallHandler((call) async {
      if (call.method == 'run') {
        await _handleWidgetSilentRefresh();
      }
    });
  } catch (_) {}
  bool shouldClose = false;
  try {
    final pending = await ch.invokeMethod<bool>('getPending') ?? false;
    if (!pending) return;
    shouldClose = true;
    if (!await LegalConsent.isAccepted()) return;
    developer.log('[MYMG] 小组件静默刷新开始（透明壳）', name: 'mymg_core');
    try {
      await RustLib.init();
    } catch (_) {}
    final p = await SharedPreferences.getInstance();
    final token = p.getString(_kTokenKey) ?? '';
    final vin = p.getString(_kVinKey) ?? '';
    if (token.isNotEmpty && vin.length == 17) {
      try {
        final s = await fetchSummary(token: token, vin: vin);
        final plate = p.getString('mymg.plate') ?? '';
        await WidgetSync.push(s, vin: vin, plate: plate);
        developer.log(
          '[MYMG] 小组件静默刷新 OK fuel=${s.fuelPercent}',
          name: 'mymg_core',
        );
      } catch (e) {
        developer.log('[MYMG] 小组件静默刷新失败: $e', name: 'mymg_core');
        await WidgetSync.refresh();
      }
    } else {
      await WidgetSync.refresh();
    }
  } catch (e) {
    debugPrint('[MYMG] widget silent refresh: $e');
  } finally {
    if (shouldClose) {
      try {
        await ch.invokeMethod('done');
      } catch (_) {}
    }
  }
}

/// 读 `mymg.bg.enabled`，按值注册或取消后台周期任务
Future<void> _applyBackground() async {
  final p = await SharedPreferences.getInstance();
  final enabled =
      await LegalConsent.isAccepted() &&
      (p.getBool(kBackgroundEnabledKey) ?? false);
  if (enabled) {
    await schedulePeriodicFetch();
  } else {
    await cancelPeriodicFetch();
  }
}

/// 调试探针：编译时 --dart-define MYMG_DEBUG_PROBE=<key> 即可触发。
/// 配合 adb logcat -s mymg_core 看 Rust 的请求体/响应体定位 14700/21102 根因。
Future<void> _runDebugProbeIfRequested() async {
  if (_kDebugProbe.isEmpty) return;
  if (!await LegalConsent.isAccepted()) return;
  developer.log('[MYMG] debug probe start: $_kDebugProbe', name: 'mymg_core');
  await Future.delayed(const Duration(seconds: 3));
  try {
    switch (_kDebugProbe) {
      case 'send_sms':
        // 用一个测试号触发 21102（缺易盾滑块的真实服务端拒绝）
        await authSendSmsCode(phone: '10000000000');
        developer.log(
          '[MYMG] probe send_sms OK (unexpected!)',
          name: 'mymg_core',
        );
        break;
      case 'lock':
        // 缺身份字段时直接失败——现代控车需 userId/mobile/headerDeviceId
        developer.log(
          '[MYMG] probe lock: use Control page (needs userId/mobile/headerDeviceId)',
          name: 'mymg_core',
        );
        break;
      case 'user_lock':
        developer.log(
          '[MYMG] probe user_lock: use Control page UI',
          name: 'mymg_core',
        );
        break;
      case 'mvcode_guess':
        // 已废弃：官方 2.2.4 无 mvcode
        developer.log('[MYMG] mvcode_guess 已废弃（官方无 mvcode）', name: 'mymg_core');
        break;
      case 'vehicle_status':
        await fetchVehicleStatus(token: '00000000', vin: '00000000000000000');
        developer.log('[MYMG] probe vehicle_status done', name: 'mymg_core');
        break;
      default:
        developer.log('[MYMG] unknown probe: $_kDebugProbe', name: 'mymg_core');
    }
  } catch (e) {
    developer.log('[MYMG] probe threw: $e', name: 'mymg_core');
  }
}

/// 淡入 + 微上移的全局页面过渡（Android/iOS 共用）
class _FadeUpPageTransitionsBuilder extends PageTransitionsBuilder {
  const _FadeUpPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.035),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}
