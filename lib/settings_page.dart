// 应用设置页：账号 / 外观 / 刷新 / 控车 / 数字钥匙 / AI / 备份 / 告警 / 保养 / 后台 / 小组件 / 本机数据 / 关于

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mymg/src/rust/api.dart';

import 'ai_settings_section.dart';
import 'alert_rules.dart';
import 'background.dart';
import 'car_image_store.dart';
import 'control_config.dart';
import 'control_settings_section.dart';
import 'digital_key_section.dart';
import 'geofence_service.dart';
import 'login_page.dart';
import 'official_alert_service.dart';
import 'notification_service.dart';
import 'store.dart';
import 'summary_cache.dart';
import 'token_age.dart';
import 'theme_controller.dart';
import 'vehicle_profile.dart';
import 'webdav_settings_section.dart';
import 'widget_sync.dart';

const kAutoRefreshKey = 'mymg.auto_refresh';
const kIntervalMinKey = 'mymg.interval_min';
const kIntervalOptions = [1, 2, 5, 10, 15, 30, 60];

/// 设置页 → 详情页的"内容已更新"信号（本页 setState 时 ping）
class _SettingsRev extends ChangeNotifier {
  void ping() => notifyListeners();
}

/// 分类详情页：内容由设置页提供（状态不回迁），随设置页变化实时重建
class _SectionPage extends StatelessWidget {
  const _SectionPage({required this.title, required this.rev, required this.body});

  final String title;
  final Listenable rev;
  final List<Widget> Function() body;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: AnimatedBuilder(
        animation: rev,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: body(),
        ),
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.token, required this.vin});
  final String token;
  final String vin;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with WidgetsBindingObserver {
  /// 详情页内容仓库：key = 分类名，value = 本次 build 出的 children（点击时推入详情页）
  final Map<String, List<Widget>> _pageBodies = {};

  /// 通知已打开的详情页用最新内容重建（本页 setState 时 ping）
  final _SettingsRev _rev = _SettingsRev();

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _rev.ping();
  }

  bool _autoRefresh = true;
  int _intervalMin = 5;
  bool _alertsEnabled = true;
  bool _officialAlerts = true;
  bool _doorsAlert = true;
  bool _windowsAlert = true;
  bool _unlockedAlert = true;
  bool _lowFuelAlert = true;
  int _lowFuelThreshold = 20;
  int _alertMinLevel = 1;
  int _widgetBgAlpha = 255;
  bool _fenceEnabled = false;
  double _fenceLat = 0;
  double _fenceLng = 0;
  double _fenceRadius = 200;
  bool _fenceMove = true;
  bool _fenceEnterExit = false;
  bool _bgEnabled = false;
  int? _bgLastRunMs;
  String? _bgLastError;
  bool _maintEnabled = true;
  int _maintIntervalKm = 5000;
  int _maintLastKm = 0;
  int? _maintCurrentKm;
  int? _count;
  DateTime? _oldest;
  DateTime? _newest;
  String _brand = 'MGLive';
  String _userId = '';
  String _mobile = '';
  String _tokenAge = '';
  String _plate = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    ControlConfig? cfg;
    String? age;
    try {
      cfg = await ControlConfig.load();
      age = await ControlConfig.tokenAgeSummary();
    } catch (_) {}
    int? count;
    DateTime? oldest;
    DateTime? newest;
    try {
      final store = SnapshotStore.instance;
      count = await store.count(widget.vin);
      final asc = await store.listByRange(vin: widget.vin, limit: 100000);
      if (asc.isNotEmpty) {
        newest = asc.first.capturedAtDt;
        oldest = asc.last.capturedAtDt;
      }
    } catch (_) {}
    int? maintCurrent;
    try {
      final s = await SummaryCache.fetch(token: widget.token, vin: widget.vin);
      maintCurrent = s.odometerKm?.round();
    } catch (_) {}
    String plate = '';
    try {
      plate = await VehicleProfile.plate(force: true);
    } catch (_) {}
    final fence = await GeofenceService.load();
    if (!mounted) return;
    setState(() {
      _autoRefresh = prefs.getBool('mymg.auto_refresh') ?? true;
      _intervalMin = prefs.getInt('mymg.interval_min') ?? 5;
      _alertsEnabled = prefs.getBool(kAlertsEnabledKey) ?? true;
      _officialAlerts = prefs.getBool('mymg.official_alerts') ?? true;
      _doorsAlert = prefs.getBool(kAlertDoorsKey) ?? true;
      _windowsAlert = prefs.getBool(kAlertWindowsKey) ?? true;
      _unlockedAlert = prefs.getBool(kAlertUnlockedKey) ?? true;
      _lowFuelAlert = prefs.getBool(kAlertLowFuelKey) ?? true;
      _lowFuelThreshold = prefs.getInt(kLowFuelThresholdKey) ?? 20;
      _alertMinLevel = prefs.getInt(kAlertMinLevelKey) ?? 1;
      _widgetBgAlpha = prefs.getInt(kWidgetBgAlphaPrefsKey) ?? 255;
      // 自动解锁开关已移到「蓝牙数字钥匙」详情页（_AutoLockTile）
      _fenceEnabled = fence.enabled;
      _fenceLat = fence.lat ?? 0;
      _fenceLng = fence.lng ?? 0;
      _fenceRadius = fence.radiusM;
      _fenceMove = fence.alertMove;
      _fenceEnterExit = fence.alertEnterExit;
      _bgEnabled = prefs.getBool(kBackgroundEnabledKey) ?? false;
      _bgLastRunMs = prefs.getInt(kBgLastRunKey);
      _bgLastError = prefs.getString(kBgLastErrorKey);
      _maintEnabled = prefs.getBool('mymg.maint.enabled') ?? true;
      _maintIntervalKm =
          (prefs.getInt('mymg.maint.interval_km') ?? 5000).clamp(1000, 50000);
      _maintLastKm = prefs.getInt('mymg.maint.last_notified_km') ?? 0;
      _maintCurrentKm = maintCurrent;
      _count = count;
      _oldest = oldest;
      _newest = newest;
      _brand = cfg?.brand ?? 'MGLive';
      _userId = cfg?.userId ?? '';
      _mobile = cfg?.mobile ?? '';
      _tokenAge = age ?? '';
      _plate = plate;
    });
  }


  /// 小组件车辆图 / 背景图：直接从图库选择（PNG 透明底可用）/ 恢复默认
  Future<void> _pickWidgetImage(BuildContext context,
      {required String kind}) async {
    final isCar = kind == 'car';
    final title = isCar ? '小组件车辆图片' : '小组件背景图片';
    final action = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text(title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 15)),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从图库选择'),
              subtitle: const Text('直接打开相册 · PNG 支持透明底'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: Text(isCar ? '恢复默认车图' : '清除背景图'),
              onTap: () => Navigator.pop(ctx, 'reset'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'reset') {
      if (isCar) {
        await WidgetSync.setWidgetCarImage(null);
      } else {
        await WidgetSync.setWidgetBgImage(null);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(isCar ? '小组件车图已恢复默认' : '小组件背景已清除')),
        );
      }
      return;
    }
    if (action == 'gallery') {
      try {
        final picker = ImagePicker();
        final x = await picker.pickImage(
          source: ImageSource.gallery,
          maxWidth: 2048,
          maxHeight: 2048,
          imageQuality: 95,
        );
        if (x == null || !mounted) return;
        final saved = isCar
            ? await CarImageStore.saveFromFile(x.path)
            : await _persistWidgetBg(x.path);
        if (isCar) {
          await WidgetSync.setWidgetCarImage(saved);
        } else {
          await WidgetSync.setWidgetBgImage(saved);
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(isCar ? '小组件车图已更新' : '小组件背景已更新')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('选图失败：$e')),
          );
        }
      }
    }
  }

  /// 小组件背景图落盘到 App 沙盒（与车图分文件）
  Future<String> _persistWidgetBg(String sourcePath) async {
    final dir = await getApplicationDocumentsDirectory();
    final carDir = Directory(p.join(dir.path, 'car'));
    if (!await carDir.exists()) await carDir.create(recursive: true);
    final out = File(p.join(carDir.path, 'widget_bg.png'));
    await out.writeAsBytes(await File(sourcePath).readAsBytes(), flush: true);
    return out.path;
  }
  Future<void> _setAlertsEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kAlertsEnabledKey, v);
    await AlertRules.reload();
    if (mounted) setState(() => _alertsEnabled = v);
  }

  Future<void> _testAlert() async {
    try {
      await NotificationService.instance.notifyPlain(
        title: 'MYMG 测试',
        body: '告警推送通道正常',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已发送测试通知')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('测试通知失败：$e')),
        );
      }
    }
  }
  Future<void> _setDoors(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kAlertDoorsKey, v);
    await AlertRules.reload();
    if (mounted) setState(() => _doorsAlert = v);
  }

  Future<void> _setWindows(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kAlertWindowsKey, v);
    await AlertRules.reload();
    if (mounted) setState(() => _windowsAlert = v);
  }

  Future<void> _setUnlocked(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kAlertUnlockedKey, v);
    await AlertRules.reload();
    if (mounted) setState(() => _unlockedAlert = v);
  }

  Future<void> _setLowFuel(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kAlertLowFuelKey, v);
    await AlertRules.reload();
    if (mounted) setState(() => _lowFuelAlert = v);
  }

  Future<void> _setLowFuelThreshold(int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(kLowFuelThresholdKey, v);
    await AlertRules.reload();
    if (mounted) setState(() => _lowFuelThreshold = v);
  }

  Future<void> _setBgEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kBackgroundEnabledKey, v);
    if (mounted) setState(() => _bgEnabled = v);
    await _applyBackground();
    if (v && mounted) {
      final test = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('测试告警推送？'),
          content: const Text('后台轮询开启后，建议先测一条通知确认权限。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('跳过')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('测试')),
          ],
        ),
      );
      if (test == true) await _testAlert();
    }
  }

  Future<void> _applyBackground() async {
    final p = await SharedPreferences.getInstance();
    final enabled = p.getBool(kBackgroundEnabledKey) ?? false;
    if (enabled) {
      await schedulePeriodicFetch();
    } else {
      await cancelPeriodicFetch();
    }
  }

  Future<void> _cleanOld() async {
    final n = await SnapshotStore.instance.cleanOlderThan(days: 30, vin: widget.vin);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(n == 0 ? '没有 30 天前的数据' : '已删除 $n 条')),
    );
    await _load();
  }

  Future<void> _deleteAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空本机全部快照？'),
        content: const Text('本机数据库的所有快照将清空，无法恢复。\n不影响服务端。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final n = await SnapshotStore.instance.deleteAll(widget.vin);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已删除 $n 条')));
    await _load();
  }

  Future<void> _setFenceFromCurrentCar() async {
    try {
      final s = await SummaryCache.fetch(token: widget.token, vin: widget.vin);
      final lat = double.tryParse(s.latitude ?? '');
      final lng = double.tryParse(s.longitude ?? '');
      if (lat == null || lng == null || (lat == 0 && lng == 0)) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前无有效车辆坐标，请先在主页刷新车况')),
        );
        return;
      }
      await GeofenceService.save(
        enabled: true,
        lat: lat,
        lng: lng,
        radiusM: _fenceRadius,
        alertMove: _fenceMove,
        alertEnterExit: _fenceEnterExit,
      );
      if (!mounted) return;
      setState(() {
        _fenceEnabled = true;
        _fenceLat = lat;
        _fenceLng = lng;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              '围栏中心已设为 ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('获取车辆位置失败：$e')),
      );
    }
  }

  Future<void> _setOfficialAlerts(bool v) async {
    await OfficialAlertService.setEnabled(v);
    if (mounted) setState(() => _officialAlerts = v);
  }

  Future<void> _pickThemeMode(BuildContext context) async {
    final ctrl = ThemeScope.of(context);
    final picked = await showModalBottomSheet<AppThemeMode>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in AppThemeMode.values)
              ListTile(
                leading: Icon(switch (m) {
                  AppThemeMode.system => Icons.brightness_auto,
                  AppThemeMode.light => Icons.light_mode_outlined,
                  AppThemeMode.dark => Icons.dark_mode_outlined,
                }),
                title: Text(switch (m) {
                  AppThemeMode.system => '跟随系统',
                  AppThemeMode.light => '浅色',
                  AppThemeMode.dark => '深色',
                }),
                trailing: ctrl.mode == m ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(ctx, m),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await ThemeController.instance.setMode(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickRefreshInterval() async {
    final v = await showModalBottomSheet<int>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('关闭自动刷新'),
              leading: const Icon(Icons.pause),
              onTap: () => Navigator.pop(ctx, 0),
            ),
            const Divider(height: 1),
            for (final m in kIntervalOptions)
              ListTile(
                title: Text(m == 1 ? '每 1 分钟' : '每 $m 分钟'),
                trailing: _intervalMin == m && _autoRefresh ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(ctx, m),
              ),
          ],
        ),
      ),
    );
    if (v == null) return;
    final p = await SharedPreferences.getInstance();
    if (v == 0) {
      await p.setBool(kAutoRefreshKey, false);
      if (mounted) setState(() => _autoRefresh = false);
    } else {
      await p.setBool(kAutoRefreshKey, true);
      await p.setInt(kIntervalMinKey, v);
      if (mounted) setState(() {
        _autoRefresh = true;
        _intervalMin = v;
      });
    }
  }

  Future<void> _pickMaintSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final cur = _maintCurrentKm;
            final next = _maintLastKm > 0 && cur != null
                ? _maintLastKm + _maintIntervalKm
                : null;
            // 全高可滑：不再限制 72%，内容可滚出屏顶
            final sheetH = MediaQuery.of(ctx).size.height;
            return SafeArea(
              top: false,
              child: SizedBox(
                height: sheetH * 0.96,
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    16,
                    20,
                    20 + MediaQuery.of(ctx).viewInsets.bottom,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(
                            color: AppPalette.track,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        '保养提醒设置',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                          color: AppPalette.strong,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text('提醒间隔',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppPalette.strong)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [1000, 3000, 5000, 10000, 15000].map((km) {
                          return ChoiceChip(
                            label: Text(
                                km >= 1000 ? '${km ~/ 1000}k km' : '$km km'),
                            selected: _maintIntervalKm == km,
                            onSelected: (_) async {
                              setSheet(() => _maintIntervalKm = km);
                              final p = await SharedPreferences.getInstance();
                              await p.setInt('mymg.maint.interval_km', km);
                              setState(() {});
                            },
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 20),
                      Text('上次提醒里程',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppPalette.strong)),
                      const SizedBox(height: 8),
                      if (cur != null)
                        Text('系统当前：$cur km',
                            style: TextStyle(
                                fontSize: 12, color: AppPalette.muted)),
                      const SizedBox(height: 10),
                      TextFormField(
                        initialValue: _maintLastKm > 0
                            ? '$_maintLastKm'
                            : (cur?.toString() ?? ''),
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: '上次提醒里程（可改）',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          isDense: false,
                          suffixText: 'km',
                          suffixStyle: TextStyle(color: AppPalette.muted),
                        ),
                        onChanged: (v) {
                          final n = int.tryParse(v.trim());
                          if (n != null) setSheet(() => _maintLastKm = n);
                        },
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.tonal(
                          onPressed: cur == null
                              ? null
                              : () async {
                                  setSheet(() => _maintLastKm = cur);
                                  final p =
                                      await SharedPreferences.getInstance();
                                  await p.setInt(
                                      'mymg.maint.last_notified_km', cur);
                                  setState(() {});
                                },
                          child: const Text('用系统当前里程'),
                        ),
                      ),
                      if (next != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppPalette.chipBg,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '下次提醒约：$next km（还差 ${next - (cur ?? next)} km）',
                            style: TextStyle(
                                fontSize: 13, color: AppPalette.strong),
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onPressed: () async {
                          final p = await SharedPreferences.getInstance();
                          await p.setInt(
                              'mymg.maint.last_notified_km', _maintLastKm);
                          if (ctx.mounted) Navigator.pop(ctx);
                          await _load();
                        },
                        child: const Text('保存'),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final oldest = _oldest;
    final newest = _newest;
    final rangeText = (oldest == null || newest == null)
        ? '还没有历史数据'
        : '${_fmt(oldest)} → ${_fmt(newest)}';
    final brandLabel = _brand == 'Roewe' ? '荣威 Roewe' : '名爵 MG';
    final maintNext = _maintLastKm > 0 && _maintCurrentKm != null
        ? _maintLastKm + _maintIntervalKm
        : null;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _collapsible(
            icon: Icons.person_outline,
            title: '账号',
            subtitle: brandLabel,
            children: [
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text(brandLabel),
            subtitle: Text(
              [
                if (_mobile.isNotEmpty) _mask(_mobile, 3, 4),
                if (_userId.isNotEmpty) _mask(_userId, 4, 4),
                if (_tokenAge.isNotEmpty) _tokenAge,
              ].join(' · '),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.directions_car_outlined),
            title: const Text('车辆'),
            subtitle: Text(
              [
                if (_plate.isNotEmpty) _plate else '车牌未获取',
                _mask(widget.vin, 6, 4),
              ].join(' · '),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          ]),
          const Divider(height: 1, indent: 16, endIndent: 16),
          _collapsible(
            icon: Icons.brightness_6_outlined,
            title: '外观',
            subtitle: ThemeScope.of(context).label,
            children: [
          Builder(
            builder: (context) {
              final ctrl = ThemeScope.of(context);
              return ListTile(
                leading: const Icon(Icons.brightness_6_outlined),
                title: const Text('主题'),
                subtitle: Text(ctrl.label),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _pickThemeMode(context),
              );
            },
          ),

          ]),
          const Divider(height: 1, indent: 16, endIndent: 16),
          _collapsible(
            icon: Icons.sync_outlined,
            title: '数据刷新',
            subtitle: _autoRefresh ? '每 $_intervalMin 分钟' : '已关闭',
            children: [
          ListTile(
            leading: const Icon(Icons.sync_outlined),
            title: const Text('自动刷新'),
            subtitle: Text(_autoRefresh ? '每 $_intervalMin 分钟' : '已关闭'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickRefreshInterval,
          ),

          ]),
          const Divider(height: 1, indent: 16, endIndent: 16),
          _collapsible(
            icon: Icons.settings_remote,
            title: '远程控车',
            subtitle: '账号 · 控车密码 · 品牌',
            children: [
          const ControlSettingsSection(),
          ]),

          const Divider(height: 1, indent: 16, endIndent: 16),
          const DigitalKeyEntryTile(),

          const Divider(height: 1, indent: 16, endIndent: 16),
          _collapsible(
            icon: Icons.auto_awesome,
            title: 'AI 智能分析',
            subtitleWidget: const AiSettingsSummary(),
            children: const [AiSettingsSection()],
          ),

          const Divider(height: 1, indent: 16, endIndent: 16),
          _collapsible(
            icon: Icons.cloud_outlined,
            title: '坚果云备份',
            subtitleWidget: const WebDavSettingsSummary(),
            children: const [WebDavSettingsSection()],
          ),

          const Divider(height: 1, indent: 16, endIndent: 16),
          _collapsible(
            icon: Icons.notifications_none,
            title: '告警推送',
            subtitle: _alertsEnabled ? '已开启' : '已关闭',
            children: [
          SwitchListTile(
            value: _alertsEnabled,
            onChanged: _setAlertsEnabled,
            title: const Text('开启告警推送'),
          ),
          SwitchListTile(
            dense: true,
            value: _officialAlerts,
            onChanged: _setOfficialAlerts,
            title: const Text('云端告警（vehicle_alerts）'),
            subtitle: const Text('服务端告警差集推送，与本地规则互补',
                style: TextStyle(fontSize: 12)),
          ),
          if (_alertsEnabled) ...[
            ListTile(
              dense: true,
              title: const Text('推送级别', style: TextStyle(fontSize: 13)),
              subtitle: Text(
                const ['全部（含提示）', '警告及以上', '仅严重'][_alertMinLevel],
                style: const TextStyle(fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                final v = await showModalBottomSheet<int>(
                  context: context,
                  builder: (ctx) => SafeArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ListTile(
                          title: const Text('全部（含提示）'),
                          trailing:
                              _alertMinLevel == 0 ? const Icon(Icons.check) : null,
                          onTap: () => Navigator.pop(ctx, 0),
                        ),
                        ListTile(
                          title: const Text('警告及以上'),
                          trailing:
                              _alertMinLevel == 1 ? const Icon(Icons.check) : null,
                          onTap: () => Navigator.pop(ctx, 1),
                        ),
                        ListTile(
                          title: const Text('仅严重'),
                          trailing:
                              _alertMinLevel == 2 ? const Icon(Icons.check) : null,
                          onTap: () => Navigator.pop(ctx, 2),
                        ),
                      ],
                    ),
                  ),
                );
                if (v == null) return;
                await AlertRules.setMinLevel(v);
                if (mounted) setState(() => _alertMinLevel = v);
              },
            ),
            SwitchListTile(
              dense: true,
              value: _doorsAlert,
              onChanged: _setDoors,
              title: const Text('车门未关'),
            ),
            SwitchListTile(
              dense: true,
              value: _windowsAlert,
              onChanged: _setWindows,
              title: const Text('车窗未关'),
            ),
            SwitchListTile(
              dense: true,
              value: _unlockedAlert,
              onChanged: _setUnlocked,
              title: const Text('车门未锁（严重）'),
            ),
            SwitchListTile(
              dense: true,
              value: _lowFuelAlert,
              onChanged: _setLowFuel,
              title: Text('油量过低（$_lowFuelThreshold%）'),
            ),
            ListTile(
              dense: true,
              title: Row(
                children: [
                  const Text('油量阈值', style: TextStyle(fontSize: 13)),
                  const Spacer(),
                  Text('$_lowFuelThreshold%', style: const TextStyle(fontWeight: FontWeight.w600)),
                ],
              ),
              subtitle: Slider(
                value: _lowFuelThreshold.toDouble(),
                min: 5,
                max: 50,
                divisions: 9,
                onChanged: (v) => _setLowFuelThreshold(v.round()),
              ),
            ),
          ],

          ]),
          const Divider(height: 1, indent: 16, endIndent: 16),
          _collapsible(
            icon: Icons.place_outlined,
            title: '地理围栏 / 异常移动',
            subtitle: _fenceEnabled ? '已启用' : '未启用',
            children: [
          SwitchListTile(
            value: _fenceEnabled,
            title: const Text('启用围栏与移动提醒'),
            subtitle: const Text('按后台拉取的 GPS 判断进出/大位移', style: TextStyle(fontSize: 12)),
            onChanged: (v) async {
              await GeofenceService.save(
                enabled: v,
                lat: _fenceLat,
                lng: _fenceLng,
                radiusM: _fenceRadius,
                alertMove: _fenceMove,
                alertEnterExit: _fenceEnterExit,
              );
              setState(() => _fenceEnabled = v);
            },
          ),
          if (_fenceEnabled) ...[
            ListTile(
              dense: true,
              title: const Text('围栏中心', style: TextStyle(fontSize: 13)),
              subtitle: Text(
                _fenceLat == null
                    ? '未设置（用当前车辆坐标）'
                    : '${_fenceLat!.toStringAsFixed(5)}, ${_fenceLng!.toStringAsFixed(5)}',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: TextButton(
                onPressed: _setFenceFromCurrentCar,
                child: const Text('用车辆位置'),
              ),
            ),
            ListTile(
              dense: true,
              title: Row(
                children: [
                  const Text('半径', style: TextStyle(fontSize: 13)),
                  const Spacer(),
                  Text('${_fenceRadius.round()} m',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ],
              ),
              subtitle: Slider(
                value: _fenceRadius,
                min: 50,
                max: 1000,
                divisions: 19,
                onChanged: (v) => setState(() => _fenceRadius = v),
                onChangeEnd: (v) async {
                  await GeofenceService.save(
                    enabled: true,
                    lat: _fenceLat,
                    lng: _fenceLng,
                    radiusM: v,
                    alertMove: _fenceMove,
                    alertEnterExit: _fenceEnterExit,
                  );
                },
              ),
            ),
            SwitchListTile(
              dense: true,
              value: _fenceEnterExit,
              title: const Text('进出围栏时提醒'),
              onChanged: (v) async {
                await GeofenceService.save(
                  enabled: true,
                  lat: _fenceLat,
                  lng: _fenceLng,
                  radiusM: _fenceRadius,
                  alertMove: _fenceMove,
                  alertEnterExit: v,
                );
                setState(() => _fenceEnterExit = v);
              },
            ),
            SwitchListTile(
              dense: true,
              value: _fenceMove,
              title: const Text('异常移动提醒（≥400m）'),
              onChanged: (v) async {
                await GeofenceService.save(
                  enabled: true,
                  lat: _fenceLat,
                  lng: _fenceLng,
                  radiusM: _fenceRadius,
                  alertMove: v,
                  alertEnterExit: _fenceEnterExit,
                );
                setState(() => _fenceMove = v);
              },
            ),
          ],

          ]),
          const Divider(height: 1, indent: 16, endIndent: 16),
          _collapsible(
            icon: Icons.build_outlined,
            title: '保养提醒',
            subtitle: _maintEnabled ? '已开启' : '已关闭',
            children: [
          ListTile(
            leading: const Icon(Icons.build_outlined),
            title: const Text('保养提醒'),
            subtitle: Text(
              _maintEnabled
                  ? '每 ${_maintIntervalKm >= 1000 ? '${_maintIntervalKm ~/ 1000}k' : '$_maintIntervalKm'} km'
                      '${maintNext != null ? ' · 下次约 $maintNext km' : ''}'
                  : '已关闭',
              style: const TextStyle(fontSize: 12),
            ),
            trailing: Switch(
              value: _maintEnabled,
              onChanged: (v) async {
                final p = await SharedPreferences.getInstance();
                await p.setBool('mymg.maint.enabled', v);
                setState(() => _maintEnabled = v);
              },
            ),
          ),
          if (_maintEnabled)
            ListTile(
              dense: true,
              leading: const Icon(Icons.tune, size: 20),
              title: const Text('间隔 / 上次提醒里程'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: _pickMaintSettings,
            ),

          ]),
          const Divider(height: 1, indent: 16, endIndent: 16),
          _collapsible(
            icon: Icons.schedule_outlined,
            title: '后台轮询',
            subtitle: _bgEnabled ? '已开启' : '已关闭',
            children: [
          SwitchListTile(
            value: _bgEnabled,
            onChanged: _setBgEnabled,
            title: const Text('App 关闭时拉车况'),
            subtitle: Text(
              _bgLastRunMs == null
                  ? '尚无运行记录'
                  : '上次：${_fmtFull(_bgLastRunMs!)}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          if (_bgLastError != null && _bgLastError!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(_bgLastError!,
                  style: const TextStyle(fontSize: 12, color: Colors.red)),
            ),

          ]),
          const Divider(height: 1, indent: 16, endIndent: 16),
          _collapsible(
            icon: Icons.widgets_outlined,
            title: '桌面小组件',
            subtitle: '图片 · 透明度 · 刷新',
            children: [
          ListTile(
            leading: const Icon(Icons.directions_car_outlined),
            title: const Text('小组件车辆图片'),
            subtitle: const Text('仅小组件使用 · 支持 PNG 透明底'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickWidgetImage(context, kind: 'car'),
          ),
          ListTile(
            leading: const Icon(Icons.wallpaper_outlined),
            title: const Text('小组件背景图片'),
            subtitle: const Text('按钮和信息悬浮于背景之上'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickWidgetImage(context, kind: 'bg'),
          ),
          ListTile(
            leading: const Icon(Icons.opacity_outlined),
            title: const Text('背景透明度'),
            subtitle: Slider(
              value: (_widgetBgAlpha / 255).clamp(0.0, 1.0),
              min: 0,
              max: 1,
              divisions: 25,
              label: '${(_widgetBgAlpha / 255 * 100).round()}%',
              onChanged: (v) {
                setState(() => _widgetBgAlpha = (v * 255).round());
              },
              onChangeEnd: (v) async {
                await WidgetSync.setWidgetBgAlpha((v * 255).round());
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: const Text('刷新桌面小组件'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final messenger = ScaffoldMessenger.of(context);
              final ok = await WidgetSync.refresh();
              if (!mounted) return;
              messenger.showSnackBar(
                SnackBar(content: Text(ok ? '已请求刷新小组件' : '刷新失败，请先在桌面添加 MYMG 小组件')),
              );
            },
          ),

          ]),
          const Divider(height: 1, indent: 16, endIndent: 16),
          _collapsible(
            icon: Icons.storage_outlined,
            title: '本机数据',
            subtitle: _count == null ? '读取中…' : '$_count 个数据点',
            children: [
          ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: Text(_count == null ? '正在读取…' : '共 $_count 个数据点'),
            subtitle: Text(rangeText, style: const TextStyle(fontSize: 12)),
          ),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('清理 30 天前'),
            onTap: _cleanOld,
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.red),
            title: const Text('清空全部快照', style: TextStyle(color: Colors.red)),
            onTap: _deleteAll,
          ),

          ]),
          const Divider(height: 1, indent: 16, endIndent: 16),
          _collapsible(
            icon: Icons.info_outline,
            title: '关于',
            subtitle: '版本 · 本车档案 · 功能一览',
            children: [
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('MYMG · 车况与智能控车'),
            subtitle: const Text(
              '自建上汽车联客户端\nFlutter UI + Rust 核心 · 油箱按 45L 估算油耗\n'
              '云端告警来自 getVehicleStatus.vehicle_alerts',
              style: TextStyle(fontSize: 12, height: 1.45),
            ),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.directions_car_outlined),
            title: const Text('本车档案'),
            subtitle: Text(
              [
                if (_plate.isNotEmpty) _plate,
                _mask(widget.vin, 6, 4),
                '燃油 · 45L',
              ].join(' · '),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.route_outlined),
            title: const Text('功能一览'),
            subtitle: const Text(
              '实时车况 · 历史曲线 · AI 解读 · 智能控车 · 围栏 · 消息中心 · CSV 导出',
              style: TextStyle(fontSize: 12),
            ),
          ),

          ]),
          const Divider(height: 1, indent: 16, endIndent: 16),
          _collapsible(
            icon: Icons.logout,
            title: '账户',
            children: [
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text('退出登录 / 重新登录', style: TextStyle(color: Colors.red)),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('退出登录？'),
                  content: const Text('清除本机 token / VIN，回到登录页。'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('退出', style: TextStyle(color: Colors.red)),
                    ),
                  ],
                ),
              );
              if (ok != true || !mounted) return;
              await TokenAge.clear();
              final p = await SharedPreferences.getInstance();
              await p.remove('mymg.vin');
              if (!mounted) return;
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const LoginPage()),
                (_) => false,
              );
            },
          ),
          ]),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// 分类入口行：设置页只列分类，点右侧 `>` 进**详情页**（与「蓝牙数字钥匙」一致）。
  ///
  /// 状态仍留在本页（不做大搬迁）：把本次 build 出的 children 存进 `_pageBodies`，
  /// 详情页通过 `_rev` 监听——本页任何 setState 都会 ping，详情页随即用最新 children 重建。
  Widget _collapsible({
    required IconData icon,
    required String title,
    String? subtitle,
    Widget? subtitleWidget,
    required List<Widget> children,
  }) {
    _pageBodies[title] = children;
    final sub = subtitleWidget ??
        ((subtitle == null || subtitle.isEmpty)
            ? null
            : Text(subtitle, style: const TextStyle(fontSize: 12)));
    return ListTile(
      leading: Icon(icon, size: 22),
      title: Text(
        title,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      subtitle: sub,
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _SectionPage(
            title: title,
            rev: _rev,
            body: () => _pageBodies[title] ?? const <Widget>[],
          ),
        ),
      ),
    );
  }

  String _fmt(DateTime dt) =>
      '${dt.month}-${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  String _fmtFull(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  String _mask(String s, int head, int tail) {
    if (s.length <= head + tail) return s;
    return '${s.substring(0, head)}${'•' * 4}${s.substring(s.length - tail)}';
  }
}
