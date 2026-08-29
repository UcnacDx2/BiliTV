import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/api/video_api.dart';
import '../services/first_frame_quality_service.dart';
import '../services/settings_service.dart';
import '../services/video_shot_preview_service.dart';

/// Displays a normal cover immediately, then replaces it with a meaningful
/// first frame. Black/flat first frames fall back to a videoshot frame.
class FirstFrameOrCover extends StatefulWidget {
  const FirstFrameOrCover({
    super.key,
    required this.coverUrl,
    this.firstFrameUrl,
    this.bvid,
    this.cid,
    required this.width,
    required this.height,
    this.fit = BoxFit.cover,
  });

  final String coverUrl;
  final String? firstFrameUrl;
  final String? bvid;
  final int? cid;
  final double width;
  final double height;
  final BoxFit fit;

  @override
  State<FirstFrameOrCover> createState() => _FirstFrameOrCoverState();
}

class _FirstFrameOrCoverState extends State<FirstFrameOrCover> {
  String? _acceptedFirstFrame;
  Uint8List? _acceptedVideoShot;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _inspect();
  }

  @override
  void didUpdateWidget(covariant FirstFrameOrCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coverUrl != widget.coverUrl ||
        oldWidget.firstFrameUrl != widget.firstFrameUrl ||
        oldWidget.bvid != widget.bvid ||
        oldWidget.cid != widget.cid) {
      _acceptedFirstFrame = null;
      _acceptedVideoShot = null;
      _inspect();
    }
  }

  Future<void> _inspect() async {
    final generation = ++_generation;
    if (!SettingsService.useFirstFrameAsCover) return;

    var firstFrame = widget.firstFrameUrl;
    var resolvedCid = widget.cid;
    if ((firstFrame == null || firstFrame.isEmpty) &&
        widget.bvid?.isNotEmpty == true) {
      final info = await VideoApi.getVideoFirstFrameInfo(widget.bvid!);
      firstFrame = info?.url;
      resolvedCid ??= info?.cid;
      if (!mounted || generation != _generation) return;
    }
    if (firstFrame == null || firstFrame.isEmpty) return;

    if (await FirstFrameQualityService.isUsable(firstFrame)) {
      if (mounted && generation == _generation) {
        setState(() => _acceptedFirstFrame = firstFrame);
      }
      return;
    }

    final bvid = widget.bvid;
    final cid = resolvedCid;
    if (bvid == null || bvid.isEmpty || cid == null || cid <= 0) return;
    final videoShot = await VideoShotPreviewService.resolve(
      bvid: bvid,
      cid: cid,
    );
    if (!mounted || generation != _generation || videoShot == null) return;
    setState(() => _acceptedVideoShot = videoShot.bytes);
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _acceptedVideoShot;
    if (bytes != null) {
      return Image.memory(
        bytes,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
      );
    }
    return CachedNetworkImage(
      imageUrl: _acceptedFirstFrame ?? widget.coverUrl,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      memCacheWidth: widget.width.round(),
      memCacheHeight: widget.height.round(),
      cacheManager: BiliCacheManager.instance,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      placeholder: (context, url) => Container(
        width: widget.width,
        height: widget.height,
        color: const Color(0xFF2d2d2d),
      ),
      errorWidget: (context, url, error) => Container(
        width: widget.width,
        height: widget.height,
        color: Colors.grey[900],
        child: const Icon(Icons.broken_image, color: Colors.white24),
      ),
    );
  }
}
