import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;

import 'api/base_api.dart';
import 'api/video_api.dart';
import 'watermark_detector.dart';
import 'watermark_region.dart';

/// Detects the standard creator mark from the first-frame URL returned by the
/// pagelist request. It never reads back the rendered player surface.
abstract final class FirstFrameWatermarkService {
  static const _maxEntries = 160;
  static final LinkedHashMap<String, Future<WatermarkRegion?>> _cache =
      LinkedHashMap();

  static Future<WatermarkRegion?> detect(String bvid) {
    if (bvid.isEmpty) return Future.value();
    final cached = _cache.remove(bvid);
    if (cached != null) {
      _cache[bvid] = cached;
      return cached;
    }
    final request = _resolve(bvid);
    _cache[bvid] = request;
    while (_cache.length > _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    return request;
  }

  static Future<WatermarkRegion?> _resolve(String bvid) async {
    try {
      final info = await VideoApi.getVideoFirstFrameInfo(bvid);
      if (info == null || info.url.isEmpty) return null;
      final response = await http.get(
        Uri.parse(_analysisUrl(info.url)),
        headers: BaseApi.getHeaders(),
      );
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return null;

      ui.Codec? codec;
      ui.Image? image;
      try {
        codec = await ui.instantiateImageCodec(
          Uint8List.fromList(response.bodyBytes),
          targetWidth: 480,
        );
        image = (await codec.getNextFrame()).image;
        final frame = await WatermarkFrame.fromImage(
          image,
          targetWidth: 480,
          upscale: true,
        );
        return frame == null
            ? null
            : await WatermarkDetector.detectSingleBilibili(frame);
      } finally {
        image?.dispose();
        codec?.dispose();
      }
    } catch (_) {
      _cache.remove(bvid);
      return null;
    }
  }

  static String _analysisUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    final isBiliCdn = uri.host.endsWith('.hdslb.com') ||
        uri.host.endsWith('.bilivideo.com') ||
        uri.host.endsWith('.biliimg.com');
    if (!isBiliCdn) return url;
    final separator = uri.path.contains('@') ? '_' : '@';
    return uri
        .replace(path: '${uri.path}${separator}480w_85q.webp')
        .toString();
  }
}
