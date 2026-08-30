import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'base_api.dart';
import 'sign_utils.dart';
import '../auth_service.dart';
import '../account_store.dart';
import '../../models/video.dart';
import '../recommendation_filter.dart';
import '../settings_service.dart';

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

/// 视频列表和搜索相关 API
class VideoFirstFrameInfo {
  const VideoFirstFrameInfo({required this.url, required this.cid});
  final String url;
  final int? cid;
}

class VideoApi {
  static const _firstFrameCacheMaxEntries = 320;
  static final LinkedHashMap<String, Future<VideoFirstFrameInfo?>>
  _firstFrameCache = LinkedHashMap();
  static final _firstFrameGate = _AsyncGate(3);

  /// First-frame metadata used by the mobile-patches cover pipeline.
  static Future<VideoFirstFrameInfo?> getVideoFirstFrameInfo(String bvid) {
    if (bvid.isEmpty) return Future.value();
    final cached = _firstFrameCache.remove(bvid);
    if (cached != null) {
      _firstFrameCache[bvid] = cached;
      return cached;
    }
    final request = () async {
      try {
        final response = await _firstFrameGate.run(
          () => http.get(
            Uri.parse(
              '${BaseApi.apiBase}/x/player/pagelist',
            ).replace(queryParameters: {'bvid': bvid}),
            headers: BaseApi.getHeaders(),
          ),
        );
        if (response.statusCode != 200) return null;
        final json = jsonDecode(response.body);
        final pages = json['data'] as List?;
        if (json['code'] == 0 && pages != null && pages.isNotEmpty) {
          final page = Map<String, dynamic>.from(pages.first as Map);
          final url = page['first_frame'] as String?;
          if (url != null && url.isNotEmpty) {
            return VideoFirstFrameInfo(
              url: BaseApi.fixPicUrl(url),
              cid: BaseApi.toInt(page['cid']),
            );
          }
        }
      } catch (_) {
        _firstFrameCache.remove(bvid);
      }
      return null;
    }();
    _firstFrameCache[bvid] = request;
    while (_firstFrameCache.length > _firstFrameCacheMaxEntries) {
      _firstFrameCache.remove(_firstFrameCache.keys.first);
    }
    return request;
  }

  /// Seeds the shared first-frame lookup when a list API already provided it.
  /// This avoids a second pagelist request when the same video is opened or
  /// appears in another card.
  static void rememberVideoFirstFrame({
    required String? bvid,
    required String? url,
    int? cid,
  }) {
    if (bvid == null || bvid.isEmpty || url == null || url.isEmpty) return;
    _firstFrameCache.remove(bvid);
    _firstFrameCache[bvid] = Future.value(
      VideoFirstFrameInfo(url: url, cid: cid),
    );
    while (_firstFrameCache.length > _firstFrameCacheMaxEntries) {
      _firstFrameCache.remove(_firstFrameCache.keys.first);
    }
  }

  /// 获取热门视频 (无需登录)
  static Future<List<Video>> getPopularVideos({int page = 1}) async {
    try {
      final uri = Uri.parse(
        '${BaseApi.apiBase}/x/web-interface/popular',
      ).replace(queryParameters: {'pn': page.toString(), 'ps': '20'});

      final response = await http.get(uri, headers: BaseApi.getHeaders());

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json['code'] == 0 && json['data'] != null) {
          final list = json['data']['list'] as List? ?? [];
          return list.map((item) => Video.fromRecommend(item)).toList();
        }
      }
    } catch (e) {
      // 忽略错误
    }
    return [];
  }

  /// 获取推荐视频 (需要 WBI 签名)
  static Future<List<Video>> getRecommendVideos({int idx = 0}) async {
    try {
      await BaseApi.ensureWbiKeys();

      Map<String, String> params = {
        'fresh_idx': idx.toString(),
        'fresh_type': '4',
        'ps': '20',
      };

      if (BaseApi.imgKey != null && BaseApi.subKey != null) {
        params = SignUtils.signWithWbi(
          params,
          BaseApi.imgKey!,
          BaseApi.subKey!,
        );
      }

      final uri = Uri.parse(
        '${BaseApi.apiBase}/x/web-interface/wbi/index/top/feed/rcmd',
      ).replace(queryParameters: params);

      final response = await http.get(
        uri,
        headers: BaseApi.getHeaders(withCookie: true),
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json['code'] == 0 && json['data'] != null) {
          final items = json['data']['item'] as List? ?? [];
          final videos = items
              .where((item) => item['bvid'] != null)
              .map((item) => Video.fromRecommend(item))
              .toList();
          return RecommendationFilter.minimumDuration(
            videos,
            SettingsService.minimumRecommendDuration,
          );
        }
      }
    } catch (e) {
      // 忽略错误
    }
    return [];
  }

  /// 获取分区视频 (按 tid)
  static Future<List<Video>> getRegionVideos({
    required int tid,
    int page = 1,
  }) async {
    try {
      final uri = Uri.parse('${BaseApi.apiBase}/x/web-interface/dynamic/region')
          .replace(
            queryParameters: {
              'rid': tid.toString(),
              'pn': page.toString(),
              'ps': '20',
            },
          );

      final response = await http.get(uri, headers: BaseApi.getHeaders());

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json['code'] == 0 && json['data'] != null) {
          final archives = json['data']['archives'] as List? ?? [];
          return archives.map((item) => Video.fromRecommend(item)).toList();
        }
      }
    } catch (e) {
      // 忽略错误
    }
    return [];
  }

  /// 获取观看历史 (需要登录)
  /// 返回 { 'list': List<Video>, 'viewAt': int, 'max': int, 'hasMore': bool }
  static Future<Map<String, dynamic>> getHistory({
    int ps = 30,
    int viewAt = 0,
    int max = 0,
  }) async {
    if (!AuthService.isLoggedIn) {
      return {'list': <Video>[], 'hasMore': false};
    }

    try {
      final params = {'ps': ps.toString()};
      if (viewAt > 0) params['view_at'] = viewAt.toString();
      if (max > 0) params['max'] = max.toString();

      final uri = Uri.parse(
        '${BaseApi.apiBase}/x/web-interface/history/cursor',
      ).replace(queryParameters: params);

      final response = await http.get(
        uri,
        headers: BaseApi.getHeaders(
          withCookie: true,
          role: AccountRole.history,
        ),
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json['code'] == 0 && json['data'] != null) {
          final listData = json['data']['list'] as List? ?? [];
          final list = listData.map((item) => Video.fromHistory(item)).toList();

          final cursor = json['data']['cursor'];
          int nextViewAt = 0;
          int nextMax = 0;
          bool hasMore = false;

          if (cursor != null) {
            nextViewAt = cursor['view_at'] ?? 0;
            nextMax = cursor['max'] ?? 0;
            hasMore = list.isNotEmpty;
          }

          return {
            'list': list,
            'viewAt': nextViewAt,
            'max': nextMax,
            'hasMore': hasMore,
          };
        }
      }
    } catch (e) {
      // 忽略错误
    }
    return {'list': <Video>[], 'hasMore': false};
  }

  /// 获取搜索建议
  static Future<List<String>> getSearchSuggestions(String keyword) async {
    if (keyword.isEmpty) return [];

    try {
      final uri = Uri.parse('https://s.search.bilibili.com/main/suggest')
          .replace(
            queryParameters: {
              'term': keyword,
              'main_ver': 'v1',
              'highlight': '',
            },
          );

      final response = await http.get(uri, headers: BaseApi.getHeaders());

      if (response.statusCode == 200) {
        final json = jsonDecode(utf8.decode(response.bodyBytes));
        if (json['code'] == 0 && json['result'] != null) {
          final tags = json['result']['tag'] as List? ?? [];
          return tags
              .map((tag) => tag['value'] as String? ?? '')
              .where((v) => v.isNotEmpty)
              .toList();
        }
      }
    } catch (e) {
      // 忽略错误
    }
    return [];
  }

  /// 搜索视频 (需要 WBI 签名)
  static Future<List<Video>> searchVideos(
    String keyword, {
    int page = 1,
    String order = 'totalrank',
  }) async {
    if (keyword.isEmpty) return [];

    try {
      await BaseApi.ensureWbiKeys();

      Map<String, String> params = {
        'keyword': keyword,
        'search_type': 'video',
        'page': page.toString(),
        'pagesize': '20',
        'order': order,
      };

      if (BaseApi.imgKey != null && BaseApi.subKey != null) {
        params = SignUtils.signWithWbi(
          params,
          BaseApi.imgKey!,
          BaseApi.subKey!,
        );
      }

      final uri = Uri.parse(
        '${BaseApi.apiBase}/x/web-interface/wbi/search/type',
      ).replace(queryParameters: params);

      final response = await http.get(
        uri,
        headers: BaseApi.getHeaders(withCookie: true),
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json['code'] == 0 && json['data'] != null) {
          final result = json['data']['result'] as List? ?? [];
          return result.map((item) => Video.fromSearch(item)).toList();
        }
      }
    } catch (e) {
      // 忽略错误
    }
    return [];
  }

  /// 获取动态视频列表
  static Future<DynamicFeed> getDynamicFeed({String offset = ''}) async {
    try {
      // The polymer feed endpoint is cursor based and does not use WBI.
      // Calling nav first made a refresh depend on an unrelated WBI request.
      final uri = Uri.parse(
        '${BaseApi.apiBase}/x/polymer/web-dynamic/v1/feed/all',
      ).replace(
        queryParameters: {'type': 'all', 'offset': offset},
      );
      final response = await http.get(
        uri,
        headers: BaseApi.getHeaders(withCookie: true),
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json['code'] == 0 && json['data'] != null) {
          final data = json['data'];
          final items = data['items'] as List? ?? [];
          final newOffset = data['offset'] as String? ?? '';
          final hasMore = data['has_more'] as bool? ?? false;

          final videos = <Video>[];

          for (final item in items) {
            try {
              if (item['visible'] != true) continue;

              final modules = item['modules'] as Map<String, dynamic>? ?? {};
              final dynamicModule =
                  modules['module_dynamic'] as Map<String, dynamic>? ?? {};
              final major =
                  dynamicModule['major'] as Map<String, dynamic>? ?? {};

              if (major['type'] != 'MAJOR_TYPE_ARCHIVE') continue;

              final archive = major['archive'] as Map<String, dynamic>? ?? {};
              final author =
                  modules['module_author'] as Map<String, dynamic>? ?? {};
              final stat = archive['stat'] as Map<String, dynamic>? ?? {};

              final viewValue = stat['play'] ?? stat['view'] ?? 0;
              final danmakuValue = stat['danmaku'] ?? 0;

              videos.add(
                Video(
                  bvid: archive['bvid'] ?? '',
                  title: archive['title'] ?? '',
                  pic: BaseApi.fixPicUrl(archive['cover'] ?? ''),
                  ownerName: author['name'] ?? '',
                  ownerFace: BaseApi.fixPicUrl(author['face'] ?? ''),
                  ownerMid: author['mid'] ?? 0,
                  view: BaseApi.toInt(viewValue),
                  danmaku: BaseApi.toInt(danmakuValue),
                  duration: BaseApi.parseDuration(
                    archive['duration_text'] ?? '',
                  ),
                  pubdate: author['pub_ts'] ?? 0,
                  badge:
                      (archive['badge'] as Map<String, dynamic>?)?['text'] ??
                      '',
                ),
              );
            } catch (e) {
              continue;
            }
          }

          return DynamicFeed(
            videos: videos,
            offset: newOffset,
            hasMore: hasMore,
            succeeded: true,
          );
        }
        debugPrint(
          '[Dynamic] API code=${json['code']} message=${json['message']}',
        );
      } else {
        debugPrint('[Dynamic] HTTP ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[Dynamic] request failed: $e');
    }
    return DynamicFeed(
      videos: const [],
      offset: offset,
      hasMore: false,
      succeeded: false,
    );
  }

  /// 获取相关视频
  static Future<List<Video>> getRelatedVideos(String bvid) async {
    try {
      final uri = Uri.parse(
        '${BaseApi.apiBase}/x/web-interface/archive/related',
      ).replace(queryParameters: {'bvid': bvid});
      final response = await http.get(
        uri,
        headers: BaseApi.getHeaders(withCookie: true),
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json['code'] == 0 && json['data'] != null) {
          final list = json['data'] as List? ?? [];
          return list.map((item) => Video.fromRecommend(item)).toList();
        }
      }
    } catch (e) {
      // 忽略错误
    }
    return [];
  }

  /// 获取 UP主 投稿视频列表 (需要 WBI 签名)
  static Future<List<Video>> getSpaceVideos({
    required int mid,
    int page = 1,
    String order = 'pubdate',
  }) async {
    try {
      await BaseApi.ensureWbiKeys();

      Map<String, String> params = {
        'mid': mid.toString(),
        'pn': page.toString(),
        'ps': '30',
        'order': order,
      };

      if (BaseApi.imgKey != null && BaseApi.subKey != null) {
        params = SignUtils.signWithWbi(
          params,
          BaseApi.imgKey!,
          BaseApi.subKey!,
        );
      }

      final uri = Uri.parse(
        '${BaseApi.apiBase}/x/space/wbi/arc/search',
      ).replace(queryParameters: params);
      final response = await http.get(
        uri,
        headers: BaseApi.getHeaders(withCookie: true),
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json['code'] == 0 && json['data'] != null) {
          final list = json['data']['list']?['vlist'] as List? ?? [];
          return list.map((item) => Video.fromSpaceVideo(item)).toList();
        }
      }
    } catch (e) {
      // 忽略错误
    }
    return [];
  }
}

/// 动态 Feed 数据结构
class DynamicFeed {
  final List<Video> videos;
  final String offset;
  final bool hasMore;
  final bool succeeded;

  DynamicFeed({
    required this.videos,
    required this.offset,
    required this.hasMore,
    this.succeeded = true,
  });
}
