// 历史快照 CSV 导出

import 'dart:convert';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'store.dart';
import 'dart:io';

class HistoryExport {
  HistoryExport._();

  static String toCsv(List<SnapshotRow> rows) {
    final buf = StringBuffer()
      ..writeln(
          'captured_at,server_time,vin,fuel_percent,range_km,odometer_km,interior_temp,exterior_temp,latitude,longitude,journey_km,speed');
    for (final r in rows) {
      final local = DateTime.fromMillisecondsSinceEpoch(r.capturedAt)
          .toIso8601String();
      final server = r.serverDataTime == null
          ? ''
          : DateTime.fromMillisecondsSinceEpoch(
              r.serverDataTime! > 1000000000000
                  ? r.serverDataTime!
                  : r.serverDataTime! * 1000,
            ).toIso8601String();
      buf.writeln([
        local,
        server,
        r.vin,
        r.fuelPercent ?? '',
        r.rangeKm ?? '',
        r.odometerKm ?? '',
        r.interiorTemp ?? '',
        r.exteriorTemp ?? '',
        r.latitude ?? '',
        r.longitude ?? '',
        r.journeyKm ?? '',
        r.speed ?? '',
      ].join(','));
    }
    return buf.toString();
  }

  static Future<void> shareCsv({
    required List<SnapshotRow> rows,
    required String vin,
  }) async {
    final csv = toCsv(rows);
    final tail = vin.length >= 6 ? vin.substring(vin.length - 6) : vin;
    final name =
        'mymg_${tail}_${DateTime.now().millisecondsSinceEpoch}.csv';
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$name');
    await file.writeAsString(csv, flush: true);
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'text/csv', name: name)],
      subject: 'MYMG 历史车况 CSV',
    );
  }
}
