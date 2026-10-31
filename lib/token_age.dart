// 令牌生命周期跟踪：记住令牌首次使用的时间，让用户在到期前有准备。
// 访问令牌通常有有效期，过期后控制类接口会返回鉴权错误，需要重新登录换取。

import 'package:shared_preferences/shared_preferences.dart';

class TokenAge {
  static const _kTokenKey = 'mymg.token';
  static const _kTokenCapturedAtKey = 'mymg.token_captured_at';

  /// Token 有效天数（粗略估计；上汽实际可能不同，仅做提醒）
  static const maxDays = 30;

  /// 用户提供新 token 时调；保存 token + 当前时间
  static Future<void> capture(String token) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kTokenKey, token);
    await p.setInt(_kTokenCapturedAtKey, DateTime.now().millisecondsSinceEpoch);
  }

  /// 现有 token 在本机已存了多少天。token 尚未存则 null。
  static Future<int?> ageDays() async {
    final p = await SharedPreferences.getInstance();
    final capturedMs = p.getInt(_kTokenCapturedAtKey);
    if (capturedMs == null) return null;
    final captured = DateTime.fromMillisecondsSinceEpoch(capturedMs);
    return DateTime.now().difference(captured).inDays;
  }

  /// token 还有几天过期。null = 还没记录 / 不在本地。
  static Future<int?> remainingDays() async {
    final age = await ageDays();
    if (age == null) return null;
    return maxDays - age;
  }

  /// token 是不是快到期了（≤ 3 天）
  static Future<bool> isExpiringSoon() async {
    final r = await remainingDays();
    return r != null && r <= 3;
  }

  /// 删旧 token（包括抓取时间）
  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kTokenKey);
    await p.remove(_kTokenCapturedAtKey);
  }
}

/// 友好显示 token 剩余有效天数。
String formatTokenRemaining(int? days) {
  if (days == null) return '尚未记录抓取时间';
  if (days < 0) return '已过期 ${-days} 天（请重新登录获取）';
  if (days == 0) return '今天过期（请重新登录获取）';
  if (days <= 3) return '还剩 $days 天（即将过期，建议重新登录获取）';
  return '还剩 $days 天';
}
