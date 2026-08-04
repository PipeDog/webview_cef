// Media player takeover — JS Bridge encoding/decoding.
//
// JS → Dart messages arrive through the plugin's existing `$cef` channel
// machinery (`javascriptChannelMessage` in WebviewManager). The MediaPlayer
// channel needs no registration: the V8 extension Proxy auto-creates it for
// any name (setJavaScriptChannels is a no-op).
//
// Dart → JS write-backs are plain JS snippets executed in the element's
// owning frame via executeJavaScriptInFrame (frameId is attached natively to
// the incoming messages). The JSON payload is embedded as a JS object
// literal — JSON is a valid JS expression, so no quote-escaping is needed.
//
// See media_player_design.md §4.2 for the protocol.

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'media_player_types.dart';

/// Coerces a decoded JSON mediaId to String. The JS side now always sends a
/// string (design §4.2), but tolerating legacy numeric ids keeps the bridge
/// from silently dropping a message on a type mismatch.
String _asString(Object? v) =>
    v is String ? v : v is num ? v.toString() : '';

/// Result of decoding an incoming JS channel message.
class MediaPlayerMessage {
  const MediaPlayerMessage._(this.command, this.request);

  final String command;

  /// Strongly-typed payload; null for unrecognized commands.
  final Object? request;
}

/// Decodes the JSON payload of an incoming `$cef.MediaPlayer` message.
///
/// Returns null when the payload is malformed or the command is unknown.
MediaPlayerMessage? mediaPlayerDecodeMessage(String message, String frameId) {
  try {
    final decoded = jsonDecode(message);
    if (decoded is! Map<String, dynamic>) return null;
    final cmd = decoded['cmd'] as String?;
    if (cmd == null) return null;

    switch (cmd) {
      case MediaPlayerCommands.playRequest:
        final request = MediaPlayRequest(
          mediaId: _asString(decoded['mediaId']),
          url: decoded['url'] as String? ?? '',
          type: MediaMediaType.fromString(decoded['type'] as String?),
          title: decoded['title'] as String? ?? '',
          gesture: decoded['gesture'] as bool? ?? false,
          frameId: frameId,
        );
        return MediaPlayerMessage._(cmd, request);
      case MediaPlayerCommands.pauseRequest:
        return MediaPlayerMessage._(
            cmd, MediaPauseRequest(mediaId: _asString(decoded['mediaId'])));
      case MediaPlayerCommands.seekRequest:
        return MediaPlayerMessage._(
            cmd,
            MediaSeekRequest(
              mediaId: _asString(decoded['mediaId']),
              position: (decoded['position'] as num).toDouble(),
            ));
      case MediaPlayerCommands.propertyChange:
        return MediaPlayerMessage._(
            cmd,
            MediaPropertyChange(
              mediaId: _asString(decoded['mediaId']),
              property: decoded['property'] as String,
              value: decoded['value']!,
            ));
      case MediaPlayerCommands.elementRemoved:
        return MediaPlayerMessage._(
            cmd, MediaElementRemoved(mediaId: _asString(decoded['mediaId'])));
      default:
        return null;
    }
  } catch (e) {
    // Never fail silently: log the raw payload so a protocol mismatch (e.g.
    // a field type change) is visible in the Flutter console instead of
    // manifesting as "player never appears".
    debugPrint('[cef-media-player] decode failed, frame=$frameId '
        'message=$message: $e');
    return null;
  }
}

/// Builds the JS snippet that dispatches a state write-back in the owning
/// frame. Executed via executeJavaScriptInFrame.
String mediaPlayerStateUpdateCode(MediaStateUpdate update) {
  return 'window.__cefMediaPlayerDispatch && '
      'window.__cefMediaPlayerDispatch("state",'
      '${jsonEncode(_stateUpdateJson(update))})';
}

/// Builds the JS snippet for a play-result write-back.
String mediaPlayerPlayResultCode(MediaPlayResult result) {
  return 'window.__cefMediaPlayerDispatch && '
      'window.__cefMediaPlayerDispatch("playResult",'
      '${jsonEncode({
        'mediaId': result.mediaId,
        'success': result.success,
        if (result.error != null) 'error': result.error,
      })} )';
}

/// Builds the JS snippet that resets the element when the player closes.
String mediaPlayerClosedCode(String mediaId) {
  return 'window.__cefMediaPlayerDispatch && '
      'window.__cefMediaPlayerDispatch("closed",'
      '${jsonEncode({'mediaId': mediaId})})';
}

Map<String, dynamic> _stateUpdateJson(MediaStateUpdate update) {
  // duration is omitted while unknown (<= 0, e.g. live streams) — NaN cannot
  // be JSON-encoded and the JS side keeps its initial NaN in that case.
  return {
    'mediaId': update.mediaId,
    'paused': update.paused,
    'currentTime': update.currentTime,
    if (update.duration > 0) 'duration': update.duration,
    'ended': update.ended,
    // Phase 3 extensions (omitted = JS side keeps the current value).
    if (update.volume != null) 'volume': update.volume,
    if (update.muted != null) 'muted': update.muted,
    if (update.playbackRate != null) 'playbackRate': update.playbackRate,
    if (update.readyState != null) 'readyState': update.readyState,
    if (update.networkState != null) 'networkState': update.networkState,
    if (update.buffered != null) 'buffered': update.buffered,
    if (update.seeking != null) 'seeking': update.seeking,
    if (update.waiting != null) 'waiting': update.waiting,
  };
}
