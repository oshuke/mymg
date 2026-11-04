import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mymg/car_image_store.dart';

// Generate and decode actual PNGs with the engine. Only the native documents
// directory and preferences are mocked; image processing and file IO stay real.
Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width / 2, height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFF0000),
  );
  final picture = recorder.endRecording();
  ui.Image? image;
  try {
    image = await picture.toImage(width, height);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('PNG fixture encoding failed');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image?.dispose();
    picture.dispose();
  }
}

Future<({int width, int height, Uint8List rgba})> _readPng(File file) async {
  final codec = await ui.instantiateImageCodec(await file.readAsBytes());
  ui.Image? image;
  try {
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) throw StateError('Saved PNG decoding failed');
    return (
      width: image.width,
      height: image.height,
      rgba: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  } finally {
    image?.dispose();
    codec.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory sandbox;
  late Directory documents;
  late Directory carDirectory;
  late SharedPreferences preferences;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('mymg-car-image-store-');
    addTearDown(() async {
      messenger.setMockMethodCallHandler(pathChannel, null);
      // This unique directory belongs to this test; external-file fixtures are
      // siblings of documents inside it, never actual user photos.
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });
    documents = await Directory(p.join(sandbox.path, 'documents')).create();
    carDirectory = Directory(p.join(documents.path, 'car'));
    messenger.setMockMethodCallHandler(pathChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return documents.path;
      }
      throw MissingPluginException(
        'Unexpected path_provider method: ${call.method}',
      );
    });
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  test('valid bytes save a real transparent PNG inside the app documents directory', () async {
    final revision = CarImageStore.revision.value;
    final path = await CarImageStore.saveFromBytes(await _png(64, 32));
    final saved = File(path);
    expect(p.dirname(path), carDirectory.path);
    expect((await saved.readAsBytes()).take(8), [
      137,
      80,
      78,
      71,
      13,
      10,
      26,
      10,
    ]);
    final image = await _readPng(saved);
    expect((image.width, image.height), (64, 32));
    expect(image.rgba.sublist(0, 4), [255, 0, 0, 255]);
    expect(
      image.rgba[(63 * 4) + 3],
      0,
      reason: 'Transparent car-image background must survive saving',
    );
    expect(preferences.getString(kCarImagePathKey), path);
    expect(await CarImageStore.heroPath(), path);
    expect(await CarImageStore.widgetBitmapPath(), path);
    expect(CarImageStore.revision.value, revision + 1);
  });

  test(
    'file import makes a sandbox copy and preserves the original photo',
    () async {
      final source = File(p.join(sandbox.path, 'picked-photo.png'));
      final original = await _png(80, 40);
      await source.writeAsBytes(original);
      final path = await CarImageStore.saveFromFile(source.path);
      expect(path, isNot(source.path));
      expect(p.dirname(path), carDirectory.path);
      final image = await _readPng(File(path));
      expect((image.width, image.height), (80, 40));
      expect(await source.readAsBytes(), original);
      expect(await CarImageStore.customPath(), path);
    },
  );

  test(
    'invalid replacement file preserves the active path, bytes and revision',
    () async {
      final first = await CarImageStore.saveFromBytes(await _png(64, 32));
      final firstBytes = await File(first).readAsBytes();
      final revision = CarImageStore.revision.value;
      final invalid = File(p.join(sandbox.path, 'broken-image.png'));
      await invalid.writeAsBytes([0, 1, 2, 3, 4, 5]);

      await expectLater(
        CarImageStore.saveFromFile(invalid.path),
        throwsA(isA<Exception>()),
      );

      expect(preferences.getString(kCarImagePathKey), first);
      expect(await CarImageStore.customPath(), first);
      expect(await File(first).readAsBytes(), firstBytes);
      expect(CarImageStore.revision.value, revision);
      expect(await carDirectory.list().map((entry) => entry.path).toList(), [
        first,
      ]);
    },
  );

  test(
    'missing replacement file also leaves the active photo untouched',
    () async {
      final first = await CarImageStore.saveFromBytes(await _png(64, 32));
      final revision = CarImageStore.revision.value;
      await expectLater(
        CarImageStore.saveFromFile(p.join(sandbox.path, 'not-present.png')),
        throwsA(isA<FileSystemException>()),
      );
      expect(await CarImageStore.customPath(), first);
      expect(await File(first).exists(), isTrue);
      expect(CarImageStore.revision.value, revision);
    },
  );

  test('second image uses a new path and notifies only after new bytes and path are available', () async {
    final first = await CarImageStore.saveFromBytes(await _png(64, 32));
    final revision = CarImageStore.revision.value;
    final observed = <({int revision, String? path, bool exists})>[];
    void onChange() {
      final path = preferences.getString(kCarImagePathKey);
      observed.add((
        revision: CarImageStore.revision.value,
        path: path,
        exists: path != null && File(path).existsSync(),
      ));
    }

    CarImageStore.revision.addListener(onChange);
    addTearDown(() => CarImageStore.revision.removeListener(onChange));

    final second = await CarImageStore.saveFromBytes(await _png(24, 48));

    expect(second, isNot(first));
    expect(observed, [(revision: revision + 1, path: second, exists: true)]);
    expect(await CarImageStore.heroPath(), second);
    expect(await CarImageStore.widgetBitmapPath(), second);
    expect(await File(first).exists(), isFalse);
    final image = await _readPng(File(second));
    expect((image.width, image.height), (24, 48));
  });

  test('reset deletes the active owned file while preserving its source and unrelated sandbox files', () async {
    final source = File(p.join(sandbox.path, 'custom_car_123456.png'));
    final original = await _png(64, 32);
    await source.writeAsBytes(original);
    final active = await CarImageStore.saveFromFile(source.path);
    final unrelated = File(p.join(carDirectory.path, 'other-photo.png'));
    await unrelated.writeAsBytes(original);
    final revision = CarImageStore.revision.value;

    await CarImageStore.resetToDefault();

    expect(preferences.containsKey(kCarImagePathKey), isFalse);
    expect(await CarImageStore.heroPath(), isNull);
    expect(await CarImageStore.widgetBitmapPath(), isNull);
    expect(CarImageStore.revision.value, revision + 1);
    expect(await File(active).exists(), isFalse);
    expect(await source.readAsBytes(), original);
    expect(await unrelated.readAsBytes(), original);
  });

  for (final fixture in [
    (
      name: 'external matching filename',
      inCarDirectory: false,
      fileName: 'custom_car_123456.png',
    ),
    (
      name: 'sandbox lookalike PNG',
      inCarDirectory: true,
      fileName: 'custom_car_source.png',
    ),
    (
      name: 'sandbox non-image file',
      inCarDirectory: true,
      fileName: 'custom_car_notes.txt',
    ),
  ]) {
    test(
      'reset preserves ${fixture.name} referenced by an old preference',
      () async {
        await carDirectory.create();
        final file = File(
          p.join(
            fixture.inCarDirectory ? carDirectory.path : sandbox.path,
            fixture.fileName,
          ),
        );
        final original = await _png(8, 8);
        await file.writeAsBytes(original);
        await preferences.setString(kCarImagePathKey, file.path);
        final revision = CarImageStore.revision.value;

        await CarImageStore.resetToDefault();

        expect(preferences.containsKey(kCarImagePathKey), isFalse);
        expect(await CarImageStore.customPath(), isNull);
        expect(CarImageStore.revision.value, revision + 1);
        expect(await file.readAsBytes(), original);
      },
    );
  }

  test(
    'replacing an external matching filename does not delete the source file',
    () async {
      final file = File(p.join(sandbox.path, 'custom_car_123456.png'));
      final original = await _png(12, 12);
      await file.writeAsBytes(original);
      await preferences.setString(kCarImagePathKey, file.path);

      final saved = await CarImageStore.saveFromBytes(await _png(48, 24));

      expect(await CarImageStore.customPath(), saved);
      expect(await file.readAsBytes(), original);
    },
  );

  for (final fixture in [
    (width: 3200, height: 1600, outputWidth: 1600, outputHeight: 800),
    (width: 1600, height: 3200, outputWidth: 800, outputHeight: 1600),
    (width: 4096, height: 1, outputWidth: 1600, outputHeight: 1),
    (width: 1, height: 4096, outputWidth: 1, outputHeight: 1600),
    (width: 1600, height: 50, outputWidth: 1600, outputHeight: 50),
  ]) {
    test(
      'saving ${fixture.width} x ${fixture.height} respects size limit and nonzero dimensions',
      () async {
        final path = await CarImageStore.saveFromBytes(
          await _png(fixture.width, fixture.height),
        );
        final image = await _readPng(File(path));
        expect(
          (image.width, image.height),
          (fixture.outputWidth, fixture.outputHeight),
        );
        expect(image.width, inInclusiveRange(1, 1600));
        expect(image.height, inInclusiveRange(1, 1600));
        expect(await CarImageStore.customPath(), path);
      },
    );
  }
}
