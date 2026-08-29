import 'package:flutter_test/flutter_test.dart';
import 'package:bili_tv_app/services/watermark_filter.dart';
import 'package:bili_tv_app/services/watermark_region.dart';

void main() {
  test('fixed region maps to the selected corner', () {
    final region = WatermarkRegion.fixed(WatermarkPosition.topRight);
    expect(region.left, closeTo(0.548, 0.001));
    expect(region.top, closeTo(0.012, 0.001));
    expect(region.right, closeTo(0.988, 0.001));
  });

  test('shader contains only bounded regions and mpv hook', () {
    final shader = WatermarkFilter.shaderFor([
      const WatermarkRegion(
        left: 0.5,
        top: 0.1,
        right: 0.9,
        bottom: 0.2,
      ),
    ]);
    expect(shader, contains('//!HOOK MAIN'));
    expect(shader, contains('HOOKED_tex'));
    expect(shader, contains('0.500000'));
    expect(shader, contains('0.900000'));
    expect(shader, isNot(contains('PixelCopy')));
  });

  test('overlapping regions merge without stacking filters', () {
    final merged = WatermarkRegion.merge([
      const WatermarkRegion(left: .5, top: .5, right: .7, bottom: .7),
      const WatermarkRegion(left: .51, top: .51, right: .71, bottom: .71),
    ]);
    expect(merged, hasLength(1));
    expect(merged.single.right, closeTo(.71, .001));
  });
}
