// Media player takeover — shared message types and state enums.
//
// Mirrors the JS Bridge protocol in media_player_design.md §4.2. The JS side
// speaks through the plugin's `$cef.MediaPlayer` channel; the Dart side
// dispatches via `executeJavaScriptInFrame` into the owning frame.

/// Media type of the taken-over element.
enum MediaMediaType {
  audio('audio'),
  video('video');

  const MediaMediaType(this.value);
  final String value;

  static MediaMediaType fromString(String? s) =>
      s == 'audio' ? MediaMediaType.audio : MediaMediaType.video;
}

/// Playback state machine of the native player
/// (`Idle → Loading → Playing → Paused → Ended / Error`, design §4.3).
enum MediaPlaybackPhase {
  idle,
  loading,
  playing,
  paused,
  ended,
  error,
}

/// Player UI form (design §4.3): video starts full-screen, the user can
/// switch to a draggable floating window; audio always uses the mini bar.
enum MediaPlayerDisplayMode {
  fullScreen,
  floating,
  miniBar,
}

/// Name of the `$cef` channel used by the media player takeover. No
/// registration needed — the V8 extension Proxy auto-creates channels.
const String kMediaPlayerChannelName = 'MediaPlayer';

/// Command names of the JS → Dart messages (design §4.2).
class MediaPlayerCommands {
  MediaPlayerCommands._();

  /// {mediaId, url, type, title, gesture} — user-initiated play request.
  static const String playRequest = 'mediaPlayRequest';

  /// {mediaId} — page script requested pause.
  static const String pauseRequest = 'mediaPauseRequest';

  /// {mediaId, position} — page custom control seek (currentTime setter
  /// proxy, Phase 3).
  static const String seekRequest = 'mediaSeekRequest';

  /// {mediaId, property, value} — page-side property change on a hijacked
  /// element (volume / muted / playbackRate, Phase 3).
  static const String propertyChange = 'mediaPropertyChange';

  /// {mediaId} — element removed from DOM or display:none.
  static const String elementRemoved = 'mediaElementRemoved';
}

/// Property names of the Phase 3 property-change message.
class MediaPlayerProperties {
  MediaPlayerProperties._();

  static const String volume = 'volume';
  static const String muted = 'muted';
  static const String playbackRate = 'playbackRate';
}

/// Command names of the Dart → JS messages (design §4.2).
class MediaPlayerWriteBacks {
  MediaPlayerWriteBacks._();

  /// {mediaId, paused, currentTime, duration, ended} — playback state
  /// write-back (throttled), executed in the element's owning frame.
  static const String stateUpdate = 'mediaStateUpdate';

  /// {mediaId, success, error} — play startup result.
  static const String playResult = 'mediaPlayResult';

  /// {mediaId} — player closed, element back to initial state.
  static const String closed = 'mediaClosed';
}

/// JS → Dart: user triggered playback on a hijacked media element.
class MediaPlayRequest {
  const MediaPlayRequest({
    required this.mediaId,
    required this.url,
    required this.type,
    required this.title,
    required this.gesture,
    required this.frameId,
  });

  /// Media element identity, assigned by the JS injection script.
  final String mediaId;

  /// Absolute media URL (resolved by the JS side); may be '' for
  /// unresolvable sources (blob/MSE).
  final String url;

  final MediaMediaType type;
  final String title;

  /// True when the play was user-gesture driven (always true in Phase 1 —
  /// gesture-less plays are silently dropped by the JS side).
  final bool gesture;

  /// Owning frame identifier, attached natively to the $cef channel message.
  final String frameId;
}

/// JS → Dart: page script requested pause.
class MediaPauseRequest {
  const MediaPauseRequest({required this.mediaId});
  final String mediaId;
}

/// JS → Dart: element removed from the DOM or hidden via display:none.
class MediaElementRemoved {
  const MediaElementRemoved({required this.mediaId});
  final String mediaId;
}

/// JS → Dart: page custom control seek (currentTime setter proxy, Phase 3).
class MediaSeekRequest {
  const MediaSeekRequest({required this.mediaId, required this.position});
  final String mediaId;

  /// Seconds.
  final double position;
}

/// JS → Dart: page-side property change (volume / muted / playbackRate,
/// Phase 3). [value] is a JSON-decoded num/bool.
class MediaPropertyChange {
  const MediaPropertyChange({
    required this.mediaId,
    required this.property,
    required this.value,
  });

  final String mediaId;
  final String property;
  final Object value;
}

/// Dart → JS: playback state write-back (design §4.2). Phase 1 covers the
/// B-level set (paused/currentTime/duration/ended); Phase 3 extends it with
/// volume/muted/playbackRate/readyState/networkState/buffered/seeking.
class MediaStateUpdate {
  const MediaStateUpdate({
    required this.mediaId,
    required this.paused,
    required this.currentTime,
    required this.duration,
    required this.ended,
    this.volume,
    this.muted,
    this.playbackRate,
    this.readyState,
    this.networkState,
    this.buffered,
    this.seeking,
    this.waiting,
  });

  final String mediaId;
  final bool paused;

  /// Seconds.
  final double currentTime;

  /// Seconds; NaN until known.
  final double duration;
  final bool ended;

  // ── Phase 3 extensions ─────────────────────────────────────────────────
  final double? volume;
  final bool? muted;
  final double? playbackRate;

  /// HTMLMediaElement.readyState (0–4).
  final int? readyState;

  /// HTMLMediaElement.networkState (0–3).
  final int? networkState;

  /// Buffered time ranges as [start, end] seconds pairs.
  final List<double>? buffered;

  /// True while a seek is in flight (page dispatches seeking/seeked).
  final bool? seeking;

  /// True while the player is buffering/stalled (page dispatches waiting).
  final bool? waiting;
}

/// Dart → JS: play startup result.
class MediaPlayResult {
  const MediaPlayResult({
    required this.mediaId,
    required this.success,
    this.error,
  });

  final String mediaId;
  final bool success;
  final String? error;
}
