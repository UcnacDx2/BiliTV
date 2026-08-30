import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'screens/splash_screen.dart'; // 引入 Splash Screen
import 'screens/mpv_gpu_probe_screen.dart';
import 'package:bili_tv_app/core/plugin/plugin_manager.dart';
import 'package:bili_tv_app/plugins/sponsor_block_plugin.dart';
import 'package:bili_tv_app/plugins/ad_filter_plugin.dart';
import 'package:bili_tv_app/plugins/danmaku_enhance_plugin.dart';
import 'services/auth_service.dart';
import 'services/local_server.dart';
import 'services/mpv_debug_control.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Required by the isolated libmpv research probe. The production player
  // remains on video_player until the GPU VO gate passes.
  MediaKit.ensureInitialized();
  await MpvDebugControl.initialize();

  // 🔥 增大图片内存缓存，防止播放视频时主页图片被回收
  PaintingBinding.instance.imageCache.maximumSize = 500; // 500张图片
  PaintingBinding.instance.imageCache.maximumSizeBytes = 200 << 20; // 200MB

  // 初始化插件管理器并注册插件
  final pluginManager = PluginManager();
  await pluginManager.init();
  pluginManager.register(SponsorBlockPlugin());
  pluginManager.register(AdFilterPlugin());
  pluginManager.register(DanmakuEnhancePlugin());

  // 启动本地 HTTP 服务 (提供插件配置 API)
  await LocalServer.instance.start();

  await AuthService.init(); // 全屏模式 - 隐藏状态栏和导航栏
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  // 初始化逻辑已移交至 SplashScreen 处理，这里仅启动 APP
  // 这样可以确保启动画面迅速出现，无需等待初始化完成

  runApp(const BiliTvApp());
}

class BiliTvApp extends StatelessWidget {
  const BiliTvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BiliTV',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
        primaryColor: const Color(0xFFfb7299), // Bilibili 粉色
        useMaterial3: true,
        focusColor: Colors.white.withValues(alpha: 0.1),
      ),
      home: const bool.fromEnvironment('MPV_GPU_PROBE')
          ? MpvGpuProbeScreen()
          : SplashScreen(),
    );
  }
}
