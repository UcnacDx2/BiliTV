import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'api/videoshot_api.dart';
import '../models/videoshot.dart';
import 'first_frame_quality_service.dart';

class VideoShotPreview {
  const VideoShotPreview({
    required this.bytes,
    required this.timestamp,
    required this.frameIndex,
  });
  final Uint8List bytes;
  final int timestamp;
  final int frameIndex;
}

class VideoShotFrameLocation {
  const VideoShotFrameLocation({
    required this.spriteUrl,
    required this.frameIndex,
    required this.timestamp,
    required this.column,
    required this.row,
  });
  final String spriteUrl;
  final int frameIndex;
  final int timestamp;
  final int column;
  final int row;
}

final class _PreviewCacheEntry {
  const _PreviewCacheEntry(this.preview, this.expiresAt);
  final VideoShotPreview? preview;
  final DateTime expiresAt;
}

final class _MetadataCacheEntry {
  const _MetadataCacheEntry(this.data, this.expiresAt);
  final VideoshotData? data;
  final DateTime expiresAt;
}

final class _AsyncGate {
  _AsyncGate(this.limit);
  final int limit;
  int _active = 0;
  final Queue<Completer<void>> _waiting = Queue();

  Future<T> run<T>(Future<T> Function() action) async {
    if (_active >= limit) {
      final waiter = Completer<void>();
      _waiting.add(waiter);
      await waiter.future;
    }
    _active++;
    try {
      return await action();
    } finally {
      _active--;
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
    }
  }
}

/// Resolves a usable middle frame from Bilibili's videoshot sprite sheets.
abstract final class VideoShotPreviewService {
  static const _targetWidth = 320;
  static const _targetHeight = 180;
  static const _maxEntries = 96;
  static const _maxMetadataEntries = 48;
  static const _maxSpriteEntries = 12;
  static const _successTtl = Duration(hours: 12);
  static const _failureTtl = Duration(minutes: 10);
  static const _metadataTtl = Duration(minutes: 30);
  static final LinkedHashMap<String, _PreviewCacheEntry> _cache =
      LinkedHashMap();
  static final Map<String, Future<VideoShotPreview?>> _inFlight = {};
  static final LinkedHashMap<String, _MetadataCacheEntry> _metadataCache =
      LinkedHashMap();
  static final Map<String, Future<VideoshotData?>> _metadataInFlight = {};
  static final LinkedHashMap<String, Uint8List> _spriteCache = LinkedHashMap();
  static final Map<String, Future<Uint8List?>> _spriteInFlight = {};
  static final _metadataGate = _AsyncGate(3);
  static final _spriteGate = _AsyncGate(1);

  static Future<VideoShotPreview?> resolve({
    required String bvid,
    required int cid,
  }) {
    if (bvid.isEmpty || cid <= 0) return Future.value();
    final key = '$bvid:$cid';
    final now = DateTime.now();
    final cached = _cache.remove(key);
    if (cached != null && cached.expiresAt.isAfter(now)) {
      _cache[key] = cached;
      return Future.value(cached.preview);
    }

    return _inFlight.putIfAbsent(key, () async {
      VideoShotPreview? preview;
      try {
        preview = await _metadataGate.run(() async {
          final data = await _resolveMetadata(bvid, cid);
          if (data == null || !_isValid(data)) return null;
          return _spriteGate.run(() => _resolveFromMetadata(data));
        });
      } catch (_) {
        preview = null;
      } finally {
        _inFlight.remove(key);
      }
      _cache[key] = _PreviewCacheEntry(
        preview,
        DateTime.now().add(preview == null ? _failureTtl : _successTtl),
      );
      while (_cache.length > _maxEntries) {
        _cache.remove(_cache.keys.first);
      }
      return preview;
    });
  }

  static bool _isValid(VideoshotData data) =>
      data.images.isNotEmpty && data.imgXLen > 0 && data.imgYLen > 0;

  static Future<VideoshotData?> _resolveMetadata(String bvid, int cid) {
    final key = '$bvid:$cid';
    final now = DateTime.now();
    final cached = _metadataCache.remove(key);
    if (cached != null && cached.expiresAt.isAfter(now)) {
      _metadataCache[key] = cached;
      return Future.value(cached.data);
    }

    return _metadataInFlight.putIfAbsent(key, () async {
      VideoshotData? data;
      try {
        data = await VideoshotApi.getVideoshot(
          bvid: bvid,
          cid: cid,
          preloadImages: false,
        );
        if (data != null && !_isValid(data)) data = null;
      } catch (_) {
        data = null;
      } finally {
        _metadataInFlight.remove(key);
      }

      _metadataCache[key] = _MetadataCacheEntry(
        data,
        DateTime.now().add(data == null ? _failureTtl : _metadataTtl),
      );
      while (_metadataCache.length > _maxMetadataEntries) {
        _metadataCache.remove(_metadataCache.keys.first);
      }
      return data;
    });
  }

  static Future<Uint8List?> _loadSprite(String url) {
    final cached = _spriteCache.remove(url);
    if (cached != null) {
      _spriteCache[url] = cached;
      return Future.value(cached);
    }

    return _spriteInFlight.putIfAbsent(url, () async {
      try {
        final bytes = await VideoshotApi.downloadSprite(url);
        if (bytes == null || bytes.isEmpty) return null;
        _spriteCache[url] = bytes;
        while (_spriteCache.length > _maxSpriteEntries) {
          _spriteCache.remove(_spriteCache.keys.first);
        }
        return bytes;
      } finally {
        _spriteInFlight.remove(url);
      }
    });
  }

  static List<VideoShotFrameLocation> candidateLocations(VideoshotData data) {
    final indexes = data.frameIndexes;
    if (indexes.isEmpty) return const [];
    final locations = <VideoShotFrameLocation>[];
    final seen = <int>{};
    for (final ratio in const [0.50, 0.35, 0.65]) {
      final frameIndex = ((indexes.length - 1) * ratio).round();
      if (!seen.add(frameIndex)) continue;
      final pageIndex = frameIndex ~/ data.framesPerImage;
      if (pageIndex < 0 || pageIndex >= data.images.length) continue;
      final indexInPage = frameIndex % data.framesPerImage;
      locations.add(
        VideoShotFrameLocation(
          spriteUrl: data.images[pageIndex],
          frameIndex: frameIndex,
          timestamp: indexes[frameIndex],
          column: indexInPage % data.imgXLen,
          row: indexInPage ~/ data.imgXLen,
        ),
      );
    }
    return locations;
  }

  static Future<VideoShotPreview?> _resolveFromMetadata(
    VideoshotData data,
  ) async {
    final bySprite = <String, List<VideoShotFrameLocation>>{};
    for (final location in candidateLocations(data)) {
      bySprite.putIfAbsent(location.spriteUrl, () => []).add(location);
    }
    for (final entry in bySprite.entries) {
      final response = await _loadSprite(entry.key);
      if (response == null || response.isEmpty) continue;
      final result = await _decodeSprite(response, data, entry.value);
      if (result != null) return result;
    }
    return null;
  }

  static Future<VideoShotPreview?> _decodeSprite(
    Uint8List bytes,
    VideoshotData data,
    List<VideoShotFrameLocation> candidates,
  ) async {
    ui.Codec? codec;
    ui.Image? sprite;
    try {
      codec = await ui.instantiateImageCodec(bytes);
      sprite = (await codec.getNextFrame()).image;
      final sourceWidth = data.imgXSize > 0
          ? data.imgXSize.toDouble()
          : sprite.width / data.imgXLen;
      final sourceHeight = data.imgYSize > 0
          ? data.imgYSize.toDouble()
          : sprite.height / data.imgYLen;
      final scaleX = sprite.width / (data.imgXLen * sourceWidth);
      final scaleY = sprite.height / (data.imgYLen * sourceHeight);

      for (final candidate in candidates) {
        final source = ui.Rect.fromLTWH(
          candidate.column * sourceWidth * scaleX,
          candidate.row * sourceHeight * scaleY,
          sourceWidth * scaleX,
          sourceHeight * scaleY,
        );
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawImageRect(
          sprite,
          source,
          ui.Rect.fromLTWH(
            0,
            0,
            _targetWidth.toDouble(),
            _targetHeight.toDouble(),
          ),
          ui.Paint()..filterQuality = ui.FilterQuality.medium,
        );
        final picture = recorder.endRecording();
        ui.Image? cropped;
        try {
          cropped = await picture.toImage(_targetWidth, _targetHeight);
          final rgba = await cropped.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          if (rgba == null) continue;
          final quality = FirstFrameQualityAnalyzer.classify(
            FirstFrameQualityAnalyzer.metrics(rgba.buffer.asUint8List()),
          );
          if (quality != FirstFrameQuality.usable) continue;
          final png = await cropped.toByteData(format: ui.ImageByteFormat.png);
          if (png == null) continue;
          return VideoShotPreview(
            bytes: png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
            timestamp: candidate.timestamp,
            frameIndex: candidate.frameIndex,
          );
        } finally {
          cropped?.dispose();
          picture.dispose();
        }
      }
      return null;
    } finally {
      sprite?.dispose();
      codec?.dispose();
    }
  }
}
