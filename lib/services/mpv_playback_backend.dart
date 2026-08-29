import 'package:media_kit/media_kit.dart';

/// Minimal playback source used by the libmpv research branch.
///
/// Bilibili DASH exposes video and audio as separate URLs. They must be
/// attached to one libmpv playback session so mpv owns A/V synchronization
/// and seek behavior.
class MpvPlaybackSource {
  const MpvPlaybackSource({
    required this.videoUrl,
    required this.headers,
    this.audioUrl,
    this.quality,
    this.codec,
  });

  final String videoUrl;
  final String? audioUrl;
  final Map<String, String> headers;
  final int? quality;
  final String? codec;
}

/// Narrow facade for the Phase 1 libmpv real-stream probe.
///
/// This intentionally does not know about Bilibili accounts, quality
/// selection, UI, or watermark detection. The existing PlaybackApi remains
/// responsible for resolving a playable source.
class MpvPlaybackBackend {
  MpvPlaybackBackend(this.player);

  final Player player;

  Stream<Duration> get position => player.stream.position;
  Stream<Duration> get duration => player.stream.duration;
  Stream<bool> get playing => player.stream.playing;
  Stream<bool> get buffering => player.stream.buffering;

  Future<void> open(MpvPlaybackSource source) async {
    // media_kit applies Media.httpHeaders to mpv's http-header-fields during
    // the media on_load hook. The external audio track is added afterwards,
    // so it inherits the same request headers in this playback session.
    await player.open(Media(source.videoUrl, httpHeaders: source.headers));

    final audioUrl = source.audioUrl;
    if (audioUrl != null && audioUrl.isNotEmpty) {
      await player.setAudioTrack(
        AudioTrack.uri(audioUrl, title: 'Bilibili DASH audio', language: 'und'),
      );
    }
  }

  Future<void> play() => player.play();
  Future<void> pause() => player.pause();
  Future<void> seek(Duration position) => player.seek(position);
}
