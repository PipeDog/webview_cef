// Media player takeover — per-WebViewController native player controller.
//
// One instance per WebViewController (audio/video share it, mutually
// exclusive — design §4.3). Wraps the fvp (libmdk) backend, drives the
// Idle → Loading → Playing → Paused → Ended / Error state machine and
// synchronizes state back to the page's hijacked media element via
// executeJavaScriptInFrame (design §4.2).
//
// Phase 1 scope (B-level): paused / currentTime / duration / ended
// write-backs plus timeupdate / play / pause / ended / error / abort events.

import 'dart:async';

import 'package:fvp/mdk.dart' as mdk;
import 'package:flutter/foundation.dart';

import 'media_player_js_bridge.dart';
import 'media_player_types.dart';

/// Playback state poll interval — also the state write-back cadence
/// (timeupdate is further throttled to >= 250ms on the JS side).
const Duration _kStatePollInterval = Duration(milliseconds: 250);

/// Position-to-duration slack (ms) treated as playback end in the polling
/// fallback below, guarding against a missed MediaStatus.end event on some
/// short media.
const int _kEndFallbackToleranceMs = 150;

/// Consecutive polls (250ms each) without position movement that turn a
/// deferred fvp error event into a reported failure (~750ms of stall).
const int _kErrorStallTicks = 3;

class MediaPlayerController extends ChangeNotifier {
  /// [executeJavaScriptInFrame] runs JS in the frame owning the media
  /// element; supplied by the WebViewController (frameId invalidation after
  /// navigation is silently handled by the native side).
  MediaPlayerController({required this.executeJavaScriptInFrame});

  final void Function(String frameId, String code) executeJavaScriptInFrame;

  // ── observable state (read by the overlay UI) ───────────────────────────
  MediaPlaybackPhase get phase => _phase;
  MediaMediaType? get mediaType => _mediaType;
  String? get mediaId => _mediaId;
  String get title => _title;
  Duration get position => _position;
  Duration get duration => _duration;
  double get volume => _volume;
  double get playbackRate => _playbackRate;

  /// fvp texture for the video track; null for audio-only media.
  int? get textureId => _textureId;

  /// Video pixel size (may be null or 0 when the source exposes no stream
  /// metadata) — drives aspect-ratio-preserving scaling in the overlay.
  int? get videoWidth => _videoWidth;
  int? get videoHeight => _videoHeight;

  /// Current player UI form (full-screen / floating / mini bar).
  MediaPlayerDisplayMode get displayMode => _displayMode;

  /// Human-readable error text for the error panel (design decision 22);
  /// blob/MSE sources get a dedicated message (decision 11).
  String get errorMessage => _errorMessage;

  MediaPlaybackPhase _phase = MediaPlaybackPhase.idle;
  MediaMediaType? _mediaType;
  String? _mediaId;
  String? _frameId;
  String _mediaUrl = '';
  String _title = '';
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _volume = 1.0;
  double _playbackRate = 1.0;
  int? _textureId;
  MediaPlayerDisplayMode _displayMode = MediaPlayerDisplayMode.fullScreen;
  String _errorMessage = '无法播放该视频';
  bool _seeking = false;
  bool _waiting = false;

  mdk.Player? _player;
  Timer? _pollTimer;
  bool _hasVideo = false;
  int? _videoWidth;
  int? _videoHeight;
  bool _disposed = false;

  /// Deferred fvp error (see _listenToPlayer): reported only when polling
  /// confirms the playback actually stalled.
  String? _pendingError;
  int _stallTicks = 0;
  int _lastPollMs = 0;

  // ── JS bridge inputs ────────────────────────────────────────────────────

  /// User triggered playback on a hijacked element (mediaPlayRequest).
  void onPlayRequest(MediaPlayRequest request) {
    if (_disposed) return;
    debugPrint('[cef-media-player] playRequest: mediaId=${request.mediaId} '
        'url=${request.url} type=${request.type} gesture=${request.gesture} '
        'frame=${request.frameId}, phase=$_phase');
    if (request.mediaId == _mediaId && _player != null) {
      // Same element replayed (page custom control): resume or retry.
      switch (_phase) {
        case MediaPlaybackPhase.paused:
        case MediaPlaybackPhase.ended:
          debugPrint('[cef-media-player] playRequest: same element, resume '
              '(${_phase.name})');
          _resume();
          return;
        case MediaPlaybackPhase.error:
          debugPrint('[cef-media-player] playRequest: same element, retry '
              '(was error: $_errorMessage)');
          _startLoading(request);
          return;
        default:
          return; // Already loading / playing.
      }
    }
    // New element: stop the previous playback (mutual exclusion).
    if (_mediaId != null) {
      debugPrint('[cef-media-player] playRequest: new element, stopping '
          'previous mediaId=$_mediaId');
    }
    _teardownPlayback();
    _startLoading(request);
  }

  /// Page script requested pause (mediaPauseRequest).
  void onPauseRequest(MediaPauseRequest request) {
    if (_disposed) {
      debugPrint('[cef-media-player] pauseRequest dropped (disposed): '
          'mediaId=${request.mediaId}');
      return;
    }
    if (request.mediaId != _mediaId) {
      debugPrint('[cef-media-player] pauseRequest ignored (mediaId mismatch): '
          'got=${request.mediaId} current=$_mediaId');
      return;
    }
    debugPrint('[cef-media-player] pauseRequest: mediaId=${request.mediaId}');
    _pause();
  }

  /// Hijacked element was removed from the DOM or hidden (mediaElementRemoved,
  /// decision 21) → close the player.
  void onElementRemoved(MediaElementRemoved request) {
    if (_disposed || request.mediaId != _mediaId) return;
    debugPrint('[cef-media-player] elementRemoved: closing player, '
        'mediaId=${request.mediaId}');
    close();
  }

  /// Page custom control seek (currentTime setter proxy, Phase 3).
  void onSeekRequest(MediaSeekRequest request) {
    if (_disposed || request.mediaId != _mediaId) return;
    final player = _player;
    if (player == null || _phase == MediaPlaybackPhase.error) {
      debugPrint('[cef-media-player] seekRequest ignored: mediaId='
          '${request.mediaId} target=${request.position}s '
          '(phase=$_phase, player=${player != null})');
      return;
    }
    final targetMs = (request.position * 1000).round();
    debugPrint('[cef-media-player] seekRequest: mediaId=${request.mediaId} '
        'target=${request.position}s -> ${targetMs}ms');
    _position = Duration(milliseconds: targetMs);
    _seeking = true;
    _writeBackState();
    notifyListeners();
    player.seek(position: targetMs).then((_) {
      if (_disposed || request.mediaId != _mediaId) return;
      debugPrint('[cef-media-player] seek completed: ${targetMs}ms');
      _seeking = false;
      _writeBackState();
      notifyListeners();
    });
  }

  /// Page-side property change (volume / muted / playbackRate, Phase 3).
  void onPropertyChange(MediaPropertyChange request) {
    if (_disposed || request.mediaId != _mediaId) return;
    debugPrint('[cef-media-player] propertyChange: mediaId=${request.mediaId} '
        'property=${request.property} value=${request.value}');
    switch (request.property) {
      case MediaPlayerProperties.volume:
        final v = (request.value as num).toDouble();
        _volume = v.clamp(0.0, 1.0);
        _player?.volume = _volume;
        break;
      case MediaPlayerProperties.muted:
        _player?.mute = request.value as bool;
        break;
      case MediaPlayerProperties.playbackRate:
        final r = (request.value as num).toDouble();
        if (r > 0) {
          _playbackRate = r;
          _player?.playbackRate = r;
        }
        break;
    }
    notifyListeners();
  }

  // ── UI controls ─────────────────────────────────────────────────────────

  /// Play/pause toggle; replays from the start when ended; retries the same
  /// URL when in error state (decision 22).
  void togglePlayPause() {
    switch (_phase) {
      case MediaPlaybackPhase.playing:
        _pause();
        break;
      case MediaPlaybackPhase.paused:
        _resume();
        break;
      case MediaPlaybackPhase.ended:
        _replay();
        break;
      case MediaPlaybackPhase.error:
        _startLoading(MediaPlayRequest(
          mediaId: _mediaId!,
          url: _mediaUrl,
          type: _mediaType ?? MediaMediaType.video,
          title: _title,
          gesture: true,
          frameId: _frameId ?? '',
        ));
        break;
      case MediaPlaybackPhase.loading:
      case MediaPlaybackPhase.idle:
        break;
    }
  }

  Future<void> seek(Duration target) async {
    final player = _player;
    if (player == null || _phase == MediaPlaybackPhase.error) {
      debugPrint('[cef-media-player] seek ignored (phase=$_phase, '
          'player=${player != null}): target=${target.inMilliseconds}ms');
      return;
    }
    debugPrint('[cef-media-player] seek: ${target.inMilliseconds}ms');
    _position = target;
    _seeking = true;
    _writeBackState();
    notifyListeners();
    await player.seek(position: target.inMilliseconds);
    if (_disposed) return;
    _seeking = false;
    _writeBackState();
  }

  void setVolume(double value) {
    _volume = value.clamp(0.0, 1.0);
    _player?.volume = _volume;
    debugPrint('[cef-media-player] setVolume: ${_volume.toStringAsFixed(2)}');
    notifyListeners();
  }

  void setPlaybackRate(double value) {
    _playbackRate = value;
    _player?.playbackRate = _playbackRate;
    debugPrint('[cef-media-player] setPlaybackRate: ${value}x');
    notifyListeners();
  }

  /// Switches the player UI form (full-screen ⇄ floating for video).
  void setDisplayMode(MediaPlayerDisplayMode mode) {
    if (_displayMode == mode) return;
    debugPrint('[cef-media-player] displayMode: $_displayMode -> $mode');
    _displayMode = mode;
    notifyListeners();
  }

  /// Closes the player (user close / cross-document navigation / element
  /// removal). Notifies the page with mediaClosed so the element returns to
  /// its initial state and any pending play() rejects with AbortError.
  void close() {
    if (_disposed || _phase == MediaPlaybackPhase.idle) {
      debugPrint('[cef-media-player] close ignored (disposed=$_disposed '
          'phase=$_phase)');
      return;
    }
    debugPrint('[cef-media-player] close player: mediaId=$_mediaId '
        'phase=$_phase');
    _writeBackClosed();
    _teardownPlayback();
    notifyListeners();
  }

  // ── lifecycle ───────────────────────────────────────────────────────────

  /// Cross-document navigation (page load / refresh / jump, decision 13):
  /// close immediately. The old frame is gone, so the mediaClosed write-back
  /// is silently dropped by executeJavaScriptInFrame (frameId invalidation).
  void onPageNavigation() {
    if (_disposed || _phase == MediaPlaybackPhase.idle) {
      debugPrint('[cef-media-player] pageNavigation: player already idle '
          '(disposed=$_disposed phase=$_phase)');
      return;
    }
    debugPrint('[cef-media-player] pageNavigation: closing player '
            '(mediaId=$_mediaId)');
    close();
  }

  @override
  void dispose() {
    debugPrint('[cef-media-player] dispose controller');
    _disposed = true;
    _teardownPlayback();
    final player = _player;
    _player = null;
    player?.dispose();
    super.dispose();
  }

  // ── internals ───────────────────────────────────────────────────────────

  void _startLoading(MediaPlayRequest request) {
    _mediaId = request.mediaId;
    _frameId = request.frameId;
    _mediaUrl = request.url;
    _mediaType = request.type;
    _title = request.title;
    _position = Duration.zero;
    _duration = Duration.zero;
    _errorMessage = '无法播放该视频';
    _pendingError = null;
    _stallTicks = 0;
    _lastPollMs = 0;
    // UI form: audio → mini bar, video → full-screen (design §4.3).
    _displayMode = request.type == MediaMediaType.audio
        ? MediaPlayerDisplayMode.miniBar
        : MediaPlayerDisplayMode.fullScreen;
    _phase = MediaPlaybackPhase.loading;
    debugPrint('[cef-media-player] startLoading: mediaId=$_mediaId '
        'type=$_mediaType url=$_mediaUrl');
    notifyListeners();
    _loadMedia();
  }

  Future<void> _loadMedia() async {
    final player = _ensurePlayer();
    _stopPolling();
    try {
      if (_mediaUrl.isEmpty) {
        debugPrint('[cef-media-player] load failed: empty url (blob/MSE or '
            'unresolvable source)');
        _onError('Unable to play this media source.');
        return;
      }
      if (_mediaUrl.startsWith('blob:')) {
        // blob/MSE sources are not supported in v1 (decision 11): dedicated
        // message instead of the unified error text.
        debugPrint('[cef-media-player] load failed: blob/MSE source '
            'unsupported, url=$_mediaUrl');
        _errorMessage = '该视频格式不支持';
        _onError('blob/MSE media source is not supported.');
        return;
      }
      debugPrint('[cef-media-player] open: $_mediaUrl');
      player.media = _mediaUrl;
      final ret = await player.prepare();
      debugPrint('[cef-media-player] prepare() returned: $ret');
      if (ret < 0) {
        _onError('Media open failed. (prepare ret=$ret)');
        return;
      }
      final info = player.mediaInfo;
      _hasVideo = (info.video?.isNotEmpty ?? false);
      _duration = Duration(milliseconds: info.duration);
      // Video pixel size (first video stream's codec parameters) — the
      // overlay uses it to keep the aspect ratio when the window is resized.
      _videoWidth = _hasVideo ? info.video!.first.codec.width : null;
      _videoHeight = _hasVideo ? info.video!.first.codec.height : null;
      debugPrint('[cef-media-player] mediaInfo: duration=${info.duration}ms '
          'hasVideo=$_hasVideo video=${info.video?.length ?? 0} '
          'audio=${info.audio?.length ?? 0} '
          'videoSize=${_hasVideo ? "$_videoWidth x $_videoHeight" : "n/a"}');
      final tex = await player.updateTexture();
      debugPrint('[cef-media-player] updateTexture() returned: $tex');
      if (tex < 0) {
        _onError('Invalid video size. (texture=$tex)');
        return;
      }
      _textureId = _hasVideo ? tex : null;
      // Audio-only still owns the dummy texture; release it so no Texture
      // widget is needed and the next video load creates a fresh one.
      if (!_hasVideo && tex >= 0) {
        await player.updateTexture(width: -1);
      }
      player.state = mdk.PlaybackState.playing;
      _phase = MediaPlaybackPhase.playing;
      debugPrint('[cef-media-player] playback started: mediaId=$_mediaId '
          'hasVideo=$_hasVideo textureId=$_textureId');
      _writeBackPlayResult(true);
      _writeBackState();
      _startPolling();
      notifyListeners();
    } catch (e, s) {
      debugPrint('[cef-media-player] load threw: $e\n$s');
      _onError('Media open failed: $e');
    }
  }

  void _onError(String message) {
    _stopPolling();
    _pendingError = null;
    _stallTicks = 0;
    _phase = MediaPlaybackPhase.error;
    debugPrint('[cef-media-player] ERROR: $message '
        '(mediaId=$_mediaId url=$_mediaUrl type=$_mediaType)');
    _writeBackPlayResult(false, message);
    _writeBackState();
    notifyListeners();
  }

  void _resume() {
    final player = _player;
    if (player == null) {
      debugPrint('[cef-media-player] resume failed: player is null');
      return;
    }
    debugPrint('[cef-media-player] resume');
    player.state = mdk.PlaybackState.playing;
    _phase = MediaPlaybackPhase.playing;
    _writeBackState();
    _startPolling();
    notifyListeners();
  }

  void _pause() {
    _stopPolling();
    final player = _player;
    if (player != null && _phase != MediaPlaybackPhase.error) {
      player.state = mdk.PlaybackState.paused;
    }
    _phase = MediaPlaybackPhase.paused;
    debugPrint('[cef-media-player] pause');
    _writeBackState();
    notifyListeners();
  }

  void _replay() {
    final player = _player;
    if (player == null) {
      debugPrint('[cef-media-player] replay failed: player is null');
      return;
    }
    debugPrint('[cef-media-player] replay from start');
    player.seek(position: 0);
    player.state = mdk.PlaybackState.playing;
    _phase = MediaPlaybackPhase.playing;
    _position = Duration.zero;
    _writeBackState();
    _startPolling();
    notifyListeners();
  }

  mdk.Player _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    debugPrint('[cef-media-player] creating mdk.Player instance');
    final player = mdk.Player();
    _player = player;
    _listenToPlayer(player);
    return player;
  }

  void _listenToPlayer(mdk.Player player) {
    player.onMediaStatus.listen((event) {
      if (_disposed || player != _player) return;
      if (event.newValue.test(mdk.MediaStatus.end)) {
        debugPrint('[cef-media-player] fvp event: MediaStatus.end');
        _onEnded();
      } else if (event.newValue.test(mdk.MediaStatus.invalid)) {
        debugPrint('[cef-media-player] fvp event: MediaStatus.invalid');
        _onError('Media became invalid.');
      } else if (event.newValue.test(mdk.MediaStatus.buffering) ||
          event.newValue.test(mdk.MediaStatus.stalled)) {
        debugPrint('[cef-media-player] fvp event: '
            'MediaStatus.${event.newValue.test(mdk.MediaStatus.buffering) ? 'buffering' : 'stalled'}');
        // Buffering started → page dispatches `waiting` (Phase 3).
        if (!_waiting) {
          _waiting = true;
          _writeBackState();
          notifyListeners();
        }
      } else if (_waiting &&
          (event.newValue.test(mdk.MediaStatus.loaded) ||
              event.newValue.test(mdk.MediaStatus.buffered))) {
        // Buffering finished → page dispatches `playing`.
        debugPrint('[cef-media-player] fvp event: '
            'MediaStatus.${event.newValue.test(mdk.MediaStatus.loaded) ? 'loaded' : 'buffered'} '
            '(buffering done)');
        _waiting = false;
        _writeBackState();
        notifyListeners();
      } else {
        // Log other media-status flags (seek, paused, stopped, EOF...) at a
        // low rate — the stream only fires on status changes.
        debugPrint('[cef-media-player] fvp event: MediaStatus='
            '${event.newValue} (old=${event.oldValue})');
      }
    });
    player.onEvent.listen((event) {
      if (_disposed || player != _player) return;
      // error field is a 0-100 progress value for reader.buffering — ignore
      // that category. Other nonzero errors are deferred to the polling tick
      // instead of failing immediately: many are transient (dropped frame,
      // audio hiccup) while playback continues, and only a stall is reported
      // as a real failure.
      if (event.error != 0 && event.category != 'reader.buffering') {
        debugPrint('[cef-media-player] fvp error event (deferred): '
            'category=${event.category} error=${event.error} '
            'detail="${event.detail}"');
        _pendingError = event.detail.isEmpty ? event.category : event.detail;
      }
    });
  }

  void _onEnded() {
    if (_phase == MediaPlaybackPhase.ended) return;
    _stopPolling();
    _phase = MediaPlaybackPhase.ended;
    // Snap the position to the real duration: the last polled value may be a
    // frame before the end (e.g. a 1.9s clip polled at 1.8s), leaving the
    // progress bar short of 100%.
    if (_duration.inMilliseconds > 0) {
      _position = _duration;
    }
    debugPrint('[cef-media-player] playback ended: mediaId=$_mediaId '
        'type=$_mediaType');
    _writeBackState();
    if (_mediaType == MediaMediaType.audio) {
      // Audio mini bar auto-collapses after playback (design §4.3): the
      // ended state was written back first so the page dispatched `ended`;
      // close() then resets the element and hides the UI.
      close();
      return;
    }
    notifyListeners();
  }

  void _teardownPlayback() {
    _stopPolling();
    debugPrint('[cef-media-player] teardownPlayback: stopping player '
        '(mediaId=$_mediaId phase=$_phase)');
    _player?.state = mdk.PlaybackState.stopped;
    _phase = MediaPlaybackPhase.idle;
    _mediaId = null;
    _frameId = null;
    _mediaUrl = '';
    _title = '';
    _position = Duration.zero;
    _duration = Duration.zero;
    _textureId = null;
    _videoWidth = null;
    _videoHeight = null;
    _seeking = false;
    _waiting = false;
    _pendingError = null;
    _stallTicks = 0;
    _lastPollMs = 0;
  }

  void _startPolling() {
    _stopPolling();
    _pollTimer = Timer.periodic(_kStatePollInterval, (_) {
      final player = _player;
      if (player == null) return;
      final ms = player.position;
      // Deferred error confirmation: the playback is alive while the
      // position moves, so transient mdk errors are dropped; a stall over
      // several consecutive polls is reported as a real failure.
      if (_pendingError != null && _phase == MediaPlaybackPhase.playing) {
        if (ms != _lastPollMs) {
          _pendingError = null; // still advancing — transient, drop it
        } else if (++_stallTicks >= _kErrorStallTicks) {
          final err = _pendingError!;
          _pendingError = null;
          _stallTicks = 0;
          _onError(err);
          return;
        }
      }
      _lastPollMs = ms;
      // Fallback end detection: fvp may not emit MediaStatus.end for some
      // short media — a position reaching the duration is treated as ended
      // so the UI (replay button, 100% progress) settles correctly.
      if (_phase == MediaPlaybackPhase.playing &&
          _duration.inMilliseconds > 0 &&
          ms >= _duration.inMilliseconds - _kEndFallbackToleranceMs) {
        _onEnded();
        return;
      }
      final next = Duration(milliseconds: ms < 0 ? 0 : ms);
      if (next != _position) {
        _position = next;
        notifyListeners();
      }
      _writeBackState();
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  // ── write-backs (design §4.2) ──────────────────────────────────────────

  void _writeBackState() {
    final frameId = _frameId;
    final mediaId = _mediaId;
    if (frameId == null || mediaId == null) return;
    // Phase 3: buffered ranges from the native player (single range from 0);
    // readyState/networkState derived from the state machine.
    final buffered = <double>[];
    if (_phase == MediaPlaybackPhase.playing || _phase == MediaPlaybackPhase.paused) {
      final bufMs = _player?.buffered() ?? 0;
      if (bufMs > 0) {
        buffered.addAll([0, bufMs / 1000.0]);
      }
    }
    executeJavaScriptInFrame(
        frameId,
        mediaPlayerStateUpdateCode(MediaStateUpdate(
          mediaId: mediaId,
          paused: _phase != MediaPlaybackPhase.playing,
          currentTime: _position.inMilliseconds / 1000.0,
          duration: _duration.inMilliseconds / 1000.0,
          ended: _phase == MediaPlaybackPhase.ended,
          volume: _volume,
          muted: _player?.mute ?? false,
          playbackRate: _playbackRate,
          readyState: _deriveReadyState(),
          networkState: _deriveNetworkState(),
          buffered: buffered.isEmpty ? null : buffered,
          seeking: _seeking,
          waiting: _waiting,
        )));
  }

  /// HTMLMediaElement.readyState (0–4) derived from the playback phase.
  int _deriveReadyState() {
    switch (_phase) {
      case MediaPlaybackPhase.loading:
      case MediaPlaybackPhase.error:
      case MediaPlaybackPhase.idle:
        return 0; // HAVE_NOTHING
      case MediaPlaybackPhase.playing:
      case MediaPlaybackPhase.paused:
      case MediaPlaybackPhase.ended:
        return _waiting ? 2 : 4; // HAVE_CURRENT_DATA / HAVE_ENOUGH_DATA
    }
  }

  /// HTMLMediaElement.networkState (0–3) derived from the playback phase.
  int _deriveNetworkState() {
    switch (_phase) {
      case MediaPlaybackPhase.loading:
        return 2; // NETWORK_LOADING
      case MediaPlaybackPhase.error:
        return 3; // NETWORK_NO_SOURCE
      case MediaPlaybackPhase.idle:
        return 0; // NETWORK_EMPTY
      case MediaPlaybackPhase.playing:
      case MediaPlaybackPhase.paused:
      case MediaPlaybackPhase.ended:
        return _waiting ? 2 : 1; // NETWORK_LOADING / NETWORK_IDLE
    }
  }

  void _writeBackPlayResult(bool success, [String? error]) {
    final frameId = _frameId;
    final mediaId = _mediaId;
    if (frameId == null || mediaId == null) return;
    debugPrint('[cef-media-player] writeBack playResult: success=$success '
        '${error != null ? 'error="$error"' : ''}');
    executeJavaScriptInFrame(
        frameId,
        mediaPlayerPlayResultCode(
            MediaPlayResult(mediaId: mediaId, success: success, error: error)));
  }

  void _writeBackClosed() {
    final frameId = _frameId;
    final mediaId = _mediaId;
    if (frameId == null || mediaId == null) return;
    debugPrint('[cef-media-player] writeBack closed: mediaId=$mediaId');
    executeJavaScriptInFrame(frameId, mediaPlayerClosedCode(mediaId));
  }
}
