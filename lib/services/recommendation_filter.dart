import '../models/video.dart';

/// Shared recommendation policy. A zero threshold leaves the feed unchanged.
abstract final class RecommendationFilter {
  static List<Video> minimumDuration(
    Iterable<Video> videos,
    int minimumSeconds,
  ) {
    if (minimumSeconds <= 0) return videos.toList();
    return videos
        .where((video) => video.duration >= minimumSeconds)
        .toList(growable: false);
  }
}
