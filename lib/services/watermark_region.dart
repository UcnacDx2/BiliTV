import 'dart:math' show max, min;

enum WatermarkPosition { topLeft, topRight, bottomLeft, bottomRight }

class WatermarkRegion {
  const WatermarkRegion({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    this.confidence = 1,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;
  final double confidence;

  factory WatermarkRegion.fixed(WatermarkPosition position) {
    const marginX = 0.012;
    const marginY = 0.012;
    const width = 0.44;
    const height = 0.11;
    final left = switch (position) {
      WatermarkPosition.topLeft || WatermarkPosition.bottomLeft => marginX,
      WatermarkPosition.topRight || WatermarkPosition.bottomRight =>
        1 - marginX - width,
    };
    final top = switch (position) {
      WatermarkPosition.topLeft || WatermarkPosition.topRight => marginY,
      WatermarkPosition.bottomLeft || WatermarkPosition.bottomRight =>
        1 - marginY - height,
    };
    return WatermarkRegion(
      left: left,
      top: top,
      right: left + width,
      bottom: top + height,
    );
  }

  WatermarkRegion clamp() => WatermarkRegion(
        left: left.clamp(0, 1),
        top: top.clamp(0, 1),
        right: right.clamp(0, 1),
        bottom: bottom.clamp(0, 1),
        confidence: confidence,
      );

  static List<WatermarkRegion> merge(Iterable<WatermarkRegion> input) {
    final output = <WatermarkRegion>[];
    for (final region in input) {
      final area = _area(region);
      if (area <= 0) continue;
      final index = output.indexWhere((existing) {
        final overlap = _intersection(existing, region);
        return overlap / min(_area(existing), area) >= 0.5;
      });
      if (index < 0) {
        output.add(region.clamp());
      } else {
        final existing = output[index];
        output[index] = WatermarkRegion(
          left: min(existing.left, region.left),
          top: min(existing.top, region.top),
          right: max(existing.right, region.right),
          bottom: max(existing.bottom, region.bottom),
          confidence: max(existing.confidence, region.confidence),
        ).clamp();
      }
    }
    return output;
  }

  static double _area(WatermarkRegion r) =>
      max(0, r.right - r.left) * max(0, r.bottom - r.top);

  static double _intersection(WatermarkRegion a, WatermarkRegion b) =>
      max(0, min(a.right, b.right) - max(a.left, b.left)) *
      max(0, min(a.bottom, b.bottom) - max(a.top, b.top));
}
