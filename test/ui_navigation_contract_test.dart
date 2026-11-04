import 'package:flutter_test/flutter_test.dart';

import 'package:mymg/ui_navigation_contract.dart';

void main() {
  test(
    'product shell has four oil-car destinations with settings outside dock',
    () {
      expect(productDestinations.map((item) => item.id), [
        ProductDestinationId.home,
        ProductDestinationId.control,
        ProductDestinationId.vehicleStatus,
        ProductDestinationId.location,
      ]);
    },
  );

  test('product shell does not expose OTA or charging destinations', () {
    expect(
      productDestinations.map((item) => item.label),
      isNot(contains('OTA')),
    );
    expect(
      productDestinations.map((item) => item.label),
      isNot(contains('充电')),
    );
  });
}
