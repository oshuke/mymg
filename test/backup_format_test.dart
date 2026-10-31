// WebDAV 备份包格式单测（不依赖网络 / 设备）
//
// 覆盖：pack ↔ unpack 往返、损坏包拒绝、multistatus 解析、保留份数排序用的文件名时间

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mymg/backup_service.dart';
import 'package:mymg/webdav_client.dart';

void main() {
  test('pack/unpack 往返', () {
    final files = <String, List<int>>{
      'meta.json': utf8.encode('{"a":1}'),
      'mymg.db': List<int>.generate(200, (i) => i % 256),
      'prefs.json': utf8.encode('{"mymg.plate":"冀A12345"}'),
    };
    final packed = BackupService.packBackup(
      files: files,
      meta: {'format': 1, 'snapshotCount': 3},
    );
    expect(packed.sublist(0, 8), ascii.encode('MYMG_BK1'));

    final parsed = BackupService.unpackBackup(packed);
    expect(parsed.files.keys.toList()..sort(),
        ['meta.json', 'mymg.db', 'prefs.json']);
    expect(utf8.decode(parsed.files['prefs.json']!),
        '{"mymg.plate":"冀A12345"}');
    expect(parsed.files['mymg.db']!.length, 200);
    expect(parsed.files['mymg.db']![10], 10);
    expect(parsed.meta['snapshotCount'], 3);
  });

  test('空 payload 也可打包', () {
    final packed = BackupService.packBackup(
      files: {'meta.json': <int>[]},
      meta: const {},
    );
    final parsed = BackupService.unpackBackup(packed);
    expect(parsed.files['meta.json'], isEmpty);
  });

  test('非 MYMG 头应抛 FormatException', () {
    expect(
      () => BackupService.unpackBackup(
        Uint8List.fromList(utf8.encode('NOTBK001${'x' * 20}')),
      ),
      throwsFormatException,
    );
  });

  test('截断包应抛 FormatException', () {
    final packed = BackupService.packBackup(
      files: {'a.txt': utf8.encode('hello')},
      meta: const {},
    );
    final cut = packed.sublist(0, packed.length - 3);
    expect(
      () => BackupService.unpackBackup(Uint8List.fromList(cut)),
      throwsFormatException,
    );
  });

  test('parseMultistatus 解析文件与目录', () {
    const xml = '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/MYMG/</D:href>
    <D:propstat>
      <D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/MYMG/mymg_backup_20260910_220000.mymgbak</D:href>
    <D:propstat>
      <D:prop>
        <D:getcontentlength>12345</D:getcontentlength>
        <D:getlastmodified>Thu, 10 Sep 2026 22:00:00 GMT</D:getlastmodified>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
</D:multistatus>
''';
    final entries = WebDavClient.parseMultistatus(
      xml,
      'https://dav.jianguoyun.com/dav/MYMG/',
    );
    expect(entries.length, 1);
    expect(entries.first.name, 'mymg_backup_20260910_220000.mymgbak');
    expect(entries.first.isCollection, isFalse);
    expect(entries.first.contentLength, 12345);
    expect(entries.first.lastModified, isNotNull);
  });

  test('文件名时间解析', () {
    final t = BackupService.parseNameTime('mymg_backup_20260910_173148.mymgbak');
    expect(t, isNotNull);
    expect(t!.year, 2026);
    expect(t.month, 9);
    expect(t.day, 10);
    expect(t.hour, 17);
    expect(t.minute, 31);
    expect(BackupService.parseNameTime('nope.mymgbak'), isNull);
  });
}
