/// 构建期可配置项（全部通过 --dart-define 注入）。
///
/// 设计原则：仓库里不保存任何厂商协议值；默认值保证「能编译、能启动」，
/// 真正需要联网/蓝牙的能力在未配置时给出可读提示。
class AppConfig {
  const AppConfig._();

  /// 登录滑块验证码的 captchaId（自填）
  static const String captchaId = String.fromEnvironment('MYMG_CAPTCHA_ID');

  /// 官方访问令牌的后缀（自填；为空表示不校验）
  static const String tokenSuffix = String.fromEnvironment('MYMG_TOKEN_SUFFIX');

  /// 官方 App 包名（仅用于「打开官方 App」跳转；未配置则按钮无效）
  static const String officialAppPackage =
      String.fromEnvironment('MYMG_OFFICIAL_PKG');

  /// 数字钥匙 GATT 服务 UUID（自填；开源版不内置厂商值）
  static const String bleServiceUuid =
      String.fromEnvironment('MYMG_BLE_SERVICE_UUID');

  /// 令牌是否「看起来可用」：未配置后缀时不校验。
  static bool looksLikeAccessToken(String t) =>
      t.isNotEmpty && (tokenSuffix.isEmpty || t.endsWith(tokenSuffix));

  /// 输入框提示文案
  static String get tokenHint =>
      tokenSuffix.isEmpty ? 'ACCESS_TOKEN' : 'ACCESS_TOKEN（以 $tokenSuffix 结尾）';
}
