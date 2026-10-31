// 车况摘要进程级缓存：短 TTL 复用 + 并发合并，避免反复 requestVehicleStatus 唤醒车辆。
//
// - UI 各页共用：首页 / 控车弹窗 / 设置 / 地图 / 历史 / 消息
// - 后台 isolate 不共用内存，各自独立
// - 首页主动下拉、控车后：force: true 强制唤醒拉新
// - 进页面 / 静默刷新：TTL 内可复用，不反复叫醒 TBOX

import 'package:mymg/src/rust/api.dart';
import 'package:mymg/src/rust/vehicle/summary.dart';

class SummaryCache {
  SummaryCache._();

  /// 命中窗口：短时间内进多个页面不重复唤醒 TBOX
  static const Duration ttl = Duration(seconds: 30);

  static VehicleSummary? _last;
  static DateTime? _at;
  static Future<VehicleSummary>? _inFlight;

  static void put(VehicleSummary s) {
    _last = s;
    _at = DateTime.now();
  }

  static VehicleSummary? peek() {
    final a = _at;
    if (_last == null || a == null) return null;
    if (DateTime.now().difference(a) > ttl) return null;
    return _last;
  }

  /// 拉摘要。TTL 内直接复用；并发调用合并为一次网络请求。
  static Future<VehicleSummary> fetch({
    required String token,
    required String vin,
    bool force = false,
  }) {
    if (!force) {
      final hit = peek();
      if (hit != null) return Future.value(hit);
      final inflight = _inFlight;
      if (inflight != null) return inflight;
    }
    final f = fetchSummary(token: token, vin: vin).then((s) {
      put(s);
      return s;
    }).whenComplete(() {
      _inFlight = null;
    });
    _inFlight = f;
    return f;
  }
}
