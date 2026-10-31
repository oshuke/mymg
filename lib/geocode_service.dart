// 逆地理：WGS-84 → 简体中文地址
//
// 策略：总预算约 6s，先出结果再后台补细
//   1. BigDataCloud zh（国内通常快，至少省市区）
//   2. Nominatim zh（街道级，DoH + 短超时）

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'coord.dart';
import 'doh_resolver.dart';

class GeocodeService {
  GeocodeService._();

  static final GeocodeService instance = GeocodeService._();

  static const _cachePrefix = 'mymg.geo6.';
  static const _quickTimeout = Duration(seconds: 4);
  static const _budget = Duration(seconds: 6);

  static const Map<String, String> _t2s = {
    '區': '区', '縣': '县', '鄉': '乡', '鎮': '镇',
    '門': '门', '車': '车', '馬': '马', '學': '学', '國': '国',
    '東': '东', '內': '内', '裡': '里', '衛': '卫', '運': '运',
    '園': '园', '場': '场', '廣': '广', '樓': '楼', '號': '号',
    '銀': '银', '華': '华', '鳳': '凤', '龍': '龙', '橋': '桥',
    '島': '岛', '灣': '湾', '陽': '阳', '陰': '阴', '電': '电',
    '話': '话', '醫': '医', '館': '馆', '賓': '宾', '麗': '丽',
    '團': '团', '體': '体', '奧': '奥', '萬': '万', '億': '亿',
    '舊': '旧', '點': '点', '線': '线', '鐵': '铁', '網': '网',
    '訊': '讯', '匯': '汇', '產': '产', '業': '业', '貿': '贸',
    '財': '财', '資': '资', '費': '费', '價': '价', '錢': '钱',
    '單': '单', '雙': '双', '愛': '爱', '歡': '欢', '樂': '乐',
    '靜': '静', '淨': '净', '綠': '绿', '紅': '红', '黃': '黄',
    '藍': '蓝', '亞': '亚', '歐': '欧', '紀': '纪', '實': '实',
    '現': '现', '開': '开', '關': '关', '間': '间', '問': '问',
    '題': '题', '說': '说', '語': '语', '讀': '读', '寫': '写',
    '聽': '听', '見': '见', '視': '视', '覺': '觉', '觸': '触',
    '動': '动', '風': '风', '雲': '云', '霧': '雾', '靈': '灵',
  };

  static String toSimplified(String s) {
    if (s.isEmpty) return s;
    final sb = StringBuffer();
    for (final ch in s.runes) {
      final c = String.fromCharCode(ch);
      sb.write(_t2s[c] ?? c);
    }
    return sb.toString();
  }

  static bool looksLatinAddress(String s) {
    final t = s.trim();
    if (t.isEmpty) return false;
    var letters = 0;
    var cjk = 0;
    for (final r in t.runes) {
      if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) {
        letters++;
      } else if (r >= 0x4E00 && r <= 0x9FFF) {
        cjk++;
      }
    }
    return letters >= 4 && cjk == 0;
  }

  static bool isDetailed(String s) {
    return s.contains('路') ||
        s.contains('街') ||
        s.contains('道') ||
        s.contains('巷') ||
        s.contains('大道');
  }

  static String? _accept(String? s) {
    if (s == null) return null;
    final t = toSimplified(s.trim());
    if (t.isEmpty || looksLatinAddress(t)) return null;
    return t;
  }

  String _keyFor(double lat, double lng) {
    final qLat = (lat * 1000).round() / 1000.0;
    final qLng = (lng * 1000).round() / 1000.0;
    return '${qLat.toStringAsFixed(3)},${qLng.toStringAsFixed(3)}';
  }

  /// 快速返回可展示地址（最长约 budget 秒）。失败返回 null，UI 自己回退坐标。
  Future<String?> reverseFromVehicle(double wgsLat, double wgsLng) async {
    final key = _keyFor(wgsLat, wgsLng);
    final p = await SharedPreferences.getInstance();
    final cached = p.getString(_cachePrefix + key);
    if (cached != null && cached.isNotEmpty && !looksLatinAddress(cached)) {
      // 有缓存直接用；若不是街道级，后台再补一次
      if (isDetailed(cached)) return cached;
      unawaited(_upgradeInBackground(wgsLat, wgsLng, key));
      return cached;
    }

    final sw = Stopwatch()..start();
    final gcj = wgs84ToGcj02(wgsLat, wgsLng);

    // 1) BigDataCloud：国内一般几秒内有省市区
    final coarse = _accept(await _bigdatacloud(gcj.lat, gcj.lng));
    if (coarse != null) {
      await p.setString(_cachePrefix + key, coarse);
      if (isDetailed(coarse)) return coarse;
      // 有粗地址就先返回，后台再试街道
      unawaited(_upgradeInBackground(wgsLat, wgsLng, key));
      return coarse;
    }

    // 2) Nominatim：预算内打一次
    if (sw.elapsedMilliseconds < _budget.inMilliseconds) {
      final detail = _accept(await _nominatim(wgsLat, wgsLng));
      if (detail != null) {
        await p.setString(_cachePrefix + key, detail);
        return detail;
      }
    }
    return null;
  }

  Future<void> _upgradeInBackground(
      double wgsLat, double wgsLng, String key) async {
    try {
      final detail = _accept(await _nominatim(wgsLat, wgsLng));
      if (detail == null || !isDetailed(detail)) return;
      final p = await SharedPreferences.getInstance();
      await p.setString(_cachePrefix + key, detail);
      developer.log('[MYMG.GEO] upgraded to detail: $detail', name: 'mymg_core');
    } catch (e) {
      developer.log('[MYMG.GEO] upgrade fail: $e', name: 'mymg_core');
    }
  }

  Future<dynamic> _getJson(Uri uri, {bool preferDoh = false}) async {
    Future<dynamic> get(HttpClient client) async {
      final req = await client.getUrl(uri);
      req.headers.set('User-Agent', 'MYMG/1.0');
      req.headers.set('Accept-Language', 'zh-CN,zh;q=0.9');
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final resp = await req.close().timeout(_quickTimeout);
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join().timeout(_quickTimeout);
      return jsonDecode(body);
    }

    try {
      final c = HttpClient()..connectionTimeout = _quickTimeout;
      try {
        final j = await get(c);
        if (j != null) return j;
      } finally {
        c.close(force: true);
      }
    } catch (_) {}

    if (preferDoh) {
      try {
        final c = HttpClient()
          ..connectionTimeout = _quickTimeout
          ..connectionFactory = connectWithDohFallback;
        try {
          final j = await get(c);
          if (j != null) return j;
        } finally {
          c.close(force: true);
        }
      } catch (_) {}
    }
    return null;
  }

  Future<String?> _nominatim(double lat, double lng) async {
    final j = await _getJson(
      Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
        '?lat=$lat&lon=$lng&format=jsonv2&zoom=18&addressdetails=1'
        '&accept-language=zh-CN',
      ),
      preferDoh: true,
    );
    return _formatNominatim(j);
  }

  String? _formatNominatim(dynamic j) {
    if (j is! Map) return null;
    final a = j['address'] as Map<String, dynamic>?;
    if (a == null) return null;
    String g(String k) => (a[k] as String?)?.trim() ?? '';

    final display = (j['display_name'] as String?) ?? '';
    final segs = display
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    String pickEndsWith(List<String> suffixes) {
      for (final s in segs) {
        for (final suf in suffixes) {
          if (s.endsWith(suf)) return s;
        }
      }
      return '';
    }

    final province = pickEndsWith(const ['省', '自治区', '特别行政区']) != ''
        ? pickEndsWith(const ['省', '自治区', '特别行政区'])
        : (g('state') != '' ? g('state') : g('province'));
    final city = pickEndsWith(const ['市']) != ''
        ? pickEndsWith(const ['市'])
        : (g('city') != '' ? g('city') : g('town'));
    final district = pickEndsWith(const ['区', '县', '旗']) != ''
        ? pickEndsWith(const ['区', '县', '旗'])
        : (g('county') != '' ? g('county') : g('suburb'));
    final street = g('suburb') != '' ? g('suburb') : g('city_district');
    final road = g('road') != '' ? g('road') : g('pedestrian');
    final name = g('name');

    final parts = <String>[];
    void add(String s) {
      if (s.isNotEmpty && !parts.contains(s)) parts.add(s);
    }

    add(province);
    if (city.isNotEmpty && city != district) add(city);
    add(district);
    if (street.isNotEmpty && street != district && street != city) add(street);
    if (road.isNotEmpty && road != street) add(road);
    if (name.isNotEmpty && name != road) add(name);

    if (parts.isNotEmpty && parts.join().length >= 3) return parts.join();

    if (segs.isNotEmpty) {
      final rev = <String>[];
      for (final s in segs.reversed) {
        if (s == '中国' || s == 'China') continue;
        if (RegExp(r'^\d').hasMatch(s)) continue;
        rev.add(s);
      }
      if (rev.isNotEmpty) return rev.join();
    }
    return null;
  }

  Future<String?> _bigdatacloud(double lat, double lng) async {
    final j = await _getJson(Uri.parse(
      'https://api.bigdatacloud.net/data/reverse-geocode-client'
      '?latitude=$lat&longitude=$lng&localityLanguage=zh',
    ));
    if (j is! Map) return null;
    final m = j.cast<String, dynamic>();
    String pick(String k) => (m[k] as String?)?.trim() ?? '';
    final parts = <String>[];
    void add(String s) {
      if (s.isNotEmpty && !parts.contains(s)) parts.add(s);
    }

    add(pick('principalSubdivision'));
    final city = pick('city');
    if (city != pick('principalSubdivision')) add(city);
    final district = pick('locality');
    if (district.isNotEmpty && district != city) add(district);
    final road = pick('street').isNotEmpty ? pick('street') : pick('neighbourhood');
    if (road.isNotEmpty && road != district) add(road);
    final building = pick('building');
    if (building.isNotEmpty) add(building);

    if (parts.isNotEmpty && parts.join().length >= 3) return parts.join();
    final label = pick('label');
    return label.isNotEmpty ? label : null;
  }

  /// UI 用：永远返回一行可读文案（地址或坐标），绝不空
  Future<String> labelFor(double wgsLat, double wgsLng) async {
    try {
      final addr = await reverseFromVehicle(wgsLat, wgsLng);
      if (addr != null && addr.isNotEmpty && !looksLatinAddress(addr)) {
        return toSimplified(addr);
      }
    } catch (_) {}
    final gcj = wgs84ToGcj02(wgsLat, wgsLng);
    return '坐标 ${gcj.lat.toStringAsFixed(4)}, ${gcj.lng.toStringAsFixed(4)}';
  }
}
