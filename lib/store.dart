// 本地 SQLite 存储：每次拉到的车况快照写一行，用于历史曲线、告警阈值、CSV 导出。
//
// 数据库位置：`getDatabasesPath()/mymg.db`（App 沙盒内，卸载 App 时自动清空）。
// 表设计：snapshots（按时间倒序，按 vin 索引）。
//
// 30 天前的自动清理（可在 _cleanExpired 调，更严格/宽松可改）。
// 路线 A 期间没有自动登录，token 失效后这表的数据依然可用（历史曲线不依赖实时接口）。
//
// ──────────────────────────────────────────────────────────────────────────
// Day 3a+：fingerprint 压缩
//
// 每条 snapshot 算一个"数据指纹"（油量/续航/里程/经纬度/行程拼接）。
// **连续**同 fingerprint 的行只保留首尾两条 —— 证明这段时期车况没动，
// 曲线仍能正确画出"水平段"，也不把相同历史堆成几十条。
//
// 注意是「连续」：A→B→A 时两段 A 各自收敛，不会把中间夹着 B 的两条 A
// 误当成同一段稳定期（旧 SQL 按全局 fingerprint 分组，有这个坑）。
//
// Schema v1 → v2：新增 fingerprint 列；onUpgrade 时回填老数据。
// ──────────────────────────────────────────────────────────────────────────

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'package:mymg/src/rust/vehicle/summary.dart';

const _kSchemaVersion = 3;

/// 单例 store
class SnapshotStore {
  static final SnapshotStore instance = SnapshotStore._();
  SnapshotStore._();

  Database? _db;
  Future<Database>? _opening;

  /// 异步初始化 DB（多次调用安全）
  Future<Database> get db async {
    if (_db != null) return _db!;
    _opening ??= _open();
    _db = await _opening!;
    return _db!;
  }

  Future<Database> _open() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'mymg.db');
    final db = await openDatabase(
      path,
      version: _kSchemaVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            captured_at INTEGER NOT NULL,
            server_data_time INTEGER,
            vin TEXT NOT NULL,
            fuel_percent INTEGER,
            range_km INTEGER,
            odometer_km REAL,
            interior_temp REAL,
            exterior_temp REAL,
            latitude TEXT,
            longitude TEXT,
            journey_km REAL,
            speed REAL,
            fingerprint TEXT
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_snapshots_vin_captured ON snapshots(vin, captured_at)',
        );
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          await db.execute('ALTER TABLE snapshots ADD COLUMN fingerprint TEXT');
        }
      },
    );
    // 打开后校准一次 fingerprint，保证与 Dart 侧算法完全一致。
    //
    // 放在 openDatabase 之外而不是 onOpen 钩子里：避开"钩子执行期间再发起
    // 批量写"的时序问题，也让失败能被调用方感知。
    //
    // 数据量级是"每天几十条"，全量校准开销可忽略；好处是指纹算法将来再调整时，
    // 老库能自动跟上，无需反复升 schema 版本。
    await _rebuildFingerprints(db);
    return db;
  }

  /// 用 Dart 侧统一的算法重算全表 fingerprint，并立刻收敛一次重复。
  ///
  /// 刻意不用 SQL 拼字符串：SQLite 的 ROUND/CAST 与 Dart 的 toStringAsFixed
  /// 在小数位数、去尾零上不一致（37.75850 → SQL 给 "37.7585"，Dart 给 "37.75850"），
  /// 会让"同一个位置"被判成两组指纹，去重失效。
  static Future<void> _rebuildFingerprints(Database db) async {
    final rows = await db.query(
      'snapshots',
      columns: [
        'id', 'fuel_percent', 'range_km', 'odometer_km',
        'latitude', 'longitude', 'journey_km', 'fingerprint',
      ],
    );
    final batch = db.batch();
    var dirty = false;
    for (final m in rows) {
      final fp = _fpFromMap(m);
      if (m['fingerprint'] != fp) {
        dirty = true;
        batch.update('snapshots', {'fingerprint': fp},
            where: 'id = ?', whereArgs: [m['id']]);
      }
    }
    if (dirty) await batch.commit(noResult: true);
    await collapseConsecutiveDuplicates(db);
  }

  /// 收敛：**连续**同 vin + 同 fingerprint 的行，只保留最早 + 最晚两条。
  ///
  /// 用 Dart 而不是窗口函数 SQL：要先按 (vin, captured_at, id) 切「连续段」，
  /// 而不是按全局 fingerprint 分组（A→B→A 时后者会误删/误留）。
  /// 表规模是每天几十条，全量扫一遍开销可忽略。
  static Future<void> collapseConsecutiveDuplicates(Database db) async {
    final rows = await db.query(
      'snapshots',
      columns: ['id', 'vin', 'captured_at', 'fingerprint'],
      orderBy: 'vin ASC, captured_at ASC, id ASC',
    );
    final parsed = rows
        .map((m) => (
              id: m['id'] as int,
              vin: m['vin'] as String,
              capturedAt: m['captured_at'] as int,
              fingerprint: m['fingerprint'] as String?,
            ))
        .toList(growable: false);
    final doomed = consecutiveCollapseIds(parsed);
    if (doomed.isEmpty) return;
    await db.delete('snapshots', where: 'id IN (${doomed.map((_) => '?').join(',')})',
        whereArgs: doomed);
  }

  /// 纯函数：算出「连续同指纹段」里该删掉的中间行 id（保留每段首尾）。
  ///
  /// [rows] 需已按 (vin, captured_at, id) 升序；本函数内部不再排序，
  /// 调用方保证顺序，便于和 SQL orderBy 对齐、单测直接喂列表。
  @visibleForTesting
  static List<int> consecutiveCollapseIds(
    List<({int id, String vin, int capturedAt, String? fingerprint})> rows,
  ) {
    final doomed = <int>[];
    var i = 0;
    while (i < rows.length) {
      final vin = rows[i].vin;
      final fp = rows[i].fingerprint;
      var j = i + 1;
      while (j < rows.length && rows[j].vin == vin && rows[j].fingerprint == fp) {
        j++;
      }
      // 段长 ≥3 才删中间；1 或 2 条原样保留（首尾语义）
      if (j - i >= 3) {
        for (var k = i + 1; k < j - 1; k++) {
          doomed.add(rows[k].id);
        }
      }
      i = j;
    }
    return doomed;
  }

  /// 计算一条快照的"数据指纹"。
  ///
  /// **只包含"车没动就不会变"的字段**：
  ///   油量 / 续航 / 总里程 / 纬度 / 经度 / 行程
  ///
  /// 刻意**排除车内温度、车外温度** —— 它们会随日照/气温自然波动（中午 33°C、
  /// 夜里 20°C），车停着不动也在变，纳入指纹会导致永远判定不出"车没动"。
  static String fingerprintOf(VehicleSummary s) => _fingerprint(
        fuelPercent: s.fuelPercent,
        rangeKm: s.rangeKm,
        odometerKm: s.odometerKm,
        latitude: s.latitude,
        longitude: s.longitude,
        journeyKm: s.journeyKm,
      );

  static String _fpFromMap(Map<String, Object?> m) => _fingerprint(
        fuelPercent: (m['fuel_percent'] as num?)?.toInt(),
        rangeKm: (m['range_km'] as num?)?.toInt(),
        odometerKm: (m['odometer_km'] as num?)?.toDouble(),
        latitude: m['latitude'] as String?,
        longitude: m['longitude'] as String?,
        journeyKm: (m['journey_km'] as num?)?.toDouble(),
      );

  /// 唯一实现：Dart 侧所有地方都走这里，保证 SQL 回填/插入/校准三处结果一致。
  static String _fingerprint({
    required int? fuelPercent,
    required int? rangeKm,
    required double? odometerKm,
    required String? latitude,
    required String? longitude,
    required double? journeyKm,
  }) {
    String whole(num? v) => v == null ? '' : v.toStringAsFixed(0);

    // 经纬度统一 5 位小数 ≈ 1 米精度：既能判断"车有没有动"，
    // 又能吸收 GPS 末位抖动（37.759456 与 37.75946 视为同一位置）。
    String coord(String? s) {
      if (s == null || s.isEmpty) return '';
      final d = double.tryParse(s);
      return d == null ? s : d.toStringAsFixed(5);
    }

    return [
      fuelPercent?.toString() ?? '',
      rangeKm?.toString() ?? '',
      whole(odometerKm),
      coord(latitude),
      coord(longitude),
      whole(journeyKm),
    ].join('|');
  }

  /// 写入一条快照（基于 VehicleSummary）。vin 由调用方传入。
  ///
  /// 自动去重：插入后把**连续**同 fingerprint 的中间行删掉，只保留首尾两条。
  /// 这段车况稳定、没变化。（2026-09-22 用户再次确认此规则，保持生效）
  Future<int> insertFromSummary(VehicleSummary s, {required String vin}) async {
    final database = await db;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final fp = fingerprintOf(s);
    final id = await database.insert(
      'snapshots',
      {
        'captured_at': ts,
        'server_data_time': s.updateTime,
        'vin': vin,
        'fuel_percent': s.fuelPercent,
        'range_km': s.rangeKm,
        'odometer_km': s.odometerKm,
        'interior_temp': s.interiorTemp,
        'exterior_temp': s.exteriorTemp,
        'latitude': s.latitude,
        'longitude': s.longitude,
        'journey_km': s.journeyKm,
        'fingerprint': fp,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    // 收敛：连续同 vin + 同 fingerprint 只保留最早 + 最晚两条
    await collapseConsecutiveDuplicates(database);
    return id;
  }

  /// 列出某 vin 在 [fromMs, toMs) 范围内的快照，按时间倒序。
  Future<List<SnapshotRow>> listByRange({
    required String vin,
    int? fromMs,
    int? toMs,
    int limit = 1000,
  }) async {
    final database = await db;
    final where = StringBuffer('vin = ?');
    final args = <Object?>[vin];
    if (fromMs != null) {
      where.write(' AND captured_at >= ?');
      args.add(fromMs);
    }
    if (toMs != null) {
      where.write(' AND captured_at < ?');
      args.add(toMs);
    }
    final rows = await database.query(
      'snapshots',
      where: where.toString(),
      whereArgs: args,
      orderBy: 'captured_at DESC',
      limit: limit,
    );
    return rows.map(SnapshotRow.fromMap).toList();
  }

  /// 最近一条快照
  Future<SnapshotRow?> last(String vin) async {
    final database = await db;
    final rows = await database.query(
      'snapshots',
      where: 'vin = ?',
      whereArgs: [vin],
      orderBy: 'captured_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return SnapshotRow.fromMap(rows.first);
  }

  /// 统计某 vin 的快照数
  Future<int> count(String vin) async {
    final database = await db;
    final r = await database.rawQuery(
      'SELECT COUNT(*) FROM snapshots WHERE vin = ?',
      [vin],
    );
    return Sqflite.firstIntValue(r) ?? 0;
  }

  /// 清理 N 天前的快照。返回删除行数。
  Future<int> cleanOlderThan({required int days, String? vin}) async {
    final database = await db;
    final cutoffMs = DateTime.now()
        .subtract(Duration(days: days))
        .millisecondsSinceEpoch;
    return database.delete(
      'snapshots',
      where: vin == null
          ? 'captured_at < ?'
          : 'vin = ? AND captured_at < ?',
      whereArgs: vin == null ? [cutoffMs] : [vin, cutoffMs],
    );
  }

  /// 删除某 vin 的全部快照
  Future<int> deleteAll(String vin) async {
    final database = await db;
    return database.delete('snapshots', where: 'vin = ?', whereArgs: [vin]);
  }

  /// 全库快照总数（WebDAV 备份 meta 用）
  Future<int> countAll() async {
    final database = await db;
    final r = await database.rawQuery('SELECT COUNT(*) AS c FROM snapshots');
    return (r.first['c'] as int?) ?? 0;
  }

  /// mymg.db 绝对路径
  Future<String> get dbFilePath async {
    final dbPath = await getDatabasesPath();
    return p.join(dbPath, 'mymg.db');
  }

  /// 备份前关闭连接并 checkpoint，保证磁盘上的 db 文件自洽
  Future<void> closeForBackup() async {
    final database = _db;
    if (database == null) return;
    try {
      await database.execute('PRAGMA wal_checkpoint(FULL)');
    } catch (_) {}
    try {
      await database.close();
    } catch (_) {}
    _db = null;
    _opening = null;
  }

  /// 备份/恢复后重新打开
  Future<void> reopenAfterBackup() async {
    // 确保没有半开句柄
    try {
      await closeForBackup();
    } catch (_) {}
    // 触发懒打开
    await db;
    // 恢复场景：指纹重算在 open 里已做
  }

  /// 强制从磁盘重载（恢复后调用）
  Future<void> reloadFromDisk() async {
    await closeForBackup();
    await db;
  }

  /// 仅测试用：注入已打开的 Database
  @visibleForTesting
  void debugAttach(Database database) {
    _db = database;
    _opening = Future.value(database);
  }
}

/// 单行快照的强类型视图。
class SnapshotRow {
  SnapshotRow({
    required this.id,
    required this.capturedAt,
    this.serverDataTime,
    required this.vin,
    this.fuelPercent,
    this.rangeKm,
    this.odometerKm,
    this.interiorTemp,
    this.exteriorTemp,
    this.latitude,
    this.longitude,
    this.journeyKm,
    this.speed,
  });

  factory SnapshotRow.fromMap(Map<String, Object?> m) => SnapshotRow(
        id: m['id'] as int,
        capturedAt: m['captured_at'] as int,
        serverDataTime: m['server_data_time'] as int?,
        vin: m['vin'] as String,
        fuelPercent: m['fuel_percent'] as int?,
        rangeKm: m['range_km'] as int?,
        odometerKm: (m['odometer_km'] as num?)?.toDouble(),
        interiorTemp: (m['interior_temp'] as num?)?.toDouble(),
        exteriorTemp: (m['exterior_temp'] as num?)?.toDouble(),
        latitude: m['latitude'] as String?,
        longitude: m['longitude'] as String?,
        journeyKm: (m['journey_km'] as num?)?.toDouble(),
        speed: (m['speed'] as num?)?.toDouble(),
      );

  final int id;
  final int capturedAt;
  final int? serverDataTime;
  final String vin;
  final int? fuelPercent;
  final int? rangeKm;
  final double? odometerKm;
  final double? interiorTemp;
  final double? exteriorTemp;
  final String? latitude;
  final String? longitude;
  final double? journeyKm;
  final double? speed;

  DateTime get capturedAtDt =>
      DateTime.fromMillisecondsSinceEpoch(capturedAt);
}