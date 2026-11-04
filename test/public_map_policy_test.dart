import 'package:flutter_test/flutter_test.dart';
import 'package:mymg/app_config.dart';
import 'package:mymg/geocode_service.dart';

void main() {
  test('unconfigured public build does not load a default map provider', () {
    expect(AppConfig.mapTilesConfigured, isFalse);
    expect(AppConfig.enablePublicGeocoding, isFalse);
  });

  test('map sources require HTTPS, XYZ placeholders and attribution', () {
    expect(AppConfig.isUsableTileSource('', ''), isFalse);
    expect(
      AppConfig.isUsableTileSource(
        'http://example.invalid/{z}/{x}/{y}',
        'Test',
      ),
      isFalse,
    );
    expect(
      AppConfig.isUsableTileSource('https://example.invalid/{z}/{x}/{y}', ''),
      isFalse,
    );
    expect(
      AppConfig.isUsableTileSource('https://example.invalid/tiles', 'Test'),
      isFalse,
    );
    expect(
      AppConfig.isUsableTileSource(
        'https://example.invalid/{z}/{x}/{y}',
        'Test',
      ),
      isTrue,
    );
  });

  test('reverse geocoding is offline unless explicitly enabled', () async {
    // No preferences or HTTP mocks: the default must return before either boundary.
    expect(await GeocodeService.instance.reverseFromVehicle(0, 0), isNull);
  });
}
