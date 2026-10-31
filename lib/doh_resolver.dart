// 备用 DNS 解析（DNS over HTTPS）—— 解决 Android 上 `Failed host lookup`。
//
// 为什么需要它：
//   `Failed host lookup: 'open.bigmodel.cn'` 是**系统 DNS 解析失败**。
//   应用层改不了系统 DNS，但下面这些都会导致它失败，且用户不一定知道：
//     - 「私人 DNS」（Private DNS）填了一个不可用的主机名
//     - VPN / 加速器 / 广告拦截 App 接管了 DNS 并返回失败
//     - 运营商或路由器的 DNS 解析不了该域名
//   这些都发生在"联网正常"的前提下 —— 车况接口能通、只有这个域名解析不了。
//   所以这里绕开系统 DNS，用 DoH 自己查一次，再拿 IP 直连。
//
// 安全性（重要）：
//   查询用的 HttpClient 只对 [kDohHosts] 这几个 **DoH 服务器 IP** 放行证书
//   主机名校验（它们是被 IP 直连的，证书 SAN 里本来就不含该 IP）；
//   而随后真正的业务 HTTPS 连接，仍然是 HttpClient 用**真实主机名**做 SNI
//   与证书校验（本模块只负责建 TCP socket，不碰 TLS）。
//   所以即使 DoH 结果被污染，也只会"连不上"，不会静默连到假服务器。
//
// 单独成文件的原因：解析结果校验（公网 IPv4 白名单）与 DoH 响应格式解析
// 是有安全含义的纯逻辑，抽出来才能写单测（见 test/doh_resolver_test.dart）。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 备用 DNS 服务器（都是国内可直连的公共解析，用 IP 直连所以自身不需要 DNS）
const List<String> kDohHosts = ['223.5.5.5', '119.29.29.29'];

/// 是不是"本机域名解析失败"这类错误。
///
/// 各平台措辞不同：Android/Linux `Failed host lookup`、
/// glibc `Name or service not known`、macOS `nodename nor servname provided`、
/// resolver 瞬断 `Temporary failure in name resolution`。
bool isHostLookupFailure(SocketException e) {
  final m = '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();
  return m.contains('failed host lookup') ||
      m.contains('name or service not known') ||
      m.contains('nodename nor servname') ||
      m.contains('temporary failure in name resolution') ||
      m.contains('no address associated with hostname');
}

final RegExp _ipv4Re = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');

/// 只接受**公网** IPv4。
///
/// 挡住回环 / 内网 / CGNAT / 组播 / 保留段：DNS 结果来自外部，
/// 不应该把连接带到本机或内网去（DNS rebinding 的常见手法）。
/// 注意这里没挡 `0.0.0.0`-`0.255.255.255` 之外的其它保留段（如 240/4），
/// 因为 a >= 224 已经把它们挡住了。
bool isPublicIpv4(String s) {
  final m = _ipv4Re.firstMatch(s.trim());
  if (m == null) return false;
  final parts = <int>[];
  for (var i = 1; i <= 4; i++) {
    final v = int.parse(m.group(i)!);
    if (v > 255) return false;
    parts.add(v);
  }
  final a = parts[0], b = parts[1];
  if (a == 0 || a == 10 || a == 127) return false; // 保留 / 内网 / 回环
  if (a == 172 && b >= 16 && b <= 31) return false; // 内网
  if (a == 192 && b == 168) return false; // 内网
  if (a == 169 && b == 254) return false; // link-local
  if (a == 100 && b >= 64 && b <= 127) return false; // 运营商 CGNAT
  if (a >= 224) return false; // 组播 / 保留
  return true;
}

/// 解析阿里 DNS（`https://223.5.5.5/resolve`）的 JSON，取第一条 A 记录。
///
/// 形如：{"Status":0,"Answer":[{"name":"x.","type":1,"TTL":60,"data":"1.2.3.4"}]}
String? pickIpv4FromAliJson(String? body) {
  if (body == null || body.trim().isEmpty) return null;
  try {
    final d = jsonDecode(body);
    if (d is! Map) return null;
    // Status != 0 表示解析失败 / NXDOMAIN
    final status = d['Status'];
    if (status is int && status != 0) return null;
    final ans = d['Answer'];
    if (ans is! List) return null;
    for (final a in ans) {
      if (a is! Map) continue;
      if (a['type'] != 1) continue; // 1 = A 记录
      final data = a['data'];
      if (data is String && isPublicIpv4(data)) return data.trim();
    }
  } catch (_) {
    // 格式不对就当查不到
  }
  return null;
}

/// 解析 DNSPod 的纯文本接口（`https://119.29.29.29/d?dn=x&type=a`）。
///
/// 返回形如 `1.2.3.4` 或 `1.2.3.4;5.6.7.8`；失败时返回空串或错误文案。
String? pickIpv4FromDnspod(String? body) {
  if (body == null) return null;
  for (final raw in body.split(RegExp(r'[;,\s]+'))) {
    if (isPublicIpv4(raw)) return raw.trim();
  }
  return null;
}

/// 用 DoH 查 A 记录，返回第一个公网 IPv4；查不到返回 null（不抛异常）。
Future<String?> resolveViaDoh(String host) async {
  const timeout = Duration(seconds: 6);
  final q = Uri.encodeQueryComponent(host);

  // ① 阿里 DNS：JSON 接口，语义最清晰
  final ali = await _dohGetText('https://223.5.5.5/resolve?name=$q&type=A', timeout);
  final fromAli = pickIpv4FromAliJson(ali);
  if (fromAli != null) return fromAli;

  // ② DNSPod：纯文本接口，阿里挂了时的备胎
  final dp = await _dohGetText('https://119.29.29.29/d?dn=$q&type=a', timeout);
  final fromDp = pickIpv4FromDnspod(dp);
  if (fromDp != null) return fromDp;

  return null;
}

Future<String?> _dohGetText(String url, Duration timeout) async {
  final c = HttpClient()
    ..connectionTimeout = timeout
    ..badCertificateCallback = (cert, h, p) => kDohHosts.contains(h);
  try {
    final req = await c.getUrl(Uri.parse(url)).timeout(timeout);
    req.headers.set(
      HttpHeaders.acceptHeader,
      'application/dns-json, application/json, text/plain, */*',
    );
    final resp = await req.close().timeout(timeout);
    if (resp.statusCode != 200) return null;
    return await resp.transform(utf8.decoder).join().timeout(timeout);
  } catch (e) {
    debugPrint('[MYMG] 备用 DNS 查询失败 $url: $e');
    return null;
  } finally {
    c.close(force: true);
  }
}

/// 挂到 `HttpClient.connectionFactory` 上：先自己查 DNS，再拿 IP 直连。
///
/// 这里**只建 TCP 连接**，TLS 由 HttpClient 用真实主机名继续完成，
/// 所以证书校验依然是完整的（见文件头的安全说明）。
Future<ConnectionTask<Socket>> connectWithDohFallback(
  Uri url,
  String? proxyHost,
  int? proxyPort,
) async {
  final ip = await resolveViaDoh(url.host);
  if (ip != null) {
    debugPrint('[MYMG] 系统 DNS 拿不到 ${url.host}，备用 DNS 解析为 $ip');
    return Socket.startConnect(
      InternetAddress(ip, type: InternetAddressType.IPv4),
      url.port,
    );
  }
  // 备用解析也失败（可能是临时抖动）→ 回落到系统解析，让正常路径兜底
  final s = await Socket.connect(
    url.host,
    url.port,
    timeout: const Duration(seconds: 15),
  );
  return ConnectionTask.fromSocket(Future.value(s), () {});
}
