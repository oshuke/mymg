// 坚果云 WebDAV 备份 / 恢复（路线 A 扩展）
//
// 备份包：自定义容器 `MYMG_BK1`
//   magic(8) | headerLen(u32 BE) | header JSON | payload…
// header.files = [{name, offset, size}]，payload 按序拼接。
//
// 包内文件：
//   meta.json  — 版本 / 时间 / 快照数 / VIN 尾号
//   mymg.db    — 本地 SQLite（checkpoint 后拷贝）
//   prefs.json — SharedPreferences（排除 WebDAV 密码等敏感项）
//                并含 __secure__.ai_api_key / __secure__.control_pin
//
// 不包含：WebDAV 密码（避免云上明文，且恢复时无需依赖备份包）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'store.dart';
import 'vehicle_profile.dart';
import 'webdav_client.dart';

// ── SharedPreferences 键 ────────────────────────────────────────────────
const kWevdavUrlKey = 'mymg.webdav.url';
const kWevdavUserKey = 'mymg.webdav.username';
const kWevdavFolderKey = 'mymg.webdav.folder';
const kWevdavPassSecureKey = 'mymg.webdav.password_v1';

const kBackupAutoKey = 'mymg.backup.auto';
const kBackupIntervalHKey = 'mymg.backup.interval_hours';
const kBackupMaxCountKey = 'mymg.backup.max_count';
const kBackupLastMsKey = 'mymg.backup.last_ms';
const kBackupLastErrorKey = 'mymg.backup.last_error';
const kBackupLastFileKey = 'mymg.backup.last_file';

/// 默认保留份数
const kBackupMaxOptions = <int>[3, 5, 10, 20, 50];
/// 自动备份周期（小时）
const kBackupIntervalOptions = <int>[6, 12, 24, 48, 168]; // 7 天

const _kMagic = 'MYMG_BK1';
const _kFormatVersion = 1;

/// 备份包内不回写到 prefs 的键（恢复时跳过）
const _skipPrefKeys = {
  kWevdavUrlKey,
  kWevdavUserKey,
  kWevdavFolderKey,
  kBackupLastMsKey,
  kBackupLastErrorKey,
  kBackupLastFileKey,
  // 登录态：恢复时保留本机当前 token，避免登出
  'mymg.token',
  'mymg.token_captured_at',
  'mymg.phone',
  // 控车身份与登录绑定，一并保留本机当前值
  'mymg.user_id',
  'mymg.mobile',
  // 已弃用/易混淆的历史 key 可在此追加
};

class BackupEntry {
  const BackupEntry({
    required this.name,
    required this.href,
    this.size,
    this.lastModified,
  });
  final String name;
  final String href;
  final int? size;
  final DateTime? lastModified;
}

class BackupService {
  BackupService._();
  static final BackupService instance = BackupService._();

  static final FlutterSecureStorage _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: true,
    ),
  );

  // ── 配置读写 ─────────────────────────────────────────────────────────

  Future<({String url, String user, String folder, String password})>
      loadConfig() async {
    final p = await SharedPreferences.getInstance();
    var pass = '';
    try {
      pass = await _secure.read(key: kWevdavPassSecureKey) ?? '';
    } catch (_) {}
    return (
      url: p.getString(kWevdavUrlKey)?.trim().isNotEmpty == true
          ? p.getString(kWevdavUrlKey)!.trim()
          : WebDavClient.jianguoyunUrl,
      user: p.getString(kWevdavUserKey) ?? '',
      folder: (p.getString(kWevdavFolderKey) ?? '/MYMG/').trim(),
      password: pass,
    );
  }

  Future<void> saveConfig({
    required String url,
    required String user,
    required String folder,
    String? password,
  }) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      kWevdavUrlKey,
      url.trim().isEmpty ? WebDavClient.jianguoyunUrl : url.trim(),
    );
    await p.setString(kWevdavUserKey, user.trim());
    var f = folder.trim();
    if (f.isEmpty) f = '/MYMG/';
    if (!f.startsWith('/')) f = '/$f';
    if (!f.endsWith('/')) f = '$f/';
    await p.setString(kWevdavFolderKey, f);
    if (password != null) {
      if (password.isEmpty) {
        await _secure.delete(key: kWevdavPassSecureKey);
      } else {
        await _secure.write(key: kWevdavPassSecureKey, value: password.trim());
      }
    }
  }

  Future<bool> hasCredentials() async {
    final c = await loadConfig();
    return c.user.isNotEmpty && c.password.isNotEmpty;
  }

  Future<bool> get autoEnabled async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(kBackupAutoKey) ?? false;
  }

  Future<void> setAutoEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kBackupAutoKey, v);
  }

  Future<int> get intervalHours async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(kBackupIntervalHKey) ?? 24;
  }

  Future<void> setIntervalHours(int h) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(kBackupIntervalHKey, h);
  }

  Future<int> get maxCount async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(kBackupMaxCountKey) ?? 10;
  }

  Future<void> setMaxCount(int n) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(kBackupMaxCountKey, n);
  }

  Future<DateTime?> get lastBackupAt async {
    final p = await SharedPreferences.getInstance();
    final ms = p.getInt(kBackupLastMsKey);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<String?> get lastError async {
    final p = await SharedPreferences.getInstance();
    return p.getString(kBackupLastErrorKey);
  }

  Future<String?> get lastFile async {
    final p = await SharedPreferences.getInstance();
    return p.getString(kBackupLastFileKey);
  }

  WebDavClient _client(dynamic cfg) => WebDavClient(
        baseUrl: cfg.url,
        username: cfg.user,
        password: cfg.password,
      );

  String _folderPath(String folder) {
    var f = folder.replaceAll(RegExp(r'^/+|/+$'), '');
    return f;
  }

  // ── 打包 ─────────────────────────────────────────────────────────────

  /// 组装备份包字节
  static Uint8List packBackup({
    required Map<String, List<int>> files,
    required Map<String, Object?> meta,
  }) {
    final entries = <Map<String, Object>>[];
    final payload = <int>[];
    for (final e in files.entries) {
      final offset = payload.length;
      payload.addAll(e.value);
      entries.add({'name': e.key, 'offset': offset, 'size': e.value.length});
    }
    final header = utf8.encode(jsonEncode({
      'format': _kFormatVersion,
      'meta': meta,
      'files': entries,
    }));
    final out = BytesBuilder(copy: false);
    final magic = ascii.encode(_kMagic);
    out.add(magic);
    final len = ByteData(4)..setUint32(0, header.length, Endian.big);
    out.add(len.buffer.asUint8List());
    out.add(header);
    out.add(payload);
    return out.toBytes();
  }

  /// 解包；格式非法时抛 [FormatException]
  static ({Map<String, Object?> meta, Map<String, List<int>> files})
      unpackBackup(Uint8List bytes) {
    if (bytes.length < 12) {
      throw const FormatException('备份包太小或已损坏');
    }
    final magic = ascii.decode(bytes.sublist(0, 8), allowInvalid: true);
    if (magic != _kMagic) {
      throw FormatException('不是 MYMG 备份包（magic=$magic）');
    }
    final headerLen =
        ByteData.sublistView(bytes, 8, 12).getUint32(0, Endian.big);
    if (headerLen <= 0 || 12 + headerLen > bytes.length) {
      throw const FormatException('备份包头长度非法');
    }
    final headerJson =
        utf8.decode(bytes.sublist(12, 12 + headerLen), allowMalformed: true);
    final header = jsonDecode(headerJson) as Map<String, dynamic>;
    final filesRaw = (header['files'] as List<dynamic>? ?? const []);
    final files = <String, List<int>>{};
    for (final f in filesRaw) {
      final m = f as Map<String, dynamic>;
      final name = m['name'] as String;
      final offset = m['offset'] as int;
      final size = m['size'] as int;
      if (offset < 0 || size < 0 || 12 + headerLen + offset + size > bytes.length) {
        throw FormatException('备份包内文件 $name 偏移非法');
      }
      files[name] = bytes.sublist(12 + headerLen + offset, 12 + headerLen + offset + size);
    }
    final metaRaw = header['meta'];
    final meta = metaRaw is Map
        ? Map<String, Object?>.from(metaRaw)
        : <String, Object?>{};
    return (meta: meta, files: files);
  }

  // ── 本地数据导出 / 导入 ──────────────────────────────────────────────

  Future<Uint8List> createLocalBackupBytes() async {
    // 先统计再关闭，避免 closeForBackup 后又把 DB 懒打开
    int snapshotCount = 0;
    try {
      snapshotCount = await SnapshotStore.instance.countAll();
    } catch (_) {}

    // 1) SQLite：checkpoint + 关闭 + 拷贝
    await SnapshotStore.instance.closeForBackup();
    final dbPath = await SnapshotStore.instance.dbFilePath;
    final dbFile = File(dbPath);
    final dbBytes = dbFile.existsSync() ? await dbFile.readAsBytes() : <int>[];
    // WAL / SHM 一并带走（若 checkpoint 后仍存在）
    final wal = File('$dbPath-wal');
    final shm = File('$dbPath-shm');
    final walBytes = wal.existsSync() ? await wal.readAsBytes() : null;
    final shmBytes = shm.existsSync() ? await shm.readAsBytes() : null;

    // 2) SharedPreferences（含 mymg.plate 车牌号等）
    final prefsMap = await _exportPrefs();
    // 显式保证车牌在包里（即使旧逻辑漏了）
    if (!prefsMap.containsKey(kPlateKey)) {
      try {
        final plate = await VehicleProfile.plate(force: true);
        if (plate.isNotEmpty) prefsMap[kPlateKey] = plate;
      } catch (_) {}
    }
    final prefsBytes = utf8.encode(jsonEncode(prefsMap));

    final meta = <String, Object?>{
      'format': _kFormatVersion,
      'createdAtMs': DateTime.now().millisecondsSinceEpoch,
      'snapshotCount': snapshotCount,
      'vinTail': prefsMap['mymg.vin'] is String
          ? _vinTail(prefsMap['mymg.vin'] as String)
          : '',
      'plate': prefsMap[kPlateKey] is String ? prefsMap[kPlateKey] : '',
    };

    final files = <String, List<int>>{
      'meta.json': utf8.encode(jsonEncode(meta)),
      'mymg.db': dbBytes,
      'prefs.json': prefsBytes,
    };
    if (walBytes != null) files['mymg.db-wal'] = walBytes;
    if (shmBytes != null) files['mymg.db-shm'] = shmBytes;

    // 3) 重新打开 DB，保证 App 继续可用
    await SnapshotStore.instance.reopenAfterBackup();

    return packBackup(files: files, meta: meta);
  }

  static String _vinTail(String vin) =>
      vin.length >= 6 ? vin.substring(vin.length - 6) : vin;

  static Future<Map<String, Object?>> _exportPrefs() async {
    final p = await SharedPreferences.getInstance();
    final out = <String, Object?>{};
    for (final key in p.getKeys()) {
      if (_skipPrefKeys.contains(key)) continue;
      // 跳过 WebDAV / 备份自身的运行时状态
      if (key.startsWith('mymg.webdav.') || key.startsWith('mymg.backup.')) {
        continue;
      }
      final v = p.get(key);
      if (v is String || v is bool || v is int || v is double) {
        out[key] = v;
      } else if (v is List<String>) {
        out[key] = v;
      }
    }

    // ── 覆盖全部数据：补入 secure storage 中的 AI Key / 控车 PIN ──
    // 仅备份到用户自己的坚果云；仍不含 WebDAV 密码。
    try {
      final aiKey = await _secure.read(key: 'mymg.ai.api_key_v1');
      if (aiKey != null && aiKey.isNotEmpty) {
        out['__secure__.ai_api_key'] = aiKey;
      }
    } catch (_) {}
    try {
      final pin = await _secure.read(key: 'mymg.control_pin_v1');
      if (pin != null && pin.isNotEmpty) {
        out['__secure__.control_pin'] = pin;
      }
    } catch (_) {}
    return out;
  }

  Future<void> _importPrefs(Map<String, Object?> map) async {
    final p = await SharedPreferences.getInstance();
    for (final e in map.entries) {
      final key = e.key;
      if (_skipPrefKeys.contains(key)) continue;
      if (key.startsWith('mymg.webdav.') || key.startsWith('mymg.backup.')) {
        continue;
      }
      // secure 字段单独处理
      if (key == '__secure__.ai_api_key') {
        try {
          await _secure.write(key: 'mymg.ai.api_key_v1', value: e.value as String);
        } catch (_) {}
        continue;
      }
      if (key == '__secure__.control_pin') {
        try {
          await _secure.write(key: 'mymg.control_pin_v1', value: e.value as String);
        } catch (_) {}
        continue;
      }
      final v = e.value;
      if (v is String) {
        await p.setString(key, v);
      } else if (v is bool) {
        await p.setBool(key, v);
      } else if (v is int) {
        await p.setInt(key, v);
      } else if (v is double) {
        await p.setDouble(key, v);
      } else if (v is List) {
        await p.setStringList(key, v.cast<String>());
      }
    }
  }

  /// 从备份包字节恢复到本机
  Future<void> restoreFromBytes(Uint8List bytes) async {
    final parsed = unpackBackup(bytes);
    final files = parsed.files;
    if (!files.containsKey('mymg.db') && !files.containsKey('prefs.json')) {
      throw const FormatException('备份包缺少 mymg.db / prefs.json');
    }

    await SnapshotStore.instance.closeForBackup();
    final dbPath = await SnapshotStore.instance.dbFilePath;
    final dbFile = File(dbPath);

    if (files.containsKey('mymg.db')) {
      // 先删旧 WAL/SHM，避免与新库不一致
      for (final suf in ['-wal', '-shm', '-journal']) {
        final f = File('$dbPath$suf');
        if (f.existsSync()) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
      await dbFile.writeAsBytes(files['mymg.db']!, flush: true);
      if (files.containsKey('mymg.db-wal')) {
        await File('$dbPath-wal')
            .writeAsBytes(files['mymg.db-wal']!, flush: true);
      }
      if (files.containsKey('mymg.db-shm')) {
        await File('$dbPath-shm')
            .writeAsBytes(files['mymg.db-shm']!, flush: true);
      }
    }

    if (files.containsKey('prefs.json')) {
      final map = jsonDecode(
        utf8.decode(files['prefs.json']!, allowMalformed: true),
      ) as Map<String, dynamic>;
      await _importPrefs(Map<String, Object?>.from(map));
      // 车牌等内存缓存可能还是旧值，强制下一次读 prefs
      VehicleProfile.invalidateCache();
    }

    await SnapshotStore.instance.reopenAfterBackup();
  }

  // ── 远程操作 ─────────────────────────────────────────────────────────

  Future<String> backupNow() async {
    final cfg = await loadConfig();
    if (cfg.user.isEmpty || cfg.password.isEmpty) {
      throw StateError('请先填写坚果云账号与应用密码');
    }
    final client = _client(cfg);
    final folder = _folderPath(cfg.folder);
    await client.ensureDirectory(folder);

    final bytes = await createLocalBackupBytes();
    final now = DateTime.now();
    final name =
        'mymg_backup_${_ts(now)}.mymgbak';
    final remote = folder.isEmpty ? name : '$folder/$name';
    await client.putBytes(remote, bytes);

    // 清理超出 maxCount 的旧备份
    final pruned = await _pruneRemote(client, folder, await maxCount);

    final p = await SharedPreferences.getInstance();
    await p.setInt(kBackupLastMsKey, now.millisecondsSinceEpoch);
    await p.remove(kBackupLastErrorKey);
    await p.setString(kBackupLastFileKey, name);

    debugPrint('[MYMG.BK] backup ok $remote prune=$pruned size=${bytes.length}');
    return name;
  }

  Future<int> _pruneRemote(
    WebDavClient client,
    String folder,
    int maxKeep,
  ) async {
    if (maxKeep <= 0) return 0;
    final entries = await listRemote(client: client, folder: folder);
    if (entries.length <= maxKeep) return 0;
    // 文件名含时间戳，字典序即时间序
    final sorted = [...entries]..sort((a, b) => a.name.compareTo(b.name));
    final excess = sorted.sublist(0, sorted.length - maxKeep);
    for (final e in excess) {
      final path = folder.isEmpty ? e.name : '$folder/${e.name}';
      await client.delete(path);
    }
    return excess.length;
  }

  Future<List<BackupEntry>> listRemote({WebDavClient? client, String? folder}) async {
    final cfg = await loadConfig();
    final c = client ?? _client(cfg);
    final f = _folderPath(folder ?? cfg.folder);
    final rows = await c.list(f);
    return rows
        .where((e) =>
            !e.isCollection &&
            (e.name.endsWith('.mymgbak') || e.name.endsWith('.mymgbackup')))
        .map((e) => BackupEntry(
              name: e.name,
              href: e.href,
              size: e.contentLength,
              lastModified: e.lastModified,
            ))
        .toList()
      ..sort((a, b) => b.name.compareTo(a.name)); // 新的在前
  }

  Future<void> restoreRemote(String fileName) async {
    final cfg = await loadConfig();
    if (cfg.user.isEmpty || cfg.password.isEmpty) {
      throw StateError('请先填写坚果云账号与应用密码');
    }
    final client = _client(cfg);
    final folder = _folderPath(cfg.folder);
    final path = folder.isEmpty ? fileName : '$folder/$fileName';
    final bytes = await client.getBytes(path);
    await restoreFromBytes(Uint8List.fromList(bytes));
  }

  Future<void> deleteRemote(String fileName) async {
    final cfg = await loadConfig();
    final client = _client(cfg);
    final folder = _folderPath(cfg.folder);
    await client.delete(folder.isEmpty ? fileName : '$folder/$fileName');
  }

  Future<void> testConnection() async {
    final cfg = await loadConfig();
    if (cfg.user.isEmpty || cfg.password.isEmpty) {
      throw StateError('请先填写坚果云账号与应用密码');
    }
    await _client(cfg).testConnection();
  }

  /// 前台自动备份入口：到周期则静默备份一次；失败写 last_error 不抛
  Future<bool> maybeAutoBackup() async {
    try {
      if (!await autoEnabled) return false;
      if (!await hasCredentials()) return false;
      final last = await lastBackupAt;
      final hours = await intervalHours;
      if (last != null &&
          DateTime.now().difference(last).inHours < hours) {
        return false;
      }
      await backupNow();
      return true;
    } catch (e, st) {
      debugPrint('[MYMG.BK] auto backup failed: $e\n$st');
      final p = await SharedPreferences.getInstance();
      await p.setString(kBackupLastErrorKey, e.toString());
      return false;
    }
  }

  static String _ts(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  /// 展示用：把远程文件名还原成时间
  static DateTime? parseNameTime(String name) {
    final m = RegExp(r'mymg_backup_(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})')
        .firstMatch(name);
    if (m == null) return null;
    return DateTime(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6)!),
    );
  }
}
