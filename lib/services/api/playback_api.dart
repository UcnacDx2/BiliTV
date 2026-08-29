import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'base_api.dart';
import 'sign_utils.dart';
import '../auth_service.dart';
import '../codec_service.dart';
import '../settings_service.dart';
import '../account_store.dart';

/// 播放相关 API (视频详情、播放地址、弹幕、进度上报)
class PlaybackApi {
  /// 获取视频详情（包含分P信息和播放历史）
  static Future<Map<String, dynamic>?> getVideoInfo(
    String bvid, {
    AccountRole role = AccountRole.video,
  }) async {
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final url =
          'https://api.bilibili.com/x/web-interface/view?bvid=$bvid&_=$timestamp';
      final headers = BaseApi.getHeaders(withCookie: true, role: role);
      debugPrint(
        '🎬 [API] getVideoInfo headers: ${headers['Cookie'] != null ? 'Cookie present' : 'NO COOKIE'}',
      );

      final response = await http.get(Uri.parse(url), headers: headers);
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json['code'] == 0) {
          return json['data'];
        }
      }
    } catch (e) {
      // print('getVideoInfo error: $e');
    }
    return null;
  }

  /// 获取视频的 cid (用于播放和弹幕)
  static Future<int?> getVideoCid(String bvid) async {
    try {
      final url = 'https://api.bilibili.com/x/web-interface/view?bvid=$bvid';

      final response = await http.get(
        Uri.parse(url),
        headers: BaseApi.getHeaders(role: AccountRole.video),
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json['code'] == 0 && json['data'] != null) {
          return json['data']['cid'];
        }
      }
    } catch (e) {
      // print('getVideoCid error: $e');
    }
    return null;
  }

  /// 获取视频播放地址
  /// 返回 {'url': String, 'audioUrl': String?, 'qualities': List<Map>, 'currentQuality': int, 'isDash': bool}
  /// [forceCodec] 强制指定编码器 (用于失败重试)
  static Future<Map<String, dynamic>?> getVideoPlayUrl({
    required String bvid,
    required int cid,
    int qn = 80,
    VideoCodec? forceCodec,
  }) async {
    try {
      await BaseApi.ensureWbiKeys();

      final params = {
        'bvid': bvid,
        'cid': cid.toString(),
        'qn': qn.toString(),
        'fnval': '4048', // 请求 DASH + HEVC + AV1 + HDR 等全格式
        'fnver': '0',
        'fourk': '1',
      };

      var signedParams = params;
      final imgKey = BaseApi.imgKey;
      final subKey = BaseApi.subKey;
      if (imgKey != null &&
          imgKey.isNotEmpty &&
          subKey != null &&
          subKey.isNotEmpty) {
        signedParams = SignUtils.signWithWbi(params, imgKey, subKey);
      }
      final queryString = signedParams.entries
          .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
          .join('&');
      final url = 'https://api.bilibili.com/x/player/playurl?$queryString';

      final response = await http.get(
        Uri.parse(url),
        // The account assigned to the video role owns the playable source.
        headers: BaseApi.getHeaders(withCookie: true, role: AccountRole.video),
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json['code'] == 0 && json['data'] != null) {
          final data = json['data'];

          final qualities = <Map<String, dynamic>>[];
          final acceptQuality = data['accept_quality'] as List? ?? [];
          final acceptDesc = data['accept_description'] as List? ?? [];
          for (int i = 0; i < acceptQuality.length; i++) {
            qualities.add({
              'qn': acceptQuality[i],
              'desc': i < acceptDesc.length
                  ? acceptDesc[i]
                  : '${acceptQuality[i]}P',
            });
          }

          String? videoUrl;
          String? audioUrl;
          bool isDash = false;

          if (data['dash'] != null) {
            isDash = true;
            final dash = data['dash'];
            final videos = dash['video'] as List? ?? [];
            final audios = dash['audio'] as List? ?? [];

            if (videos.isNotEmpty) {
              final videosByQuality = <int, List<dynamic>>{};
              for (final v in videos) {
                final id = v['id'] as int? ?? 0;
                videosByQuality.putIfAbsent(id, () => []).add(v);
              }

              final targetQn = qn;
              var candidateVideos = videosByQuality[targetQn];
              if (candidateVideos == null || candidateVideos.isEmpty) {
                final sortedQualities = videosByQuality.keys.toList()
                  ..sort(
                    (a, b) =>
                        (b - targetQn).abs().compareTo((a - targetQn).abs()),
                  );
                if (sortedQualities.isNotEmpty) {
                  candidateVideos = videosByQuality[sortedQualities.first];
                }
              }
              candidateVideos ??= videos;

              dynamic selectedVideo;

              // 获取硬件解码器支持列表
              final hwDecoders = await CodecService.getHardwareDecoders();
              final hasAv1Hw = hwDecoders.contains('av1');
              final hasHevcHw = hwDecoders.contains('hevc');
              final hasAvcHw = hwDecoders.contains('avc');

              // 1. 如果指定了 forceCodec（失败回退时），优先使用
              if (forceCodec != null && forceCodec != VideoCodec.auto) {
                selectedVideo = candidateVideos.firstWhere((v) {
                  final codecs = v['codecs'] as String? ?? '';
                  return codecs.startsWith(forceCodec.prefix);
                }, orElse: () => null);
              }

              // 2. 首次尝试（forceCodec==null），使用用户设置
              if (selectedVideo == null && forceCodec == null) {
                final userCodec = SettingsService.preferredCodec;

                if (userCodec != VideoCodec.auto) {
                  // 用户指定了具体编码器
                  selectedVideo = candidateVideos.firstWhere((v) {
                    final codecs = v['codecs'] as String? ?? '';
                    return codecs.startsWith(userCodec.prefix);
                  }, orElse: () => null);
                } else {
                  // 用户设置是"自动"，智能选硬解最优: AV1 > HEVC > AVC
                  if (hasAv1Hw) {
                    selectedVideo = candidateVideos.firstWhere((v) {
                      final codecs = v['codecs'] as String? ?? '';
                      return codecs.startsWith('av01');
                    }, orElse: () => null);
                  }

                  if (selectedVideo == null && hasHevcHw) {
                    selectedVideo = candidateVideos.firstWhere((v) {
                      final codecs = v['codecs'] as String? ?? '';
                      return codecs.startsWith('hev') ||
                          codecs.startsWith('hvc');
                    }, orElse: () => null);
                  }

                  if (selectedVideo == null && hasAvcHw) {
                    selectedVideo = candidateVideos.firstWhere((v) {
                      final codecs = v['codecs'] as String? ?? '';
                      return codecs.startsWith('avc');
                    }, orElse: () => null);
                  }
                }
              }

              // 3. 兜底：确保有视频（可能会用软解）
              selectedVideo ??= candidateVideos.first;

              videoUrl = selectedVideo['baseUrl'] ?? selectedVideo['base_url'];
              final selectedCodec = selectedVideo['codecs'] as String? ?? '';

              if (audios.isNotEmpty) {
                var sortedAudios = List.from(audios);
                sortedAudios.sort(
                  (a, b) =>
                      (b['bandwidth'] ?? 0).compareTo(a['bandwidth'] ?? 0),
                );
                audioUrl =
                    sortedAudios.first['baseUrl'] ??
                    sortedAudios.first['base_url'];
              }

              if (videoUrl != null) {
                return await _attachAccountAwareResume(
                  {
                    'url': videoUrl,
                    'audioUrl': audioUrl,
                    'qualities': qualities,
                    'currentQuality': data['quality'] ?? qn,
                    'isDash': isDash,
                    'codec': selectedCodec,
                    'dashData': data['dash'],
                  },
                  playUrl: Uri.parse(url),
                  data: data,
                );
              }
            }
          } else if (data['durl'] != null) {
            final durls = data['durl'] as List;
            if (durls.isNotEmpty) {
              videoUrl = durls[0]['url'];
              if (videoUrl != null) {
                return await _attachAccountAwareResume(
                  {
                    'url': videoUrl,
                    'qualities': qualities,
                    'currentQuality': data['quality'] ?? qn,
                    'isDash': false,
                    'dashData': null,
                  },
                  playUrl: Uri.parse(url),
                  data: data,
                );
              }
            }
          }
        } else {
          // API 返回错误码
          throw Exception(
            'API错误: ${json['code']} - ${json['message'] ?? '未知错误'}',
          );
        }
      } else {
        // HTTP 错误
        throw Exception('HTTP ${response.statusCode}');
      }
    } catch (e) {
      // 返回错误信息而不是 null
      return {'error': e.toString()};
    }
    return null;
  }

  /// The mobile-patches account split is intentional: the video account
  /// resolves the stream, while the history account supplies resume state.
  static Future<Map<String, dynamic>> _attachAccountAwareResume(
    Map<String, dynamic> result, {
    required Uri playUrl,
    required Map<String, dynamic> data,
  }) async {
    result['lastPlayTime'] = BaseApi.toInt(data['last_play_time']);
    result['lastPlayCid'] = BaseApi.toInt(data['last_play_cid']);

    final videoMid = AuthService.videoAccount?.mid;
    final history = AuthService.historyAccount;
    if (history == null || videoMid == null || history.mid == videoMid) {
      return result;
    }

    try {
      final response = await http.get(
        playUrl,
        headers: BaseApi.getHeaders(
          withCookie: true,
          role: AccountRole.history,
        ),
      );
      if (response.statusCode != 200) return result;
      final json = jsonDecode(response.body);
      final historyData = json['data'] as Map<String, dynamic>?;
      if (json['code'] == 0 && historyData != null) {
        result['lastPlayTime'] = BaseApi.toInt(historyData['last_play_time']);
        result['lastPlayCid'] = BaseApi.toInt(historyData['last_play_cid']);
      }
    } catch (_) {
      // Stream resolution must remain usable if the secondary account fails.
    }
    return result;
  }

  /// 获取弹幕数据 (XML 格式，支持 deflate/gzip/raw)
  static Future<List<Map<String, dynamic>>> getDanmaku(int cid) async {
    try {
      final url = 'https://comment.bilibili.com/$cid.xml';

      final response = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36',
          'Accept-Encoding': 'gzip, deflate',
        },
      );

      if (response.statusCode == 200) {
        String xmlString;
        final bytes = response.bodyBytes;

        if (bytes.isEmpty) return [];

        try {
          if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
            final decompressed = gzip.decode(bytes);
            xmlString = utf8.decode(decompressed);
          } else if (bytes.length >= 2 && bytes[0] == 0x78) {
            final decompressed = zlib.decode(bytes);
            xmlString = utf8.decode(decompressed);
          } else if (bytes.isNotEmpty && bytes[0] == 0x3c) {
            xmlString = utf8.decode(bytes);
          } else {
            final decompressed = ZLibDecoder(raw: true).convert(bytes);
            xmlString = utf8.decode(decompressed);
          }
        } catch (e) {
          xmlString = utf8.decode(bytes, allowMalformed: true);
        }

        final danmakuList = <Map<String, dynamic>>[];

        final regex = RegExp(r'<d p="([^"]+)">([^<]*)</d>');
        for (final match in regex.allMatches(xmlString)) {
          final pAttr = match.group(1)!;
          final content = match.group(2)!;

          final parts = pAttr.split(',');
          if (parts.length >= 4) {
            danmakuList.add({
              'time': double.tryParse(parts[0]) ?? 0.0,
              'type': int.tryParse(parts[1]) ?? 1,
              'fontSize': double.tryParse(parts[2]) ?? 25.0,
              'color': int.tryParse(parts[3]) ?? 0xFFFFFF,
              'content': content,
            });
          }
        }

        return danmakuList;
      }
    } catch (e) {
      // 忽略错误
    }
    return [];
  }

  /// 上报播放进度 (Heartbeat)
  static Future<bool> reportProgress({
    required String bvid,
    required int cid,
    required int progress,
  }) async {
    if (!AuthService.isLoggedIn) return false;

    try {
      final startTs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final queryParams = {
        'bvid': bvid,
        'cid': cid.toString(),
        'played_time': progress.toString(),
        'real_played_time': progress.toString(),
        'start_ts': startTs.toString(),
        'csrf':
            AccountStore.accountFor(AccountRole.heartbeat)?.biliJct ??
            AuthService.biliJct ??
            '',
      };

      final queryString = queryParams.entries
          .map(
            (e) =>
                '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
          )
          .join('&');

      final url =
          'https://api.bilibili.com/x/click-interface/web/heartbeat?$queryString';

      final response = await http.post(
        Uri.parse(url),
        headers: BaseApi.getHeaders(
          withCookie: true,
          role: AccountRole.heartbeat,
        ),
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json['code'] == 0) {
          return true;
        }
      }
    } catch (e) {
      // 忽略错误
    }
    return false;
  }

  /// 获取视频在线观看人数
  /// 返回 { 'total': 总人数字符串, 'count': 本视频在线人数字符串 }
  static Future<Map<String, String>?> getOnlineCount({
    required int aid,
    required int cid,
  }) async {
    try {
      final url =
          'https://api.bilibili.com/x/player/online/total?aid=$aid&cid=$cid';
      final response = await http.get(
        Uri.parse(url),
        headers: BaseApi.getHeaders(
          withCookie: true,
          role: AccountRole.heartbeat,
        ),
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json['code'] == 0 && json['data'] != null) {
          final data = json['data'];
          return {'total': data['total'] ?? '', 'count': data['count'] ?? ''};
        }
      }
    } catch (e) {
      // 忽略错误
    }
    return null;
  }
}
