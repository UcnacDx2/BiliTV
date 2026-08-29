import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import '../services/api/video_api.dart';
import '../services/bilibili_api.dart';
import '../services/account_store.dart';
import '../services/api/videoshot_api.dart';
import '../services/video_shot_preview_service.dart';
import '../services/watermark_detector.dart';
import '../services/watermark_filter.dart';
import '../services/watermark_region.dart';
import '../services/mpv_playback_backend.dart';

/// Phase 0 feasibility screen for the watermark research branch.
///
/// This intentionally uses a bundled clip. It proves the Android libmpv GPU
/// VO and runtime GLSL hook independently from Bilibili authentication,
/// DASH, and the existing production player.
class MpvGpuProbeScreen extends StatefulWidget {
  const MpvGpuProbeScreen({super.key});

  @override
  State<MpvGpuProbeScreen> createState() => _MpvGpuProbeScreenState();
}

class _MpvGpuProbeScreenState extends State<MpvGpuProbeScreen> {
  late final Player _player;
  late final VideoController _videoController;
  late final MpvPlaybackBackend _playbackBackend;
  String? _shaderPath;
  String _status = '初始化 libmpv GPU 输出…';
  bool _shaderEnabled = false;
  List<WatermarkRegion> _regions = const [];
  StreamSubscription<PlayerLog>? _logSubscription;

  void _report(String message) {
    debugPrint('[MPV_PROBE] $message');
    if (mounted) setState(() => _status = message);
  }

  @override
  void initState() {
    super.initState();
    _player = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.info),
    );
    _playbackBackend = MpvPlaybackBackend(_player);
    _videoController = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        vo: 'gpu',
        hwdec: 'mediacodec-copy',
        enableHardwareAcceleration: true,
      ),
    );
    _logSubscription = _player.stream.log.listen((log) {
      if (!mounted || log.level == 'error') return;
      // Keep the probe's high-level result readable; libmpv's informational
      // logs are still visible through logcat and must not overwrite it.
      if (_status.startsWith('初始化') || _status.startsWith('GPU')) {
        setState(() => _status = '${log.prefix}: ${log.text}');
      }
    });
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      final directory = await getApplicationSupportDirectory();
      final shaderFile = File('${directory.path}/mpv_gpu_probe.glsl');
      final shaderData = await rootBundle.load(
        'assets/shaders/mpv_gpu_probe.glsl',
      );
      await shaderFile.writeAsBytes(shaderData.buffer.asUint8List());
      _shaderPath = shaderFile.path;
      _report('GPU probe: opening startup clip');
      await _player.open(Media('asset:///assets/icons/startup.mp4'));
      _report('GPU ready; resolving real Bilibili stream');
      await _tryRealBilibiliStream();
    } catch (error) {
      _report('GPU probe failed: $error');
    }
  }

  Future<void> _tryRealBilibiliStream() async {
    _report('Fetching popular videos');
    final videos = await VideoApi.getPopularVideos();
    _report('Popular videos received: ${videos.length}');
    if (videos.isEmpty) {
      await _setShader(true);
      _report('No popular videos; keeping GPU shader probe');
      return;
    }
    final video = videos.firstWhere(
      (item) => !item.isLive && item.bvid.isNotEmpty,
      orElse: () => videos.first,
    );
    _report('Resolving video info: ${video.bvid}');
    final info = await BilibiliApi.getVideoInfo(
      video.bvid,
      role: AccountRole.video,
    );
    final resolvedCid = (info?['cid'] as num?)?.toInt() ?? video.cid;
    if (resolvedCid <= 0) throw StateError('无法取得 CID');
    _report('Requesting playurl: ${video.bvid} cid=$resolvedCid');
    final playInfo = await BilibiliApi.getVideoPlayUrl(
      bvid: video.bvid,
      cid: resolvedCid,
      qn: 80,
    );
    final url = playInfo?['url'] as String?;
    if (url == null || url.isEmpty) {
      throw StateError('未取得视频 URL: ${playInfo?['error'] ?? 'unknown'}');
    }
    final headers = AccountStore.headers(AccountRole.video)
      ..['Origin'] = 'https://www.bilibili.com';
    final audioUrl = playInfo?['audioUrl'] as String?;
    _report(
      'Opening real DASH: qn=${playInfo?['currentQuality']} '
      'audio=${audioUrl == null || audioUrl.isEmpty ? 'missing' : 'present'}',
    );
    await _playbackBackend.open(
      MpvPlaybackSource(
        videoUrl: url,
        audioUrl: audioUrl,
        headers: headers,
        quality: playInfo?['currentQuality'] as int?,
        codec: playInfo?['codec'] as String?,
      ),
    );
    _report('Real stream opened: ${video.bvid}; reading official videoshot');
    await _detectFromOfficialVideoshot(video.bvid, resolvedCid);
  }

  Future<void> _detectFromOfficialVideoshot(String bvid, int cid) async {
    final data = await VideoshotApi.getVideoshot(
      bvid: bvid,
      cid: cid,
      preloadImages: false,
    );
    if (data == null || data.images.isEmpty) {
      await _setShader(true);
      if (mounted) setState(() => _status = '真实流正常；官方雪碧图不可用，已启用探针 Shader');
      return;
    }
    // Use the existing official-sprite crop service. It never captures the
    // rendered player surface and therefore remains seek-independent.
    final preview = await VideoShotPreviewService.resolve(bvid: bvid, cid: cid);
    if (preview == null) {
      await _setShader(true);
      if (mounted) setState(() => _status = '真实流正常；官方雪碧图没有可用帧');
      return;
    }
    final codec = await ui.instantiateImageCodec(preview.bytes);
    final image = (await codec.getNextFrame()).image;
    try {
      final frame = await WatermarkFrame.fromImage(image);
      final detected = frame == null
          ? null
          : await WatermarkDetector.detectSingleBilibili(frame);
      _regions = detected == null ? const [] : [detected];
      await WatermarkFilter.apply(_player, _shaderPath!, _regions);
      if (mounted) setState(() => _shaderEnabled = _regions.isNotEmpty);
      if (mounted) {
        setState(
          () => _status = _regions.isEmpty
              ? '真实流正常；未检测到 bilibili 锚点'
              : '真实流 + 官方雪碧图检测成功，已启用 GPU 去水印',
        );
      }
    } finally {
      image.dispose();
      codec.dispose();
    }
  }

  Future<void> _setShader(bool enabled) async {
    final path = _shaderPath;
    if (path == null) return;
    if (enabled) {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        await platform.command(['change-list', 'glsl-shaders', 'append', path]);
      }
    } else {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        await platform.command(['change-list', 'glsl-shaders', 'remove', path]);
      }
    }
    if (mounted) setState(() => _shaderEnabled = enabled);
  }

  @override
  void dispose() {
    _logSubscription?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Video(controller: _videoController),
          Positioned(
            left: 24,
            top: 24,
            child: DecoratedBox(
              decoration: const BoxDecoration(color: Colors.black54),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_status, style: const TextStyle(fontSize: 16)),
              ),
            ),
          ),
          Positioned(
            left: 24,
            bottom: 24,
            child: Row(
              children: [
                ElevatedButton(
                  onPressed: _shaderPath == null
                      ? null
                      : () => _setShader(!_shaderEnabled),
                  child: Text(_shaderEnabled ? 'Remove GLSL' : 'Apply GLSL'),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: () async {
                    final target =
                        _player.state.position - const Duration(seconds: 30);
                    await _playbackBackend.seek(
                      target.isNegative ? Duration.zero : target,
                    );
                  },
                  child: const Text('-30s'),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: () async {
                    await _playbackBackend.seek(
                      _player.state.position + const Duration(seconds: 30),
                    );
                  },
                  child: const Text('+30s'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
