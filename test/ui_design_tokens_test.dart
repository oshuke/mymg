import 'package:flutter_test/flutter_test.dart';

import 'package:mymg/ui_design_tokens.dart';

void main() {
  test('light oil-car palette exposes blue glass surfaces and fuel accent', () {
    expect(MyMgDesignTokens.primaryBlue, isNotNull);
    expect(MyMgDesignTokens.glassSurface, isNotNull);
    expect(MyMgDesignTokens.fuelAccent, isNotNull);
    expect(MyMgDesignTokens.glassBorder, isNotNull);
  });

  test('spacing and touch tokens keep controls comfortable', () {
    expect(MyMgSpacing.page, greaterThanOrEqualTo(16));
    expect(MyMgSpacing.controlMin, greaterThanOrEqualTo(48));
    expect(MyMgRadius.card, lessThanOrEqualTo(24));
  });
}
