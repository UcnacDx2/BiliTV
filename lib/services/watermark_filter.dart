import 'dart:io';

import 'package:media_kit/media_kit.dart';

import 'watermark_region.dart';

/// GPU-only watermark masking for the libmpv renderer.
///
/// No decoded frames cross into Dart. The shader samples neighbouring pixels
/// around each detected region, so the cost stays on the video GPU path.
abstract final class WatermarkFilter {
  static const maxRegions = 4;
  static const fileName = 'bili_tv_watermark.glsl';

  static String pathFor(String supportDirectory) =>
      '$supportDirectory${Platform.pathSeparator}$fileName';

  static String shaderFor(Iterable<WatermarkRegion> regions) {
    final selected = regions.take(maxRegions).toList(growable: false);
    final body = StringBuffer();
    for (var i = 0; i < selected.length; i++) {
      final r = selected[i];
      body
        ..writeln('  const vec4 region$i = vec4('
            '${_number(r.left)}, ${_number(r.top)}, '
            '${_number(r.right)}, ${_number(r.bottom)});')
        ..writeln('  ${i == 0 ? 'if' : 'else if'} '
            '(bili_inside(HOOKED_pos, region$i)) {')
        ..writeln('    color = bili_fill(HOOKED_pos, region$i, pad);')
        ..writeln('  }');
    }
    return '''//!HOOK MAIN
//!BIND HOOKED
//!DESC BiliTV watermark removal

vec4 bili_fill(vec2 uv, vec4 rect, vec2 pad) {
  vec2 size = max(rect.zw - rect.xy, vec2(0.000001));
  vec2 position = clamp((uv - rect.xy) / size, 0.0, 1.0);
  vec4 left = HOOKED_tex(vec2(max(rect.x - pad.x, 0.0), uv.y));
  vec4 right = HOOKED_tex(vec2(min(rect.z + pad.x, 1.0), uv.y));
  vec4 top = HOOKED_tex(vec2(uv.x, max(rect.y - pad.y, 0.0)));
  vec4 bottom = HOOKED_tex(vec2(uv.x, min(rect.w + pad.y, 1.0)));
  vec4 horizontal = mix(left, right, position.x);
  vec4 vertical = mix(top, bottom, position.y);
  if (rect.x <= pad.x) horizontal = right;
  if (rect.z >= 1.0 - pad.x) horizontal = left;
  if (rect.y <= pad.y) vertical = bottom;
  if (rect.w >= 1.0 - pad.y) vertical = top;
  float edgeX = min(position.x, 1.0 - position.x);
  float edgeY = min(position.y, 1.0 - position.y);
  float weight = edgeX / max(edgeX + edgeY, 0.000001);
  return mix(horizontal, vertical, weight);
}

bool bili_inside(vec2 uv, vec4 rect) {
  return uv.x >= rect.x && uv.x <= rect.z &&
      uv.y >= rect.y && uv.y <= rect.w;
}

vec4 hook() {
  vec4 color = HOOKED_tex(HOOKED_pos);
  vec2 pad = max(HOOKED_pt * 2.0, vec2(0.0005));
${body.toString()}  return color;
}
''';
  }

  static Future<void> clear(Player player, String path) async {
    try {
      final platform = player.platform;
      if (platform is NativePlayer) {
        await platform.command(['change-list', 'glsl-shaders', 'remove', path]);
      }
    } catch (_) {}
  }

  static Future<void> apply(
    Player player,
    String path,
    Iterable<WatermarkRegion> regions,
  ) async {
    await clear(player, path);
    final selected = regions.take(maxRegions).toList(growable: false);
    if (selected.isEmpty) return;
    await File(path).writeAsString(shaderFor(selected));
    final platform = player.platform;
    if (platform is NativePlayer) {
      await platform.command(['change-list', 'glsl-shaders', 'append', path]);
    }
  }

  static String _number(double value) {
    if (value == 0) return '0.0';
    if (value == 1) return '1.0';
    return value.toStringAsFixed(6);
  }
}
