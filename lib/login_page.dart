import 'app_config.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import 'theme_controller.dart';

import 'package:flutter/services.dart'
    show Clipboard, FilteringTextInputFormatter, MethodChannel, TextInputType;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mymg/src/rust/api.dart';

import 'car_side_illustration.dart';
import 'control_config.dart';
import 'err_util.dart';
import 'legal_documents.dart';
import 'product_shell.dart';
import 'pin_vault.dart';
import 'token_age.dart';
import 'ui_motion.dart';
import 'vehicle_profile.dart';

const _kTokenKey = 'mymg.token';
const _kVinKey = 'mymg.vin';
const _kPhoneKey = 'mymg.phone';

/// 登录页：验证码登录优先；token 粘贴为备用折叠。
/// captchaId / userId / 手机号 均自动处理，无需用户填。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  // 品牌：登录时选择并写入控车配置
  String _brand = 'MGLive';

  final _phoneCtrl = TextEditingController();
  final _smsCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();

  // 备用：token 登录
  bool _showTokenLogin = false;
  final _tokenCtrl = TextEditingController();
  final _vinCtrl = TextEditingController();

  /// Token 登录可选：清数据后无法自动拉 userId/手机时手动补
  final _tokenUserIdCtrl = TextEditingController();

  bool _saving = false;
  bool _smsSending = false;
  bool _smsLogging = false;
  String? _error;
  String? _smsHint;
  bool _agreed = false;
  int _smsCountdown = 0;
  Timer? _smsTimer;

  /// 滑块验证码 captchaId（构建时通过 --dart-define=MYMG_CAPTCHA_ID 注入）
  static const _captchaId = AppConfig.captchaId;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      final last = p.getString(_kPhoneKey);
      if (last != null && last.isNotEmpty && mounted) {
        _phoneCtrl.text = last;
      }
      final brand = p.getString(kControlBrandKey);
      if (brand != null && brand.isNotEmpty && mounted) {
        setState(() => _brand = brand == 'MG' ? 'MGLive' : brand);
      }
    });
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _smsCtrl.dispose();
    _pinCtrl.dispose();
    _tokenCtrl.dispose();
    _vinCtrl.dispose();
    _tokenUserIdCtrl.dispose();
    _smsTimer?.cancel();
    super.dispose();
  }

  Future<bool> _requireAgreement() async {
    if (!_agreed) {
      setState(() => _error = '请先阅读并同意用户协议和隐私政策');
      return false;
    }
    try {
      await LegalConsent.accept();
      return mounted;
    } catch (_) {
      if (mounted) setState(() => _error = '无法保存协议确认，请重试');
      return false;
    }
  }

  Future<String> _deviceId() async {
    try {
      return await const MethodChannel('mymg/debug')
              .invokeMethod<String>('getAndroidId') ??
          'mymg000000000001';
    } catch (_) {
      return 'mymg000000000001';
    }
  }

  Future<void> _sendSms() async {
    if (!await _requireAgreement()) return;
    final phone = _phoneCtrl.text.trim();
    if (!RegExp(r'^1\d{10}$').hasMatch(phone)) {
      setState(() => _error = '请输入 11 位手机号');
      return;
    }

    setState(() {
      _smsSending = true;
      _error = null;
      _smsHint = '请完成滑块验证…';
    });

    String? validate;
    try {
      final resCh = const MethodChannel('mymg/captcha');
      await resCh.invokeMethod('clear');
      final ch = const MethodChannel('mymg/debug');
      await ch.invokeMethod('openCaptcha', {'captchaId': _captchaId});
      for (var i = 0; i < 120; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        final m = await resCh.invokeMapMethod<String, dynamic>('getResult');
        if (m == null) continue;
        final ready = m['ready'] == true;
        final v = m['validate'] as String?;
        final err = m['error'] as String?;
        if (ready ||
            (v != null && v.isNotEmpty) ||
            (err != null && err.isNotEmpty)) {
          await resCh.invokeMethod('clear');
          if (v != null && v.isNotEmpty) {
            validate = v;
            if (mounted) setState(() => _smsHint = '滑块通过，正在发送验证码…');
            break;
          }
          if (mounted) {
            setState(() {
              _error = err ?? '滑块验证失败或取消';
              _smsHint = null;
              _smsSending = false;
            });
          }
          return;
        }
      }
      if (validate == null || validate.isEmpty) {
        if (mounted) {
          setState(() {
            _error = '滑块验证超时或未完成';
            _smsHint = null;
            _smsSending = false;
          });
        }
        return;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '打开滑块失败：$e';
        _smsHint = null;
        _smsSending = false;
      });
      return;
    }

    try {
      final deviceId = await _deviceId();
      await authSendSmsCodeFull(
        phone: phone,
        captchaId: _captchaId,
        captchaValidate: validate,
        deviceId: deviceId,
      );
      if (!mounted) return;
      setState(() {
        _smsHint = '验证码已发送';
        _smsCountdown = 60;
      });
      _smsTimer?.cancel();
      _smsTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted || _smsCountdown <= 1) {
          t.cancel();
          if (mounted) setState(() => _smsCountdown = 0);
          return;
        }
        setState(() => _smsCountdown--);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '发送失败：${formatFrbError(e)}';
        _smsHint = null;
      });
    } finally {
      if (mounted) setState(() => _smsSending = false);
    }
  }

  Future<void> _loginBySms() async {
    if (!await _requireAgreement()) return;
    final phone = _phoneCtrl.text.trim();
    final code = _smsCtrl.text.trim();
    if (!RegExp(r'^1\d{10}$').hasMatch(phone)) {
      setState(() => _error = '请输入 11 位手机号');
      return;
    }
    if (code.isEmpty) {
      setState(() => _error = '请输入短信验证码');
      return;
    }
    setState(() {
      _smsLogging = true;
      _error = null;
    });
    try {
      final deviceId = await _deviceId();
      final r = await authLoginBySmsDevice(
        phone: phone,
        code: code,
        deviceId: deviceId,
      );
      if (!mounted) return;

      var token = r.token;
      var userId = r.userId ?? '';
      String? activateWarn;
      try {
        final activated = await authActivateToken(
          loginToken: token,
          userId: userId,
          deviceId: deviceId,
        );
        // 官方 getOutSideServiceToken 返回 data.swapToken，优先用于控车
        if (activated.isNotEmpty) token = activated;
      } catch (e) {
        activateWarn = 'token 激活未完成：${formatFrbError(e)}';
      }
      if (!AppConfig.looksLikeAccessToken(token)) {
        activateWarn =
            activateWarn ??
            '当前 token 可能不是 ACCESS_TOKEN；若控车 14101，请改用 Token 登录。';
      } else {
        activateWarn =
            activateWarn ?? '已使用 swap/ACCESS_TOKEN，可尝试控车；若仍 14101 再用 Token 登录。';
      }

      // userId 可能是数字或空 → 再拉一次
      if (userId.isEmpty) {
        try {
          final fetched = await authFetchUserId(
            token: token,
            deviceId: deviceId,
          );
          if (fetched != null && fetched.isNotEmpty) userId = fetched;
        } catch (_) {}
      }

      // 自动落库：token / 手机号 / userId / 品牌 / 与登录一致的 deviceId
      // ★ userId 为空时不要覆盖掉本机已有身份，否则控车会显示「未自动登录」
      final prev = await ControlConfig.load();
      if (userId.isEmpty) userId = prev.userId;
      final p = await SharedPreferences.getInstance();
      await p.setString(_kTokenKey, token);
      await p.setString(_kPhoneKey, phone);
      await TokenAge.capture(token);
      await ControlConfig.saveIdentity(
        brand: _brand,
        userId: userId,
        mobile: phone,
        headerDeviceId: deviceId,
      );

      String vin = '';
      String? plate = '';
      String? vinErr;
      try {
        final list = await authFetchVinsUser(token: token, userId: userId);
        if (list.isNotEmpty) {
          vin = list.first.vin;
          plate = list.first.plate;
        }
      } catch (e) {
        vinErr = formatFrbError(e);
      }
      if (vin.length != 17) {
        try {
          final list = await authFetchVins(token: token);
          if (list.isNotEmpty) {
            vin = list.first.vin;
            plate = plate ?? list.first.plate;
          }
        } catch (e) {
          vinErr = vinErr ?? formatFrbError(e);
        }
      }

      if (plate != null && plate.isNotEmpty) {
        await VehicleProfile.setPlate(plate);
      }

      if (vin.length != 17) {
        setState(() {
          _smsLogging = false;
          _tokenCtrl.text = token;
          _vinCtrl.text = '';
          _showTokenLogin = true;
          _error = activateWarn != null
              ? '$activateWarn\n登录已保存，请补填 VIN。'
              : vinErr == null
              ? '登录成功！token/userId 已保存，请补填 VIN 后保存。'
              : '登录成功！token/userId 已保存。取 VIN 未成功，请补填 VIN。\n$vinErr';
        });
        return;
      }

      await p.setString(_kVinKey, vin);
      if (_pinCtrl.text.trim().isNotEmpty) {
        await PinVault().saveEncrypted(_pinCtrl.text.trim());
      }
      if (!mounted) return;
      if (activateWarn != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(activateWarn)));
      }
      if (!AppConfig.looksLikeAccessToken(token)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '验证码登录成功，但当前 token 可能不是 ACCESS_TOKEN；'
              '若控车报 14101，请改用「Token 登录」粘贴官方 App 的 ACCESS_TOKEN。',
            ),
          ),
        );
      }
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ProductShell(token: token, vin: vin),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '验证码登录失败：${formatFrbError(e)}');
    } finally {
      if (mounted) setState(() => _smsLogging = false);
    }
  }

  String? _tokenLoginError() {
    final t = _tokenCtrl.text.trim();
    final v = _vinCtrl.text.trim().toUpperCase();
    if (t.isEmpty) return '请粘贴 ACCESS_TOKEN';
    if (!AppConfig.looksLikeAccessToken(t)) {
      return AppConfig.tokenSuffix.isEmpty
          ? 'token 不能为空'
          : 'token 必须以 ${AppConfig.tokenSuffix} 结尾';
    }
    if (v.isEmpty) return '请填入 17 位 VIN';
    if (!RegExp(r'^[A-HJ-NPR-Z0-9]{17}$').hasMatch(v)) {
      return 'VIN 格式不对（17 位英文大写/数字）';
    }
    return null;
  }

  Future<void> _saveTokenLogin() async {
    if (!await _requireAgreement()) return;
    final err = _tokenLoginError();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final token = _tokenCtrl.text.trim();
      final vin = _vinCtrl.text.trim().toUpperCase();
      final deviceId = await _deviceId();
      final p = await SharedPreferences.getInstance();
      await p.setString(_kTokenKey, token);
      await p.setString(_kVinKey, vin);
      await TokenAge.capture(token);

      // Token 登录也要尽量补全控车身份，避免 userId 被清空导致无法控车
      final prev = await ControlConfig.load();
      var userId = _tokenUserIdCtrl.text.trim();
      if (userId.isEmpty) userId = prev.userId;
      var mobile = _phoneCtrl.text.trim();
      if (mobile.isEmpty) mobile = prev.mobile;
      if (userId.isEmpty || mobile.isEmpty) {
        try {
          final fetched = await authFetchUserId(
            token: token,
            deviceId: deviceId,
          );
          if (fetched != null && fetched.isNotEmpty) userId = fetched;
        } catch (_) {}
      }
      await ControlConfig.saveIdentity(
        brand: _brand,
        userId: userId,
        mobile: mobile,
        headerDeviceId: deviceId,
      );
      if (_pinCtrl.text.trim().isNotEmpty) {
        await PinVault().saveEncrypted(_pinCtrl.text.trim());
      }
      if (!mounted) return;
      final missing = <String>[
        if (userId.isEmpty) 'userId',
        if (mobile.isEmpty) '手机号',
        if (_pinCtrl.text.trim().isEmpty && !prev.pinSaved) '控车PIN',
      ];
      if (missing.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已保存 token/VIN，但控车还缺：${missing.join('、')}。'
              '请到「设置 → 远程控车」补全后再锁车。',
            ),
          ),
        );
      }
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ProductShell(token: token, vin: vin),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = '保存失败：${formatFrbError(e)}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
          child: StaggeredAppear(
            index: 0,
            baseDelay: const Duration(milliseconds: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 简洁品牌头
                Center(
                  child: CarSideIllustration(
                    width: 200,
                    height: 72,
                    accentColor: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.directions_car,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'MYMG',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              color: AppPalette.strong,
                              letterSpacing: 0.5,
                            ),
                          ),
                          Text(
                            '车况 · 智能控车 · 消息中心',
                            style: TextStyle(
                              color: AppPalette.muted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 28),
                Text(
                  '手机号验证码登录',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: AppPalette.strong,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  '与官方同链路：滑块 + 短信。登录后自动保存 token / 手机号 / userId。',
                  style: TextStyle(color: AppPalette.muted, fontSize: 13),
                ),
                const SizedBox(height: 20),

                AgreementControl(
                  value: _agreed,
                  onChanged: (_saving || _smsSending || _smsLogging)
                      ? null
                      : (value) => setState(() {
                          _agreed = value;
                          _error = null;
                        }),
                ),
                const SizedBox(height: 16),
                // 品牌
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'MGLive', label: Text('名爵 MG')),
                    ButtonSegment(value: 'Roewe', label: Text('荣威')),
                  ],
                  selected: {_brand},
                  onSelectionChanged: (s) => setState(() => _brand = s.first),
                ),
                const SizedBox(height: 16),

                _fieldRow(
                  controller: _phoneCtrl,
                  label: '手机号',
                  hint: '官方 App 绑定号',
                  obscure: false,
                  keyboardType: TextInputType.phone,
                  maxLength: 11,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _fieldRow(
                        controller: _smsCtrl,
                        label: '短信验证码',
                        hint: '6 位数字',
                        obscure: false,
                        keyboardType: TextInputType.number,
                        maxLength: 8,
                      ),
                    ),
                    SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(top: 22),
                      child: OutlinedButton(
                        onPressed: (_smsSending || _smsCountdown > 0)
                            ? null
                            : _sendSms,
                        child: Text(
                          _smsCountdown > 0 ? '${_smsCountdown}s' : '获取验证码',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ),
                if (_smsHint != null) ...[
                  SizedBox(height: 8),
                  Text(
                    _smsHint!,
                    style: TextStyle(fontSize: 12, color: AppPalette.muted),
                  ),
                ],

                const SizedBox(height: 8),
                _fieldRow(
                  controller: _pinCtrl,
                  label: '控车 PIN（可选）',
                  hint: '4~8 位，设置里也可再改',
                  obscure: true,
                  keyboardType: TextInputType.number,
                  maxLength: 8,
                ),

                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(color: Colors.red, fontSize: 13),
                  ),
                ],

                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _smsLogging ? null : _loginBySms,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: _smsLogging
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text('验证码登录', style: TextStyle(fontSize: 16)),
                ),

                SizedBox(height: 16),
                // 备用：token 登录折叠
                if (!_showTokenLogin)
                  TextButton.icon(
                    onPressed: () => setState(() => _showTokenLogin = true),
                    icon: Icon(Icons.expand_more, size: 18),
                    label: Text('备用：粘贴 Token 登录'),
                  )
                else ...[
                  const Divider(),
                  SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '备用：Token / VIN',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    '验证码不可用时使用：粘贴官方 App 的 ACCESS_TOKEN。',
                    style: TextStyle(color: AppPalette.muted, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  _fieldRow(
                    controller: _tokenCtrl,
                    label: 'ACCESS_TOKEN',
                    hint: AppConfig.tokenHint,
                    obscure: false,
                    keyboardType: TextInputType.text,
                    maxLength: 80,
                    onPaste: () async {
                      final data = await Clipboard.getData('text/plain');
                      if (data?.text != null) {
                        setState(() => _tokenCtrl.text = data!.text!.trim());
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  _fieldRow(
                    controller: _vinCtrl,
                    label: 'VIN（17 位）',
                    hint: '17 位字母/数字',
                    obscure: false,
                    keyboardType: TextInputType.text,
                    textCapital: true,
                    maxLength: 17,
                    onPaste: () async {
                      final data = await Clipboard.getData('text/plain');
                      if (data?.text != null) {
                        setState(
                          () =>
                              _vinCtrl.text = data!.text!.trim().toUpperCase(),
                        );
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  _fieldRow(
                    controller: _tokenUserIdCtrl,
                    label: '控车 userId（可选）',
                    hint: '你的账号 userId（可选）',
                    obscure: false,
                    keyboardType: TextInputType.number,
                    maxLength: 32,
                    onPaste: () async {
                      final data = await Clipboard.getData('text/plain');
                      if (data?.text != null) {
                        setState(
                          () => _tokenUserIdCtrl.text = data!.text!.trim(),
                        );
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '说明：控车需要官方 App 的 ACCESS_TOKEN。'
                    '验证码登录的 token 在部分场景会被 checkPINCode 拒绝；'
                    '若短信登录后控车 14101，请改用本方式粘贴官方 token。'
                    '清数据后若拉不到 userId，请填上面的 userId 与手机号、PIN。',
                    style: TextStyle(
                      color: AppPalette.muted,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.tonal(
                    onPressed: _saving ? null : _saveTokenLogin,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                    ),
                    child: Text(
                      _saving ? '保存中…' : '用 Token 进入',
                      style: const TextStyle(fontSize: 15),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => setState(() => _showTokenLogin = false),
                      child: const Text('收起'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _fieldRow({
    required TextEditingController controller,
    required String label,
    required String hint,
    required bool obscure,
    required TextInputType keyboardType,
    int? maxLength,
    bool textCapital = false,
    VoidCallback? onPaste,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          obscureText: obscure,
          keyboardType: keyboardType,
          textCapitalization: textCapital
              ? TextCapitalization.characters
              : TextCapitalization.none,
          maxLength: maxLength,
          inputFormatters: [
            if (keyboardType == TextInputType.number)
              FilteringTextInputFormatter.digitsOnly,
          ],
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            border: const OutlineInputBorder(),
            counterText: '',
            suffixIcon: onPaste == null
                ? null
                : IconButton(
                    tooltip: '从剪贴板粘贴',
                    icon: const Icon(Icons.content_paste),
                    onPressed: onPaste,
                  ),
          ),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
        ),
      ],
    );
  }
}
