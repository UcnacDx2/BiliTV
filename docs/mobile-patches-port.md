# PiliPlus mobile-patches → BiliTV

This fork tracks the behavior delta from the `mobile-patches` branch, rather
than treating BiliTV as a blank implementation target.

## Directly applicable feature delta

| Capability | BiliTV port status | Main implementation |
| --- | --- | --- |
| Replace card covers with usable video first frames | Implemented | `FirstFrameQualityService`, `FirstFrameOrCover` |
| Reject black, dark-flat, and low-information first frames | Implemented | `FirstFrameQualityAnalyzer` |
| Fall back to a videoshot middle frame | Implemented | `VideoShotPreviewService` |
| Prefer signed APP videoshot metadata | Implemented | `VideoshotApi._getAppVideoshot` |
| Recover videoshot indexes from `pvdata` | Implemented | `VideoshotData.parsePvdata` |
| Separate video-source and history accounts | Implemented | `AccountStore`, `PlaybackApi`, `BaseApi` |
| Account-aware local resume cache | Implemented | `PlaybackProgressCache` |
| Cross-account resume on another page of a multi-P video | Implemented | `PlayerActionMixin` |
| Add accounts and assign parser/history/heartbeat roles | Implemented | Settings → 添加账号 / 账号分工 |
| Filter recommendation videos below a minimum duration | Implemented | `RecommendationFilter`, Playback settings |

## Source-delta areas that need a different TV adaptation

The source branch also contains Flutter version bumps, desktop/iOS window
patches, mobile-only player gestures, text-selection behavior, reply/vote
controls, dynamic reactions, subtitle export, downloads, and CI changes. They
cannot be copied file-for-file into BiliTV because this project has a separate
TV navigation model, player surface, and plugin system. They are tracked as
adaptation work instead of being silently treated as completed.

## Verification

- `flutter analyze` passes after the account, cover, and videoshot changes.
- `flutter test` covers BV/AV conversion, frame-quality classification, and
  big-endian videoshot index parsing.
