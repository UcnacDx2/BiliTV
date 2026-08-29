import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:bili_tv_app/services/first_frame_quality_service.dart';
import 'package:bili_tv_app/services/id_utils.dart';
import 'package:bili_tv_app/models/videoshot.dart';
import 'package:bili_tv_app/models/video.dart';
import 'package:bili_tv_app/services/recommendation_filter.dart';

void main() {
  group('mobile-patches pure logic', () {
    test('converts the canonical BV id to AV id', () {
      expect(BilibiliIdUtils.bv2av('BV17x411w7KC'), 170001);
    });

    test('rejects black frames and keeps informative frames', () {
      final black = Uint8List(32 * 18 * 4);
      expect(
        FirstFrameQualityAnalyzer.classify(
          FirstFrameQualityAnalyzer.metrics(black),
        ),
        FirstFrameQuality.mostlyBlack,
      );

      final informative = Uint8List(32 * 18 * 4);
      for (var i = 0; i < informative.length; i += 4) {
        final bright = (i ~/ 4) % 2 == 0;
        informative[i] = bright ? 220 : 20;
        informative[i + 1] = bright ? 180 : 20;
        informative[i + 2] = bright ? 120 : 20;
        informative[i + 3] = 255;
      }
      expect(
        FirstFrameQualityAnalyzer.classify(
          FirstFrameQualityAnalyzer.metrics(informative),
        ),
        FirstFrameQuality.usable,
      );
    });

    test('parses videoshot pvdata as monotonic big-endian timestamps', () {
      expect(
        VideoshotData.parsePvdata(Uint8List.fromList([0, 0, 0, 12, 0, 30])),
        [0, 12, 30],
      );
      expect(
        VideoshotData.parsePvdata(Uint8List.fromList([0, 20, 0, 10])),
        isEmpty,
      );
    });

    test('filters recommendations below the configured duration', () {
      final videos = [
        Video(bvid: 'short', title: 'short', pic: '', duration: 59),
        Video(bvid: 'long', title: 'long', pic: '', duration: 60),
      ];
      expect(
        RecommendationFilter.minimumDuration(videos, 60).map((v) => v.bvid),
        ['long'],
      );
      expect(RecommendationFilter.minimumDuration(videos, 0), videos);
    });
  });
}
