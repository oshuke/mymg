// 控车配置：统一读写身份 / 品牌 / 指纹策略（设置页维护，控车页只读）
//
// 存 SharedPreferences（明文身份字段）；PIN 仍在 PinVault。

import 'package:shared_preferences/shared_preferences.dart';

import 'pin_vault.dart';
import 'token_age.dart';

const kControlBrandKey = 'mymg.brand';
const kControlUserIdKey = 'mymg.user_id';
const kControlMobileKey = 'mymg.mobile';
const kControlHeaderDevKey = 'mymg.header_device_id';
const kControlRequireBioKey = 'mymg.control_require_bio';

class ControlConfig {
  ControlConfig({
    required this.brand,
    required this.userId,
    required this.mobile,
    required this.headerDeviceId,
    required this.requireBiometric,
    required this.pinSaved,
    required this.token,
    required this.vin,
  });

  final String brand;
  final String userId;
  final String mobile;
  final String headerDeviceId;
  final bool requireBiometric;
  final bool pinSaved;
  final String? token;
  final String? vin;

  bool get identityOk => userId.isNotEmpty && mobile.isNotEmpty;
  bool get tokenOk => token != null && token!.isNotEmpty;
  bool get vinOk => vin != null && vin!.length == 17;
  bool get readyForControl => identityOk && tokenOk && vinOk && pinSaved;

  static Future<ControlConfig> load() async {
    final p = await SharedPreferences.getInstance();
    final vault = PinVault();
    final pinSaved = await vault.hasEncryptedPin();
    var devId = p.getString(kControlHeaderDevKey) ?? '';
    if (devId.isEmpty) devId = 'mymg000000000001';
    return ControlConfig(
      brand: p.getString(kControlBrandKey) ?? 'MGLive',
      userId: p.getString(kControlUserIdKey) ?? '',
      mobile: p.getString(kControlMobileKey) ?? '',
      headerDeviceId: devId,
      requireBiometric: p.getBool(kControlRequireBioKey) ?? false,
      pinSaved: pinSaved,
      token: p.getString('mymg.token'),
      vin: p.getString('mymg.vin'),
    );
  }

  static Future<void> saveIdentity({
    required String brand,
    required String userId,
    required String mobile,
    required String headerDeviceId,
  }) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(kControlBrandKey, brand);
    await p.setString(kControlUserIdKey, userId.trim());
    await p.setString(kControlMobileKey, mobile.trim());
    await p.setString(
      kControlHeaderDevKey,
      headerDeviceId.trim().isEmpty ? 'mymg000000000001' : headerDeviceId.trim(),
    );
  }

  static Future<void> setRequireBiometric(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kControlRequireBioKey, v);
  }

  /// token 有效期摘要（供设置页）
  static Future<String> tokenAgeSummary() async {
    final remain = await TokenAge.remainingDays();
    return formatTokenRemaining(remain);
  }
}
