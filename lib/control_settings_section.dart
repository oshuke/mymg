// 设置页「远程控车」：ListTile + 弹窗填写，避免平铺混乱。
// 品牌仅保留 MGLive / Roewe（MG 与 MGLive 协议等价，已合并）。

import 'app_config.dart';
import 'package:flutter/material.dart';
import 'theme_controller.dart';
import 'package:flutter/services.dart';

import 'control_config.dart';
import 'pin_vault.dart';

class ControlSettingsSection extends StatefulWidget {
  const ControlSettingsSection({super.key});

  @override
  State<ControlSettingsSection> createState() => _ControlSettingsSectionState();
}

class _ControlSettingsSectionState extends State<ControlSettingsSection> {
  String _brand = 'MGLive';
  String _userId = '';
  String _mobile = '';
  String _devId = 'mymg000000000001';
  bool _requireBio = false;
  bool _pinSaved = false;
  bool _bioSupported = false;
  String _tokenAge = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = await ControlConfig.load();
    final bio = await PinVault().isBiometricAvailable;
    final age = await ControlConfig.tokenAgeSummary();
    if (!mounted) return;
    setState(() {
      // 旧配置若为 MG，统一显示为 MGLive
      _brand = (c.brand == 'MG') ? 'MGLive' : c.brand;
      _userId = c.userId;
      _mobile = c.mobile;
      _devId = c.headerDeviceId;
      _requireBio = c.requireBiometric;
      _pinSaved = c.pinSaved;
      _bioSupported = bio;
      _tokenAge = age;
      final t = c.token ?? '';
      final tail = t.isEmpty
          ? '无token'
          : AppConfig.looksLikeAccessToken(t)
              ? 'ACCESS_TOKEN …${t.substring(t.length - 12)}'
              : '非ACCESS_TOKEN …${t.length > 8 ? t.substring(t.length - 8) : t}';
      _tokenAge = '$age · $tail';
    });
  }

  Future<void> _saveAll() async {
    await ControlConfig.saveIdentity(
      brand: _brand,
      userId: _userId,
      mobile: _mobile,
      headerDeviceId: _devId,
    );
    await ControlConfig.setRequireBiometric(_requireBio);
  }

  Future<void> _editText({
    required String title,
    required String? initial,
    required void Function(String) onSaved,
    String? hint,
    bool obscure = false,
    TextInputType? keyboard,
    List<TextInputFormatter>? formatters,
    int? maxLength,
  }) async {
    final ctrl = TextEditingController(text: initial ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          obscureText: obscure,
          keyboardType: keyboard,
          inputFormatters: formatters,
          maxLength: maxLength,
          decoration: InputDecoration(
            hintText: hint,
            isDense: true,
            counterText: '',
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result != null) {
      onSaved(result);
      await _saveAll();
      if (mounted) setState(() {});
    }
  }

  Future<void> _editPin() async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_pinSaved ? '修改控车密码' : '设置控车密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctrl,
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
              '加密保存到 KeyStore，控车时使用',
              style: TextStyle(fontSize: 11, color: AppPalette.muted),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == null) return;
    final pin = result.trim();
    if (pin.length < 4 || pin.length > 8) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PIN 必须是 4~8 位数字')),
      );
      return;
    }
    await PinVault().saveEncrypted(pin);
    await PinVault().loadIntoMemory();
    if (!mounted) return;
    setState(() => _pinSaved = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('PIN 已加密保存')),
    );
  }

  Future<void> _clearPin() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除控车密码？'),
        content: const Text('清除后下次控车需重新设置 PIN。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清除')),
        ],
      ),
    );
    if (ok != true) return;
    await PinVault().clearEncrypted();
    if (!mounted) return;
    setState(() => _pinSaved = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('控车密码已清除')),
    );
  }

  Future<void> _testBiometric() async {
    setState(() => _tokenAge = _tokenAge); // no-op keep
    final ok = await PinVault().authenticate(reason: '测试指纹解锁');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? '指纹验证通过'
            : '指纹未通过 / 已取消。请确认系统已录入指纹，并重新打开 MYMG'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final brandLabel = _brand == 'Roewe' ? '荣威 Roewe' : '名爵 MG';
    final autoFilled = _userId.isNotEmpty && _mobile.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: Icon(Icons.token_outlined),
          title: Text('access token 有效期'),
          subtitle: Text(_tokenAge, style: TextStyle(fontSize: 12)),
        ),
        // 验证码登录后自动写入的身份：只读展示，无需手填
        ListTile(
          leading: Icon(Icons.person_outline),
          title: Text('登录身份'),
          subtitle: Text(
            [
              if (autoFilled)
                brandLabel
              else
                '未自动登录（缺 userId 或手机号）',
              if (_mobile.isNotEmpty) _maskMobile(_mobile) else '手机空',
              if (_userId.isNotEmpty) _maskId(_userId) else 'userId空',
              if (_pinSaved) 'PIN已保存' else 'PIN未保存',
            ].join(' · '),
            style: TextStyle(fontSize: 12),
          ),
          trailing: autoFilled
              ? Icon(Icons.check_circle, color: Colors.green, size: 18)
              : null,
        ),
        if (!autoFilled)
          Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              '建议用登录页「验证码登录」自动填充 userId / 手机号；控车 PIN 哈希需要这两项。',
              style: TextStyle(fontSize: 11, color: AppPalette.muted, height: 1.4),
            ),
          ),
        SwitchListTile(
          value: _requireBio,
          onChanged: _bioSupported
              ? (v) async {
                  setState(() => _requireBio = v);
                  await _saveAll();
                }
              : null,
          title: const Text('控车前指纹验证'),
          subtitle: Text(
            _bioSupported
                ? (_requireBio ? '开启：每次控车先指纹' : '关闭：直接使用 PIN')
                : '本机未检测到指纹 / 面部特征',
            style: const TextStyle(fontSize: 12),
          ),
        ),
        if (_bioSupported)
          ListTile(
            leading: const Icon(Icons.fingerprint),
            title: const Text('测试指纹'),
            onTap: _testBiometric,
          ),
        ListTile(
          leading: const Icon(Icons.pin_outlined),
          title: const Text('控车密码 PIN'),
          subtitle: Text(_pinSaved ? '已保存（KeyStore 加密）' : '未设置'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: _pinSaved ? '修改' : '设置',
                icon: const Icon(Icons.edit_outlined),
                onPressed: _editPin,
              ),
              if (_pinSaved)
                IconButton(
                  tooltip: '清除',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _clearPin,
                ),
            ],
          ),
          onTap: _editPin,
        ),
        // 高级：DeviceID（一般自动 android_id，仅排查用）
        ExpansionTile(
          leading: const Icon(Icons.settings_outlined, size: 20),
          title: const Text('高级', style: TextStyle(fontSize: 14)),
          subtitle: const Text('一般无需修改', style: TextStyle(fontSize: 11)),
          children: [
            ListTile(
              dense: true,
              title: const Text('DeviceID / Uuid'),
              subtitle: Text(_devId, style: const TextStyle(fontSize: 12)),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () => _editText(
                title: 'DeviceID',
                initial: _devId,
                onSaved: (v) =>
                    _devId = v.trim().isEmpty ? 'mymg000000000001' : v.trim(),
              ),
            ),
            ListTile(
              dense: true,
              title: const Text('品牌'),
              subtitle: Text(brandLabel),
              trailing: const Icon(Icons.chevron_right),
              onTap: _pickBrand,
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _pickBrand() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择品牌'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'MGLive'),
            child: Row(children: [
              const Icon(Icons.directions_car),
              const SizedBox(width: 8),
              const Text('名爵 MG'),
              if (_brand == 'MGLive') ...[
                const Spacer(),
                const Icon(Icons.check, color: Colors.green),
              ],
            ]),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'Roewe'),
            child: Row(children: [
              const Icon(Icons.directions_car),
              const SizedBox(width: 8),
              const Text('荣威 Roewe'),
              if (_brand == 'Roewe') ...[
                const Spacer(),
                const Icon(Icons.check, color: Colors.green),
              ],
            ]),
          ),
        ],
      ),
    );
    if (selected != null && selected != _brand) {
      setState(() => _brand = selected);
      await _saveAll();
    }
  }

  String _maskId(String s) =>
      s.length <= 8 ? s : '${s.substring(0, 4)}****${s.substring(s.length - 4)}';

  String _maskMobile(String s) =>
      s.length <= 7 ? s : '${s.substring(0, 3)}****${s.substring(s.length - 4)}';
}
