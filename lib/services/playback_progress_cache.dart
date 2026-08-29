import 'package:shared_preferences/shared_preferences.dart';

/// 本地播放进度缓存管理器
///
/// 用于在退出播放器时保存进度，并在下次进入时恢复。
/// 这解决了 B站 API 的 `history` 字段不总是返回的问题。
///
/// 一个视频只保存一个最新进度（和 B站 API 行为一致）。
class PlaybackProgressCache {
  static SharedPreferences? _prefs;
  static const String _progressPrefix = 'playback_progress_v3_';
  static const String _cidPrefix = 'playback_cid_v3_';

  /// 初始化
  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// 保存播放进度（覆盖之前的进度）
  ///
  /// [bvid] 视频 BVID
  /// [cid] 当前分P的 CID
  /// [progress] 播放进度（秒）
  static Future<void> saveProgress(
    String bvid,
    int cid,
    int progress, {
    int? accountMid,
  }) async {
    await init();
    final suffix = _suffix(bvid, accountMid);
    await _prefs?.setInt('$_progressPrefix$suffix', progress);
    await _prefs?.setInt('$_cidPrefix$suffix', cid);
  }

  /// 获取缓存的完整记录（CID 和进度）
  ///
  /// [bvid] 视频 BVID
  /// 返回 (cid, progress)，如果没有缓存则返回 null
  static Future<({int cid, int progress})?> getCachedRecord(
    String bvid, {
    int? accountMid,
  }) async {
    await init();
    final suffix = _suffix(bvid, accountMid);
    var cachedCid = _prefs?.getInt('$_cidPrefix$suffix');
    var cachedProgress = _prefs?.getInt('$_progressPrefix$suffix');

    // A cache created before account isolation is still useful for the
    // first migrated account, but never becomes the write target again.
    if (accountMid != null && (cachedCid == null || cachedProgress == null)) {
      cachedCid = _prefs?.getInt('$_cidPrefix$bvid');
      cachedProgress = _prefs?.getInt('$_progressPrefix$bvid');
    }

    if (cachedCid != null &&
        cachedCid > 0 &&
        cachedProgress != null &&
        cachedProgress > 0) {
      return (cid: cachedCid, progress: cachedProgress);
    }
    return null;
  }

  /// 清除指定视频的进度缓存（播放完成时调用）
  static Future<void> clearProgress(String bvid, {int? accountMid}) async {
    await init();
    final suffix = _suffix(bvid, accountMid);
    await _prefs?.remove('$_progressPrefix$suffix');
    await _prefs?.remove('$_cidPrefix$suffix');
  }

  static String _suffix(String bvid, int? accountMid) =>
      accountMid == null ? bvid : '${accountMid}_$bvid';
}
