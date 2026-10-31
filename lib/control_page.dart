import 'app_config.dart';
import 'package:flutter/material.dart';
import 'theme_controller.dart';
import 'package:flutter/services.dart';

import 'package:mymg/src/rust/api.dart';
import 'package:mymg/src/rust/vehicle/control.dart';
import 'package:mymg/src/rust/vehicle/summary.dart';

import 'control_config.dart';
import 'summary_cache.dart';
import 'err_util.dart';
import 'pin_vault.dart';

/// 远程控车页面 —— 只做操作与状态展示。
/// 身份 / 品牌 / PIN / 指纹策略 在「设置 → 远程控车」维护。
class ControlPage extends StatefulWidget {
  const ControlPage({super.key});

  @override
  State<ControlPage> createState() => _ControlPageState();
}

class _ControlPageState extends State<ControlPage> {
  final PinVault _vault = PinVault();

  ControlConfig? _cfg;
  VehicleSummary? _summary;
  bool _loading = false;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _loadCreds();
  }

  Future<void> _loadCreds() async {
    final c = await ControlConfig.load();
    if (!mounted) return;
    setState(() => _cfg = c);
    if (c.tokenOk && c.vinOk) {
      await _refresh();
    }
  }

  Future<void> _refresh() async {
    final c = _cfg;
    if (c == null || !c.tokenOk || !c.vinOk) {
      setState(() => _statusMessage = '缺少凭证，请到设置或首页填写');
      return;
    }
    setState(() {
      _loading = true;
      _statusMessage = null;
    });
    try {
      // 手动刷新：强制唤醒拿实时；去掉多余的第二次 fetchVehicleStatus
      final summary = await SummaryCache.fetch(
        token: c.token!,
        vin: c.vin!,
        force: true,
      );
      setState(() => _summary = summary);
    } catch (e) {
      setState(() => _statusMessage = '刷新失败：${formatFrbError(e)}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── 控车操作（官方三步鉴权）────────────────────────────

  Future<void> _doLock() async {
    final pin = await _ensurePin('锁车');
    if (pin == null) return;
    await _runControl(
      label: '锁车',
      call: () => vehicleLock(
        brand: _cfg!.brand,
        token: _cfg!.token!,
        vin: _cfg!.vin!,
        pin: pin,
        userId: _cfg!.userId,
        mobile: _cfg!.mobile,
        headerDeviceId: _cfg!.headerDeviceId,
      ),
    );
  }

  Future<void> _doUnlock() async {
    final pin = await _ensurePin('解锁');
    if (pin == null) return;
    await _runControl(
      label: '解锁',
      call: () => vehicleUnlock(
        brand: _cfg!.brand,
        token: _cfg!.token!,
        vin: _cfg!.vin!,
        pin: pin,
        userId: _cfg!.userId,
        mobile: _cfg!.mobile,
        headerDeviceId: _cfg!.headerDeviceId,
      ),
    );
  }

  Future<void> _doUnlockBoot() async {
    final pin = await _ensurePin('开后备箱');
    if (pin == null) return;
    await _runControl(
      label: '开后备箱',
      call: () => vehicleUnlockBoot(
        brand: _cfg!.brand,
        token: _cfg!.token!,
        vin: _cfg!.vin!,
        pin: pin,
        userId: _cfg!.userId,
        mobile: _cfg!.mobile,
        headerDeviceId: _cfg!.headerDeviceId,
      ),
    );
  }

  Future<void> _doFindCar() async {
    final pin = await _ensurePin('鸣笛找车');
    if (pin == null) return;
    await _runControl(
      label: '鸣笛找车',
      call: () => vehicleFindVehicle(
        brand: _cfg!.brand,
        token: _cfg!.token!,
        vin: _cfg!.vin!,
        pin: pin,
        userId: _cfg!.userId,
        mobile: _cfg!.mobile,
        headerDeviceId: _cfg!.headerDeviceId,
        isFlashing: true,
        hornVolume: 3,
        timeLengthS: 3,
      ),
    );
  }

  Future<void> _doAcOn() async {
    final pin = await _ensurePin('启动空调');
    if (pin == null) return;
    await _runControl(
      label: '启动空调',
      call: () => vehicleAcOn(
        brand: _cfg!.brand,
        token: _cfg!.token!,
        vin: _cfg!.vin!,
        pin: pin,
        userId: _cfg!.userId,
        mobile: _cfg!.mobile,
        headerDeviceId: _cfg!.headerDeviceId,
        targetTempC: 24,
      ),
    );
  }

  Future<void> _doAcOff() async {
    final pin = await _ensurePin('关闭空调');
    if (pin == null) return;
    await _runControl(
      label: '关闭空调',
      call: () => vehicleAcOff(
        brand: _cfg!.brand,
        token: _cfg!.token!,
        vin: _cfg!.vin!,
        pin: pin,
        userId: _cfg!.userId,
        mobile: _cfg!.mobile,
        headerDeviceId: _cfg!.headerDeviceId,
      ),
    );
  }

  /// 拉起官方 App（备用入口）
  Future<void> _openOfficialMgLive() async {
    const channel = MethodChannel('mymg/debug');
    try {
      final outcome = await channel.invokeMethod<Object>(
        'openControl',
        {'package': AppConfig.officialAppPackage},
      );
      if (!mounted) return;
      if (outcome == 'launcher') {
        _toast('已打开官方 App，约 5 秒进入控车页');
      } else {
        _toast('未安装官方 App 或启动失败');
      }
    } catch (e) {
      if (!mounted) return;
      _toast('打开官方 App 失败：$e');
    }
  }

  bool _readyForAction() {
    final c = _cfg;
    if (c == null || !c.tokenOk || !c.vinOk) {
      _toast('请先在设置或首页填写 token + VIN');
      return false;
    }
    return true;
  }

  // ── PIN 解锁流程 ──────────────────────────────────────────────
  //
  // 1) 内存缓存还在有效期 → 直接返回
  // 2) KeyStore 里有持久 PIN → 弹指纹 → 通过即加载到内存
  // 3) 指纹不可用 / 用户取消 → 回退手输 PIN
  // 4) 没保存过 PIN → 弹 PIN 输入框（明文）→ 加密保存
  //
  Future<String?> _ensurePin([String? actionLabel]) async {
    final c = _cfg;
    if (c == null || !c.readyForControl) {
      _toast('请先在「设置 → 远程控车」完成身份、PIN 配置');
      return null;
    }

    final cached = _vault.cachedPin;
    if (cached != null) return cached;

    // 需要指纹：先生物识别，再加载 PIN
    if (c.requireBiometric) {
      final bioOk = await _vault.isBiometricAvailable;
      if (bioOk) {
        final ok = await _vault.authenticate(reason: '解锁控车 PIN');
        if (ok) {
          final p = await _vault.loadIntoMemory();
          if (p != null) {
            if (mounted) setState(() {});
            return p;
          }
        }
        // 指纹失败/取消：回退手输（不强制再弹设置）
        _toast('指纹未通过，请手动输入 PIN');
        return await _askPin(firstTime: false);
      }
      // 用户开了指纹但设备不支持 → 直接手输
      return await _askPin(firstTime: false);
    }

    // 无需指纹：直接用已保存 PIN
    final p = await _vault.loadIntoMemory();
    if (p != null) return p;
    return await _askPin(firstTime: false);
  }

  /// PIN 输入 / 修改对话框。首次 (firstTime=true) 时强制启用"加密保存"。
  Future<String?> _askPin({required bool firstTime}) async {
    final controller = TextEditingController();
    bool remember = firstTime; // 首次默认保存，后续默认也保存（覆盖旧值）

    final pin = await showDialog<String?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(firstTime ? '设置控车密码' : '输入控车密码'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLength: 8,
                obscureText: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '4~8 位数字',
                  counterText: '',
                ),
              ),
              SizedBox(height: 6),
              Text(
                '默认 PIN 通常是 VIN 后 6 位，可在官方 App 里修改',
                style: TextStyle(color: AppPalette.muted, fontSize: 11),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: remember,
                onChanged: firstTime
                    ? null // 首次必须保存
                    : (v) => setS(() => remember = v ?? true),
                title: Text(firstTime
                    ? '加密保存到本机（KeyStore），后续可用指纹验证'
                    : '更新已加密保存的密码'),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final v = controller.text.trim();
                if (v.length < 4 || v.length > 8) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('PIN 必须是 4~8 位数字')),
                  );
                  return;
                }
                Navigator.pop(ctx, v);
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );

    if (pin == null) return null;

    if (remember) {
      await _vault.saveEncrypted(pin);
      await _vault.loadIntoMemory();
      if (mounted) await _loadCreds();
    }
    return pin;
  }

  Future<void> _runControl({
    required Future<ControlOutcome> Function() call,
    required String label,
  }) async {
    setState(() {
      _loading = true;
      _statusMessage = null;
    });
    try {
      final outcome = await call();
      if (!mounted) return;
      if (outcome.accepted) {
        _toast('「$label」已下发${outcome.requestId != null ? "（${outcome.requestId}）" : ""}');
      } else {
        _toast('「$label」失败：${outcome.message ?? "未知错误"}');
      }
    } catch (e) {
      if (!mounted) return;
      _toast('「$label」出错：${formatFrbError(e)}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    // 操作后 1.5s 拉一次最新车况，方便看 lock/climate 变化
    await Future.delayed(const Duration(milliseconds: 1500));
    if (mounted) await _refresh();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── 渲染 ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('远程控车'),
        backgroundColor: Colors.amber.shade100,
        actions: [
          IconButton(
            tooltip: '打开官方 App',
            icon: const Icon(Icons.open_in_new),
            onPressed: _openOfficialMgLive,
          ),
          IconButton(
            tooltip: '刷新车况',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildRoadmapBanner(),
            const SizedBox(height: 8),
            _buildStatusCard(),
            const SizedBox(height: 16),
            _buildActionGrid(),
            const SizedBox(height: 16),
            if (_statusMessage != null) _buildErrorBanner(),
          ],
        ),
      ),
    );
  }

  /// 官方协议提示（启用后）
  Widget _buildRoadmapBanner() {
    return Card(
      color: Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Row(children: [
              Icon(Icons.verified_user_outlined, color: Colors.green),
              SizedBox(width: 8),
              Text('官方控车协议已接入',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ]),
            SizedBox(height: 6),
            Text(
              'randomCode → checkPINCode → 控车。无 mvcode。\n'
              '身份 / 品牌 / PIN / 指纹在「设置 → 远程控车」配置。',
              style: TextStyle(fontSize: 12, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    final s = _summary;
    final loading = _loading && s == null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: loading
            ? Center(child: Padding(
                padding: EdgeInsets.all(12),
                child: CircularProgressIndicator(),
              ))
            : s == null
                ? Text('下拉可刷新车况（需已配置 token/VIN）',
                    style: TextStyle(color: AppPalette.muted))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 油量/续航/里程只在首页展示，控车页只保留安全状态
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          _chip('中控锁', s.allLocked == true ? '已锁' : (s.allLocked == false ? '未锁' : '未知'), s.allLocked == true),
                          _chip('车门', s.allDoorsClosed == true ? '全关' : (s.allDoorsClosed == false ? '有开' : '未知'), s.allDoorsClosed == true),
                          _chip('车窗', s.allWindowsClosed == true ? '全关' : (s.allWindowsClosed == false ? '有开' : '未知'), s.allWindowsClosed == true),
                        ],
                      ),
                    ],
                  ),
      ),
    );
  }

  Widget _chip(String label, String value, bool ok) {
    return Chip(
      avatar: Icon(ok ? Icons.check_circle : Icons.error_outline,
          size: 16, color: ok ? Colors.green : Colors.orange),
      label: Text('$label $value', style: const TextStyle(fontSize: 12)),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _buildActionGrid() {
    final enabled = !_loading && (_cfg?.readyForControl ?? false);
    Widget btn({
      required IconData icon,
      required String label,
      required VoidCallback onTap,
      Color? color,
    }) {
      return InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: enabled ? onTap : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Card(
            child: SizedBox(
              height: 48,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: color, size: 18),
                  SizedBox(height: 3),
                  Text(label,
                      style: const TextStyle(fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!enabled)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              (_cfg?.pinSaved ?? false)
                  ? '控车按钮已就绪（下方）'
                  : '请先到「设置 → 远程控车」配置 userId、手机号、PIN',
              style: TextStyle(fontSize: 12, color: AppPalette.muted),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: btn(
                  icon: Icons.lock_open,
                  label: '解锁',
                  onTap: _doUnlock,
                  color: Colors.orange),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: btn(
                  icon: Icons.lock,
                  label: '锁车',
                  onTap: _doLock,
                  color: Colors.green),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: btn(
                  icon: Icons.notifications_active,
                  label: '找车',
                  onTap: _doFindCar,
                  color: Colors.blue),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: btn(
                  icon: Icons.lock_open_outlined,
                  label: '后备箱',
                  onTap: _doUnlockBoot,
                  color: Colors.brown),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildErrorBanner() {
    return Card(
      color: Colors.red.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          _statusMessage ?? '',
          style: const TextStyle(color: Colors.red, fontSize: 13),
        ),
      ),
    );
  }
}

// ── 工具 ────────────────────────────────────────────────────────────────
//
// 注意：formatFrbError() 见 err_util.dart。
// （之前在本文件里有一个同名 _err 工具，因为只在本文件用；现在两个页面共享
// 后挪到 err_util.dart。）

