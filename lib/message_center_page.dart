// 消息中心：官方云端告警 + 本地规则告警 + 围栏/移动事件
//
// 数据来源均为本机 SharedPreferences / Summary，不依赖未确认的云端消息接口。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mymg/src/rust/api.dart';
import 'package:mymg/src/rust/vehicle/model.dart';
import 'package:mymg/src/rust/vehicle/summary.dart';

import 'alert_rules.dart';
import 'geofence_service.dart';
import 'official_alert_service.dart';
import 'summary_cache.dart';
import 'theme_controller.dart';
import 'ui_motion.dart';

// bg keys 与 background.dart 同名常量（避免循环依赖，此处重复声明）
const kBgLastRunKey = 'mymg.bg.last_run_ms';

class MessageCenterPage extends StatefulWidget {
  const MessageCenterPage({
    super.key,
    required this.token,
    required this.vin,
  });

  final String token;
  final String vin;

  @override
  State<MessageCenterPage> createState() => _MessageCenterPageState();
}

class _MessageCenterPageState extends State<MessageCenterPage> {
  bool _loading = true;
  String? _error;
  List<_MsgItem> _items = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final items = <_MsgItem>[];
    try {
      // 云端告警（拉最新一次即可；下拉 force=唤醒实时）
      VehicleSummary? s;
      try {
        s = await SummaryCache.fetch(
          token: widget.token,
          vin: widget.vin,
          force: force,
        );
      } catch (e) {
        _error = e.toString();
      }
      if (s != null) {
        await AlertRules.reload();
        AlertRules.rememberFuel(s.fuelPercent);
        final localIds = AlertRules.activeIds(s);
        for (final id in localIds) {
          final rule = AlertRules.byId(id);
          if (rule == null) continue;
          items.add(_MsgItem(
            source: _MsgSource.local,
            severity: rule.severity,
            title: rule.title,
            body: rule.bodyBuilder(),
            time: DateTime.now(),
          ));
        }
        for (final a in s.alerts ?? const <VehicleAlert>[]) {
          items.add(_MsgItem(
            source: _MsgSource.cloud,
            severity: AlertSeverity.warning,
            title: OfficialAlertService.describe(a),
            body: '来自上汽车联服务端 vehicle_alerts',
            time: a.alertTime != null
                ? DateTime.fromMillisecondsSinceEpoch(
                    (a.alertTime! > 1000000000000
                            ? a.alertTime!
                            : a.alertTime! * 1000)
                        .toInt())
                : DateTime.now(),
          ));
        }
      }

      // 围栏配置摘要
      final fence = await GeofenceService.load();
      if (fence.enabled) {
        items.add(_MsgItem(
          source: _MsgSource.system,
          severity: AlertSeverity.info,
          title: '地理围栏监控中',
          body: fence.lat == null
              ? '半径 ${fence.radiusM.round()}m · 中心未设置'
              : '半径 ${fence.radiusM.round()}m · 中心 ${fence.lat!.toStringAsFixed(4)}, ${fence.lng!.toStringAsFixed(4)}',
          time: DateTime.now(),
        ));
      }

      final p = await SharedPreferences.getInstance();
      final lastRun = p.getInt(kBgLastRunKey);
      if (lastRun != null && lastRun > 0) {
        items.add(_MsgItem(
          source: _MsgSource.system,
          severity: AlertSeverity.info,
          title: '后台巡检',
          body:
              '上次拉取 ${DateTime.fromMillisecondsSinceEpoch(lastRun).toString().split('.').first}',
          time: DateTime.fromMillisecondsSinceEpoch(lastRun),
        ));
      }

      // 官方告警 seen 历史（可选）
      final seen = p.getString(kOfficialAlertsSeenKey);
      if (seen != null && seen.isNotEmpty && seen != '[]') {
        try {
          final list = (jsonDecode(seen) as List).cast<String>();
          items.add(_MsgItem(
            source: _MsgSource.cloud,
            severity: AlertSeverity.info,
            title: '云端告警同步',
            body: '已记录 ${list.length} 条服务端告警指纹',
            time: DateTime.now(),
          ));
        } catch (_) {}
      }
    } catch (e) {
      _error ??= e.toString();
    }

    items.sort((a, b) => b.time.compareTo(a.time));
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('消息中心'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () => _load(force: true),
              child: _items.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.all(32),
                      children: [
                        const SizedBox(height: 40),
                        Icon(Icons.notifications_none,
                            size: 56, color: AppPalette.muted),
                        const SizedBox(height: 12),
                        Center(
                          child: Text(
                            _error ?? '暂无消息',
                            style: TextStyle(color: AppPalette.muted),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Center(
                          child: Text(
                            '车况异常、云端告警、围栏进出会出现在这里',
                            style: TextStyle(
                                fontSize: 12, color: AppPalette.subtle),
                          ),
                        ),
                      ],
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
                          child: Text(
                            '共 ${_items.length} 条 · 按时间倒序',
                            style: TextStyle(
                                fontSize: 12, color: AppPalette.muted),
                          ),
                        ),
                        for (var i = 0; i < _items.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: StaggeredAppear(
                              index: i % 6,
                              animate: i < 6,
                              child: _MsgTile(item: _items[i]),
                            ),
                          ),
                      ],
                    ),
            ),
    );
  }
}

enum _MsgSource { cloud, local, system }

class _MsgItem {
  const _MsgItem({
    required this.source,
    required this.severity,
    required this.title,
    required this.body,
    required this.time,
  });

  final _MsgSource source;
  final AlertSeverity severity;
  final String title;
  final String body;
  final DateTime time;
}

class _MsgTile extends StatelessWidget {
  const _MsgTile({required this.item});
  final _MsgItem item;

  @override
  Widget build(BuildContext context) {
    final (icon, color, sourceLabel) = switch (item.source) {
      _MsgSource.cloud => (
          Icons.cloud_outlined,
          AppPalette.info,
          '云端',
        ),
      _MsgSource.local => (
          Icons.shield_outlined,
          AppPalette.warn,
          '本地规则',
        ),
      _MsgSource.system => (
          Icons.settings_suggest_outlined,
          AppPalette.muted,
          '系统',
        ),
    };
    final sevLabel = item.severity.label;
    final time =
        '${item.time.month.toString().padLeft(2, '0')}-${item.time.day.toString().padLeft(2, '0')} '
        '${item.time.hour.toString().padLeft(2, '0')}:${item.time.minute.toString().padLeft(2, '0')}';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.title,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: AppPalette.strong,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          color: color.withOpacity(0.12),
                        ),
                        child: Text(
                          '$sourceLabel · $sevLabel',
                          style: TextStyle(fontSize: 10, color: color),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.body,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppPalette.muted,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(time,
                      style: TextStyle(fontSize: 11, color: AppPalette.subtle)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

