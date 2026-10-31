// 小组件直接控车宿主：透明壳，指纹验证后下发指令并关闭。
// 不进完整 App UI；失败/取消仅 Toast 后结束。
//
// 路由：/widget_control/<code>
//   1=锁车  2=空调  3=后备箱  4=找车  5=解锁

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'control_config.dart';
import 'err_util.dart';
import 'pin_vault.dart';
import 'src/rust/api.dart';
import 'src/rust/vehicle/control.dart';

class WidgetControlHostPage extends StatefulWidget {
  const WidgetControlHostPage({super.key, this.controlCode});

  /// 1=锁车 2=空调 3=后备箱 4=找车 5=解锁
  final int? controlCode;

  @override
  State<WidgetControlHostPage> createState() => _WidgetControlHostPageState();
}

class _WidgetControlHostPageState extends State<WidgetControlHostPage> {
  static const _channel = MethodChannel('mymg/widget_control');

  bool _done = false;
  String _status = '正在验证指纹...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<int?> _resolveCode() async {
    final fromCtor = widget.controlCode;
    if (fromCtor != null && fromCtor > 0) return fromCtor;
    try {
      final v = await _channel.invokeMethod<int>('controlCode');
      if (v != null && v > 0) return v;
    } catch (_) {}
    final name = ModalRoute.of(context)?.settings.name ?? '';
    final seg = name.split('/').last;
    return int.tryParse(seg);
  }

  String _labelOf(int code) {
    switch (code) {
      case 1:
        return '锁车';
      case 2:
        return '空调';
      case 3:
        return '后备箱';
      case 4:
        return '找车';
      case 5:
        return '解锁';
      default:
        return '控车';
    }
  }

  Future<void> _run() async {
    if (_done) return;
    final code = await _resolveCode();
    if (code == null) {
      await _finish('缺少控车指令');
      return;
    }
    final label = _labelOf(code);

    // 1) 指纹 / 设备凭据 —— 小组件直控强制验证
    final vault = PinVault();
    final bioOk = await vault.authenticate(reason: '小组件$label · 验证指纹');
    if (!bioOk) {
      await _finish('指纹未通过，已取消$label');
      return;
    }

    // 2) 取加密 PIN + 控车身份
    final pin = await vault.loadIntoMemory() ?? await vault.readEncrypted();
    if (pin == null || pin.isEmpty) {
      await _finish('未保存控车 PIN，请先到 App 设置');
      return;
    }
    final cfg = await ControlConfig.load();
    if (!cfg.readyForControl || cfg.token == null || cfg.vin == null) {
      await _finish('控车未配置完整（token/VIN/身份）');
      return;
    }

    setState(() => _status = '正在$label...');

    // 3) 直接下发
    ControlOutcome out;
    try {
      final brand = cfg.brand;
      final token = cfg.token!;
      final vin = cfg.vin!;
      final userId = cfg.userId;
      final mobile = cfg.mobile;
      final deviceId = cfg.headerDeviceId;
      switch (code) {
        case 1:
          out = await vehicleLock(
            brand: brand,
            token: token,
            vin: vin,
            pin: pin,
            userId: userId,
            mobile: mobile,
            headerDeviceId: deviceId,
          );
          break;
        case 5:
          out = await vehicleUnlock(
            brand: brand,
            token: token,
            vin: vin,
            pin: pin,
            userId: userId,
            mobile: mobile,
            headerDeviceId: deviceId,
          );
          break;
        case 3:
          out = await vehicleUnlockBoot(
            brand: brand,
            token: token,
            vin: vin,
            pin: pin,
            userId: userId,
            mobile: mobile,
            headerDeviceId: deviceId,
          );
          break;
        case 4:
          out = await vehicleFindVehicle(
            brand: brand,
            token: token,
            vin: vin,
            pin: pin,
            userId: userId,
            mobile: mobile,
            headerDeviceId: deviceId,
            isFlashing: true,
            hornVolume: 0,
            timeLengthS: 30,
          );
          break;
        case 2:
          out = await vehicleAcOn(
            brand: brand,
            token: token,
            vin: vin,
            pin: pin,
            userId: userId,
            mobile: mobile,
            headerDeviceId: deviceId,
            targetTempC: 24,
          );
          break;
        default:
          await _finish('未知控车码 $code');
          return;
      }
    } catch (e) {
      await _finish('$label失败：${formatFrbError(e)}');
      return;
    }

    final ok = out.accepted;
    final msg = (out.message ?? '').trim();
    await _finish(
      ok
          ? (msg.isEmpty ? '$label已下发' : msg)
          : (msg.isEmpty ? '$label失败' : msg),
    );
  }

  Future<void> _finish(String toast) async {
    if (_done) return;
    _done = true;
    try {
      await _channel.invokeMethod('toast', toast);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(toast)),
        );
      }
    }
    try {
      await _channel.invokeMethod('finish');
    } catch (_) {
      if (mounted) Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            _status,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
      ),
    );
  }
}
