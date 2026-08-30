import 'dart:isolate';
import 'dart:math' show max, min;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'watermark_region.dart';

enum WatermarkMode { disabled, bilibili, bilibiliAuto, advanced }

class WatermarkFrame {
  const WatermarkFrame({required this.width, required this.height, required this.luma});
  final int width;
  final int height;
  final Uint8List luma;

  static Future<WatermarkFrame?> fromImage(
    ui.Image image, {
    int targetWidth = 480,
    bool upscale = false,
  }) async {
    final width = upscale ? targetWidth : min(targetWidth, image.width);
    final height = max(1, (image.height * width / image.width).round());
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.low,
    );
    final picture = recorder.endRecording();
    final scaled = await picture.toImage(width, height);
    picture.dispose();
    final data = await scaled.toByteData(format: ui.ImageByteFormat.rawRgba);
    scaled.dispose();
    if (data == null) return null;
    final rgba = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final luma = Uint8List(width * height);
    for (var i = 0; i < luma.length; i++) {
      final p = i * 4;
      luma[i] = (rgba[p] * 77 + rgba[p + 1] * 150 + rgba[p + 2] * 29) >> 8;
    }
    return WatermarkFrame(width: width, height: height, luma: luma);
  }
}

/// CPU analysis runs only on downloaded official videoshot thumbnails. It is
/// deliberately isolated from the player render path.
abstract final class WatermarkDetector {
  static const _template = [
    '.###...............###...............',
    '#####........##...#####........##....',
    '#####.......####.######.......####...',
    '#####.......####..#####......#####...',
    '#####.....######.######.....######.#.',
    '#####....###########.##....#########.',
    '.####....##############....##########',
    '.####....##############....###.######',
    '.####.....####.#.#.####....##########',
    '.#######..###############..######.###',
    '.##.#########.###################.###',
    '.######################.########.####',
    '.###############################.####',
    '.################.#############.#####',
    '.###.################################',
    '..##########################.########',
    '..#######...#....#..#######...#...##.',
    '...###...............##..............',
  ];

  static Future<List<WatermarkRegion>> detectBilibili(List<WatermarkFrame> frames) {
    if (frames.length < 3 || !_sameSize(frames)) return Future.value(const []);
    return Isolate.run(() => _detectBilibili(frames));
  }

  static Future<List<WatermarkRegion>> detectAdvanced(List<WatermarkFrame> frames) {
    if (frames.length < 6 || !_sameSize(frames)) return Future.value(const []);
    return Isolate.run(() => _detectAdvanced(frames));
  }

  static Future<WatermarkRegion?> detectSingleBilibili(WatermarkFrame frame) =>
      Isolate.run(() => _detectSingle(frame));

  static List<WatermarkRegion> merge(Iterable<WatermarkRegion> regions) =>
      WatermarkRegion.merge(regions);

  static bool _sameSize(List<WatermarkFrame> f) => f.every(
        (x) => x.width == f.first.width && x.height == f.first.height,
      );

  static List<WatermarkRegion> _detectBilibili(List<WatermarkFrame> frames) {
    final width = frames.first.width;
    final height = frames.first.height;
    final results = <WatermarkRegion>[];
    for (final corner in _corners) {
      final matches = <_Match>[];
      for (final frame in frames) {
        final edge = _edge(frame);
        final match = _bestMatch(edge, width, height, corner);
        if (match.score >= 0.78) matches.add(match);
      }
      if (matches.length < 3) continue;
      matches.sort((a, b) => b.score.compareTo(a.score));
      final seed = matches.first;
      final stable = matches.where((m) => (m.x - seed.x).abs() <= 6 && (m.y - seed.y).abs() <= 6).toList();
      if (stable.length < 3) continue;
      final x = stable.map((m) => m.x).toList()..sort();
      final y = stable.map((m) => m.y).toList()..sort();
      final anchorX = x[x.length ~/ 2];
      final anchorY = y[y.length ~/ 2];
      final tw = _template.first.length;
      final th = _template.length;
      results.add(WatermarkRegion(
        left: max(0, anchorX - (tw * 1.5).round()) / width,
        top: max(0, anchorY - 5) / height,
        right: min(width, anchorX + tw + 6) / width,
        bottom: min(height, anchorY + th + 6) / height,
        confidence: stable.map((m) => m.score).reduce((a, b) => a + b) / stable.length,
      ));
    }
    return results;
  }

  static WatermarkRegion? _detectSingle(WatermarkFrame frame) {
    final edge = _edge(frame);
    final best = _corners.map((c) => _bestMatch(edge, frame.width, frame.height, c)).toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    if (best.isEmpty ||
        best.first.score < 0.88 ||
        best.first.noise > 0.65 ||
        best.first.score - best[1].score < 0.2) {
      return null;
    }
    final m = best.first;
    final w = frame.width;
    final h = frame.height;
    final tw = _template.first.length;
    final th = _template.length;
    final top = max(1, m.y - 4);
    final bottom = min(h - 1, m.y + th + 4);
    final right = min(w, m.x + tw + 4);
    final scanLimit = max(0, right - (w * 0.44).round());
    final minimumActiveEdges = max(3, ((bottom - top + 1) * 0.18).round());
    final maxBlankRun = max(7, (w * 0.015).round());
    var left = m.x;
    var blankRun = 0;
    var stoppedAtBlank = false;
    for (var x = m.x - 1; x >= scanLimit; x--) {
      var edgeCount = 0;
      for (var y = top; y <= bottom; y++) {
        if (edge[y * w + x] != 0) edgeCount++;
      }
      if (edgeCount >= minimumActiveEdges) {
        left = x;
        blankRun = 0;
      } else {
        blankRun++;
        if (blankRun >= maxBlankRun) {
          stoppedAtBlank = true;
          break;
        }
      }
    }
    if (!stoppedAtBlank && left <= scanLimit + 1) left = m.x;
    final paddingX = max(4, (w * 0.008).round());
    final paddingY = max(3, (h * 0.01).round());
    return WatermarkRegion(
      left: max(0, left - paddingX) / w,
      top: max(0, top - paddingY) / h,
      right: min(w, right + paddingX) / w,
      bottom: min(h, bottom + paddingY) / h,
      confidence: m.score,
    );
  }

  static List<WatermarkRegion> _detectAdvanced(List<WatermarkFrame> frames) {
    final w = frames.first.width;
    final h = frames.first.height;
    final result = <WatermarkRegion>[];
    for (final corner in _corners) {
      final roi = _roi(w, h, corner, .30, .25);
      final mask = Uint8List(roi.width * roi.height);
      final gradients = frames.map(_gradient).toList();
      final required = (frames.length * .6).ceil();
      for (var y = 1; y < roi.height - 1; y++) {
        for (var x = 1; x < roi.width - 1; x++) {
          var count = 0;
          final source = (roi.top + y) * w + roi.left + x;
          for (final g in gradients) {
            if (g[source] > 8) count++;
          }
          if (count >= required) mask[y * roi.width + x] = 1;
        }
      }
      final components = _components(_dilate(mask, roi.width, roi.height, 2, 2), roi.width, roi.height);
      components.sort((a, b) => b.area.compareTo(a.area));
      for (final c in components) {
        if (c.area < .002 * w * h || c.width < 14 || c.height < 6 || c.width > .29 * w || c.height > .22 * h) continue;
        final outerGap = corner.left ? c.left : roi.width - c.right;
        if (outerGap <= 0 || outerGap > .085 * w) continue;
        final x1 = roi.left + c.left;
        final y1 = roi.top + c.top;
        final x2 = roi.left + c.right;
        final y2 = roi.top + c.bottom;
        if ((corner.top && y2 > .25 * h) || (!corner.top && y1 < .75 * h)) continue;
        result.add(WatermarkRegion(
          left: max(0, x1 - (w * .015).round()) / w,
          top: max(0, y1 - (h * .015).round()) / h,
          right: min(w, x2 + (w * .015).round()) / w,
          bottom: min(h, y2 + (h * .015).round()) / h,
          confidence: min(1, c.area / (.006 * w * h)),
        ));
        break;
      }
    }
    return result;
  }

  static Uint8List _edge(WatermarkFrame f) {
    final out = Uint8List(f.luma.length);
    for (var y = 1; y < f.height - 1; y++) {
      for (var x = 1; x < f.width - 1; x++) {
        final i = y * f.width + x;
        final dx = (f.luma[i + 1] - f.luma[i - 1]).abs();
        final dy = (f.luma[i + f.width] - f.luma[i - f.width]).abs();
        if ((dx + dy) ~/ 2 > 8) out[i] = 1;
      }
    }
    return out;
  }

  static Uint8List _gradient(WatermarkFrame f) => _edge(f);

  static _Match _bestMatch(Uint8List edge, int w, int h, _Corner c) {
    final tw = _template.first.length;
    final th = _template.length;
    final template = [for (final row in _template) for (final char in row.codeUnits) char == 35 ? 1 : 0];
    final count = template.where((x) => x != 0).length;
    final backgroundCount = template.length - count;
    final roi = _roi(w, h, c, .25, .18);
    var best = _Match(c, 0, 0, 0, 1);
    for (var y = roi.top; y <= roi.bottom - th; y++) {
      for (var x = roi.left; x <= roi.right - tw; x++) {
        var hit = 0;
        var backgroundEdges = 0;
        for (var ty = 0; ty < th; ty++) {
          for (var tx = 0; tx < tw; tx++) {
            if (edge[(y + ty) * w + x + tx] == 0) continue;
            if (template[ty * tw + tx] != 0) {
              hit++;
            } else {
              backgroundEdges++;
            }
          }
        }
        final score = hit / count;
        final noise = backgroundEdges / backgroundCount;
        if (score > best.score || (score == best.score && noise < best.noise)) {
          best = _Match(c, x, y, score, noise);
        }
      }
    }
    return best;
  }

  static Uint8List _dilate(Uint8List source, int w, int h, int rx, int ry) {
    final out = Uint8List(source.length);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (source[y * w + x] == 0) continue;
        for (var yy = max(0, y - ry); yy <= min(h - 1, y + ry); yy++) {
          for (var xx = max(0, x - rx); xx <= min(w - 1, x + rx); xx++) {
            out[yy * w + xx] = 1;
          }
        }
      }
    }
    return out;
  }

  static List<_Component> _components(Uint8List mask, int w, int h) {
    final visited = Uint8List(mask.length);
    final queue = Int32List(mask.length);
    final out = <_Component>[];
    for (var start = 0; start < mask.length; start++) {
      if (mask[start] == 0 || visited[start] != 0) continue;
      var head = 0, tail = 0, left = start % w, right = left + 1, top = start ~/ w, bottom = top + 1, area = 0;
      queue[tail++] = start; visited[start] = 1;
      while (head < tail) {
        final i = queue[head++], x = i % w, y = i ~/ w;
        area++; left = min(left, x); right = max(right, x + 1); top = min(top, y); bottom = max(bottom, y + 1);
        for (var yy = max(0, y - 1); yy <= min(h - 1, y + 1); yy++) {
          for (var xx = max(0, x - 1); xx <= min(w - 1, x + 1); xx++) {
            final n = yy * w + xx;
            if (mask[n] != 0 && visited[n] == 0) { visited[n] = 1; queue[tail++] = n; }
          }
        }
      }
      out.add(_Component(left, top, right, bottom, area));
    }
    return out;
  }

  static _Roi _roi(int w, int h, _Corner c, double wf, double hf) => _Roi(
        c.left ? 0 : w - (w * wf).round(),
        c.top ? 0 : h - (h * hf).round(),
        (w * wf).round(),
        (h * hf).round(),
      );
}

class _Corner { const _Corner(this.left, this.top); final bool left; final bool top; }
const _corners = [_Corner(true, true), _Corner(false, true), _Corner(true, false), _Corner(false, false)];
class _Match { const _Match(this.corner, this.x, this.y, this.score, this.noise); final _Corner corner; final int x; final int y; final double score; final double noise; }
class _Roi { const _Roi(this.left, this.top, this.width, this.height); final int left; final int top; final int width; final int height; int get right => left + width; int get bottom => top + height; }
class _Component { const _Component(this.left, this.top, this.right, this.bottom, this.area); final int left; final int top; final int right; final int bottom; final int area; int get width => right - left; int get height => bottom - top; }
