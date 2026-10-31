// 极简 WebDAV 客户端（仅覆盖坚果云备份所需方法）
//
// 不引入第三方包：PROPFIND / PUT / GET / DELETE / MKCOL 用 dart:io HttpClient 即可。
// 坚果云：https://dav.jianguoyun.com/dav/
// 认证：HTTP Basic（用户名 + 应用密码，不是网页登录密码）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class WebDavException implements Exception {
  WebDavException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() =>
      statusCode == null ? message : '$message（HTTP $statusCode）';
}

class WebDavEntry {
  const WebDavEntry({
    required this.href,
    required this.name,
    required this.isCollection,
    this.contentLength,
    this.lastModified,
  });

  final String href;
  final String name;
  final bool isCollection;
  final int? contentLength;
  final DateTime? lastModified;
}

class _Result {
  _Result(this.statusCode, this.bytes);
  final int statusCode;
  final List<int> bytes;
}

class WebDavClient {
  WebDavClient({
    required String baseUrl,
    required this.username,
    required this.password,
    this.timeout = const Duration(seconds: 90),
  }) : baseUrl = _normalizeBase(baseUrl);

  static const String jianguoyunUrl = 'https://dav.jianguoyun.com/dav/';

  final String baseUrl;
  final String username;
  final String password;
  final Duration timeout;

  static String _normalizeBase(String url) {
    var u = url.trim();
    if (u.isEmpty) return u;
    if (!u.endsWith('/')) u = '$u/';
    return u;
  }

  String get _authHeader =>
      'Basic ${base64Encode(utf8.encode('$username:$password'))}';

  String resolveUrl(String pathOrUrl) {
    if (pathOrUrl.startsWith('http://') || pathOrUrl.startsWith('https://')) {
      return pathOrUrl;
    }
    final p = pathOrUrl.replaceAll(RegExp(r'^/+'), '');
    return p.isEmpty ? baseUrl : '$baseUrl$p';
  }

  Future<_Result> _request(
    String method,
    String pathOrUrl, {
    Map<String, String>? headers,
    List<int>? body,
    bool expectXml = false,
  }) async {
    final uri = Uri.parse(resolveUrl(pathOrUrl));
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.openUrl(method, uri);
      req.headers.set(HttpHeaders.authorizationHeader, _authHeader);
      req.headers.set(HttpHeaders.userAgentHeader, 'MYMG-WebDAV/1.0');
      if (expectXml) {
        req.headers.set(HttpHeaders.acceptHeader, 'application/xml, text/xml');
      }
      headers?.forEach(req.headers.set);
      if (body != null) {
        req.headers.contentLength = body.length;
        req.add(body);
      }
      final resp = await req.close().timeout(timeout);
      final bytes = await resp.fold<List<int>>(<int>[], (a, b) {
        a.addAll(b);
        return a;
      }).timeout(timeout);
      return _Result(resp.statusCode, bytes);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _ensureOk(_Result r, String action) async {
    if (r.statusCode >= 200 && r.statusCode < 300) return;
    final body = utf8.decode(r.bytes, allowMalformed: true);
    final snippet = body.length > 240 ? '${body.substring(0, 240)}…' : body;
    throw WebDavException('$action 失败：$snippet', statusCode: r.statusCode);
  }

  /// 确保远程目录存在（逐级 MKCOL，已存在忽略）
  Future<void> ensureDirectory(String path) async {
    final clean = path.replaceAll(RegExp(r'^/+|/+$'), '');
    if (clean.isEmpty) return;
    var acc = '';
    for (final part in clean.split('/')) {
      if (part.isEmpty) continue;
      acc = acc.isEmpty ? part : '$acc/$part';
      final r = await _request('MKCOL', acc, expectXml: true);
      if (r.statusCode == 200 ||
          r.statusCode == 201 ||
          r.statusCode == 405) {
        continue;
      }
      if (r.statusCode == 403 || r.statusCode == 409) {
        try {
          await list(acc);
          continue;
        } catch (_) {}
      }
      await _ensureOk(r, '创建目录 $acc');
    }
  }

  Future<void> putBytes(String path, List<int> bytes) async {
    final r = await _request(
      'PUT',
      path,
      headers: {HttpHeaders.contentTypeHeader: 'application/octet-stream'},
      body: bytes,
    );
    await _ensureOk(r, '上传 ${path.split('/').where((e) => e.isNotEmpty).last}');
  }

  Future<List<int>> getBytes(String path) async {
    final r = await _request('GET', path);
    await _ensureOk(r, '下载');
    return r.bytes;
  }

  Future<void> delete(String path) async {
    final r = await _request('DELETE', path);
    if (r.statusCode == 404) return;
    await _ensureOk(r, '删除');
  }

  /// Depth:1 列目录。[path] 为相对 baseUrl 的路径（可空）。
  Future<List<WebDavEntry>> list(String path) async {
    final r = await _request(
      'PROPFIND',
      path,
      headers: {
        'Depth': '1',
        HttpHeaders.contentTypeHeader: 'application/xml; charset=utf-8',
      },
      body: utf8.encode(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<D:propfind xmlns:D="DAV:"><D:prop>'
        '<D:displayname/><D:resourcetype/>'
        '<D:getcontentlength/><D:getlastmodified/>'
        '</D:prop></D:propfind>',
      ),
      expectXml: true,
    );
    if (r.statusCode == 404) return const [];
    await _ensureOk(r, '列出目录');
    return parseMultistatus(
      utf8.decode(r.bytes, allowMalformed: true),
      baseUrl,
    );
  }

  Future<void> testConnection() async {
    final r = await _request(
      'PROPFIND',
      '',
      headers: {'Depth': '0'},
      body: utf8.encode(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<D:propfind xmlns:D="DAV:"><D:prop><D:displayname/></D:prop></D:propfind>',
      ),
      expectXml: true,
    );
    await _ensureOk(r, '连接 WebDAV');
  }

  /// 解析 PROPFIND multistatus（公开以便单测）
  static List<WebDavEntry> parseMultistatus(String xml, String base) {
    final out = <WebDavEntry>[];
    final basePath = Uri.parse(base).path.replaceAll(RegExp(r'/+$'), '');
    final responses = RegExp(
      r'<(?:[A-Za-z0-9]+:)?response\b[^>]*>([\s\S]*?)</(?:[A-Za-z0-9]+:)?response>',
      caseSensitive: false,
    ).allMatches(xml);

    for (final m in responses) {
      final block = m.group(1)!;
      final hrefM = RegExp(
        r'<(?:[A-Za-z0-9]+:)?href\b[^>]*>([\s\S]*?)</(?:[A-Za-z0-9]+:)?href>',
        caseSensitive: false,
      ).firstMatch(block);
      if (hrefM == null) continue;

      final href = unescapeXml(hrefM.group(1)!.trim());
      var pathOnly = _pathOf(href);
      final isCollection = RegExp(
        r'<[^>]*collection\b',
        caseSensitive: false,
      ).hasMatch(block);

      if (basePath.isNotEmpty &&
          pathOnly == basePath &&
          isCollection) {
        continue; // 目录自身
      }

      final parts = pathOnly.split('/').where((e) => e.isNotEmpty).toList();
      final name = parts.isEmpty ? pathOnly : parts.last;
      if (name.isEmpty) continue;

      final lenM = RegExp(
        r'<(?:[A-Za-z0-9]+:)?getcontentlength\b[^>]*>(\d+)<',
        caseSensitive: false,
      ).firstMatch(block);
      final modM = RegExp(
        r'<(?:[A-Za-z0-9]+:)?getlastmodified\b[^>]*>([^<]+)<',
        caseSensitive: false,
      ).firstMatch(block);

      DateTime? last;
      final mod = modM?.group(1)?.trim();
      if (mod != null) {
        last = _parseHttpDate(mod);
      }

      out.add(WebDavEntry(
        href: href,
        name: name,
        isCollection: isCollection,
        contentLength: lenM == null ? null : int.tryParse(lenM.group(1)!),
        lastModified: last,
      ));
    }
    return out;
  }

  static String unescapeXml(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');

  static String _pathOf(String hrefOrPath) {
    String path;
    try {
      final u = Uri.parse(hrefOrPath);
      path = u.path.isNotEmpty ? u.path : hrefOrPath;
    } catch (_) {
      path = hrefOrPath;
    }
    if (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return path;
  }

  static DateTime? _parseHttpDate(String s) {
    try {
      return HttpDate.parse(s);
    } catch (_) {
      return DateTime.tryParse(s);
    }
  }
}
