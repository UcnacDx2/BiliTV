import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

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
  String? _shaderPath;
  String _status = '初始化 libmpv GPU 输出…';
  bool _shaderEnabled = false;
  StreamSubscription<PlayerLog>? _logSubscription;

  @override
  void initState() {
    super.initState();
    _player = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.info),
    );
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
      setState(() => _status = '${log.prefix}: ${log.text}');
    });
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      final directory = await getApplicationSupportDirectory();
      final shaderFile = File('${directory.path}/mpv_gpu_probe.glsl');
      final shaderData = await rootBundle.load('assets/shaders/mpv_gpu_probe.glsl');
      await shaderFile.writeAsBytes(shaderData.buffer.asUint8List());
      _shaderPath = shaderFile.path;
      await _player.open(Media('asset:///assets/icons/startup.mp4'));
      await _setShader(true);
      if (mounted) setState(() => _status = '播放中：右上角红色标记应来自 GLSL hook');
    } catch (error) {
      if (mounted) setState(() => _status = 'GPU probe failed: $error');
    }
  }

  Future<void> _setShader(bool enabled) async {
    final path = _shaderPath;
    if (path == null) return;
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    await platform.setProperty(
      'glsl-shaders',
      enabled ? path : '',
      waitForInitialization: false,
    );
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
            child: ElevatedButton(
              onPressed: _shaderPath == null ? null : () => _setShader(!_shaderEnabled),
              child: Text(_shaderEnabled ? 'Remove GLSL' : 'Apply GLSL'),
            ),
          ),
        ],
      ),
    );
  }
}
