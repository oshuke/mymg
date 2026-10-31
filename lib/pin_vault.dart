// 控车 PIN 的"安全保险箱"：PIN 不明文落盘，靠 Android KeyStore 加密。
//
// - 首次输入后 PIN 加密存到 EncryptedSharedPreferences（Android Keystore 兜底）
// - 后续操作前需要调用 `unlockForUse()`：
//     1) 指纹可用就先让用户验证指纹
//     2) 指纹失败 / 不可用 → 回退让用户输 PIN（保持 PIN 永远不入裸内存外的磁盘）
// - 解锁后用 in-memory cache 缓存一段时间（PIN_TTL），避免每次控车都弹指纹
//
// KeyStore 通过 `flutter_secure_storage` 间接调用，无需写 MethodChannel。

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

class PinVault {
  /// 改名更明确：这是我自己的键名前缀，和 secure_storage 内部前缀无关。
  static const _kPinKey = 'mymg.control_pin_v1';

  /// 缓存 PIN 的有效期。过期后下次控车需要重新验指纹 / 输 PIN。
  /// 拉长到 30 分钟：连续控车不再反复弹指纹，降低远程首包延迟。
  static const Duration pinTtl = Duration(minutes: 30);

  // ── 单例内存缓存 ────────────────────────────────────────────────────────
  String? _cachedPin;
  DateTime _cachedAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool get hasCachedPin =>
      _cachedPin != null &&
      DateTime.now().difference(_cachedAt) < pinTtl;

  String? get cachedPin => hasCachedPin ? _cachedPin : null;

  /// 清除内存缓存（用户主动退出登录 / 切换车辆）
  void forget() {
    _cachedPin = null;
    _cachedAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  // ── 加密存储后端 ───────────────────────────────────────────────────────
  // aOptions: Android-specific —— EncryptedSharedPreferences（API 23+）。
  // AES-GCM 256 + KeyStore master key，每次启动随机生成的密钥用 KeyStore 加密。
  static final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: true,
    ),
  );

  /// 把 PIN 加密存盘（首次输入后调用）。
  Future<void> saveEncrypted(String pin) async {
    await _storage.write(key: _kPinKey, value: pin);
  }

  /// 从加密存储读出 PIN（解密用 KeyStore）。
  Future<String?> readEncrypted() async {
    return await _storage.read(key: _kPinKey);
  }

  /// 抹掉已保存的 PIN（用户主动清除）。
  Future<void> clearEncrypted() async {
    await _storage.delete(key: _kPinKey);
    forget();
  }

  /// 是否已加密存盘（PIN 是否"记住"了）。
  Future<bool> hasEncryptedPin() async {
    final v = await readEncrypted();
    return v != null && v.isNotEmpty;
  }

  /// 把 PIN 从加密存储读到内存缓存（不会在 UI 显示）。
  /// 配合 unlockForUse() 用——指纹通过后调用。
  Future<String?> loadIntoMemory() async {
    final p = await readEncrypted();
    if (p != null) {
      _cachedPin = p;
      _cachedAt = DateTime.now();
    }
    return p;
  }

  // ── 指纹 / 设备凭据解锁 ────────────────────────────────────────────────

  final _auth = LocalAuthentication();

  /// 本机是否登记了指纹 / Face 等生物特征。
  Future<bool> get isBiometricAvailable async {
    try {
      final supported = await _auth.isDeviceSupported();
      if (!supported) return false;
      final canCheck = await _auth.canCheckBiometrics;
      return canCheck;
    } catch (_) {
      return false;
    }
  }

  /// 让用户用指纹 / 面部解锁。返回 true 表示通过。
  /// 不抛异常——失败 / 取消都返回 false。
  Future<bool> authenticate({
    String reason = '解锁控车密码',
  }) async {
    try {
      // 先确认能力，避免直接 authenticate 在部分机型上静默返回 false
      final supported = await _auth.isDeviceSupported();
      final can = await _auth.canCheckBiometrics;
      debugPrint('PinVault.authenticate supported=$supported canCheck=$can');
      if (!supported || !can) {
        return false;
      }
      final ok = await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
          useErrorDialogs: false, // 关掉系统错误弹窗，失败原因走日志 + UI 文案
        ),
      );
      debugPrint('PinVault.authenticate result=$ok');
      return ok;
    } on Exception catch (e) {
      debugPrint('PinVault.authenticate exception: $e');
      return false;
    } catch (e, st) {
      debugPrint('PinVault.authenticate error: $e\n$st');
      return false;
    }
  }
}
