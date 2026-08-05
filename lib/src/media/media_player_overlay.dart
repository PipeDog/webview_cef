// Media player takeover — overlay UI layered on the WebView's Stack.
//
// Three player forms (design §4.3), switched by MediaPlayerController:
// - full-screen player (video default): covers the webview, full controls,
//   can switch to the floating window;
// - floating window (video, toggled from full-screen): draggable, several
//   size presets, playback continues while the page is usable;
// - audio mini bar (audio default): draggable compact bar with play/pause,
//   progress, volume, speed, close; auto-collapses when playback ends.
//
// Loading indicator, unified error panel with retry (decision 22, including
// the blob/MSE "该视频格式不支持" message, decision 11) and the ended state
// with a replay button (decision 15) are shared across forms.

import 'package:flutter/material.dart';

import 'media_player_controller.dart';
import 'media_player_types.dart';

/// Target-value jump (ms) treated as a snap: replay (100% → 0%), the end snap
/// (last poll → duration) or a far seek must not animate the bar across the
/// track. The 250ms poll advances at most ~500ms per tick at 2x speed, so
/// anything beyond 1s is a real jump.
const double _kSnapJumpMs = 1000;

/// Overlay widget; place inside the WebView's Stack. Renders nothing while
/// the player is idle.
class MediaPlayerOverlay extends StatelessWidget {
  const MediaPlayerOverlay({super.key, required this.controller});

  final MediaPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.phase == MediaPlaybackPhase.idle) {
          return const SizedBox.shrink();
        }
        return Positioned.fill(
          child: switch (controller.displayMode) {
            MediaPlayerDisplayMode.fullScreen =>
              _FullScreenPlayer(controller: controller),
            MediaPlayerDisplayMode.floating =>
              _FloatingPlayer(controller: controller),
            MediaPlayerDisplayMode.miniBar =>
              _AudioMiniBar(controller: controller),
          },
        );
      },
    );
  }
}

/// Draggable position + size state shared by the floating window and the
/// mini bar.
class _DraggableBox extends StatefulWidget {
  const _DraggableBox({
    required this.controller,
    required this.size,
    required this.child,
    this.snapSignal = 0,
  });

  final MediaPlayerController controller;
  final Size size;
  final Widget child;

  /// Bumped by the owner (e.g. after a floating-window resize) to request a
  /// re-snap to the nearest horizontal edge on the next layout.
  final int snapSignal;

  @override
  State<_DraggableBox> createState() => _DraggableBoxState();
}

class _DraggableBoxState extends State<_DraggableBox> {
  /// Current position; null until the first layout places the box in the
  /// bottom-right corner of the stage.
  Offset? _pos;

  /// Which horizontal edge the box is currently anchored to. On a parent-
  /// window resize the box follows this edge — right-anchored tracks the
  /// right edge, left-anchored stays put. Defaults to right to match the
  /// bottom-right initial position.
  bool _snappedToRight = true;

  /// Set by didUpdateWidget when the owner bumps [snapSignal] (a resize):
  /// the next layout re-evaluates the anchor and re-snaps the box to the
  /// horizontal edge it is closer to.
  bool _pendingSnap = false;

  /// True while the user is dragging: the box tracks the pointer without
  /// animation, then snaps to the nearest horizontal edge on release.
  bool _dragging = false;

  /// Last layout's stage width; used to detect a parent-window resize this
  /// frame so the box can follow its anchor edge instantly instead of
  /// animating (which would lag behind a continuous window drag).
  double? _lastStageWidth;

  @override
  void didUpdateWidget(_DraggableBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.snapSignal != oldWidget.snapSignal) {
      _pendingSnap = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxDx = constraints.maxWidth - widget.size.width;
        final maxDy = constraints.maxHeight - widget.size.height;
        // Keep a uniform 10px margin from the stage edges on all four
        // sides; when the parent is too small to honor it, visibility wins.
        const double edgeMargin = 10;
        final minX = edgeMargin;
        final maxX = maxDx - edgeMargin;
        final minY = edgeMargin;
        final maxY = maxDy - edgeMargin;
        final rightX = maxX < minX ? minX : maxX;
        final bottomY = maxY < minY ? minY : maxY;
        final raw = _pos ?? Offset(rightX, bottomY);
        // A parent-window resize (stage width changed this frame) makes the
        // box follow its currently-anchored edge instantly — right-anchored
        // tracks rightX, left-anchored stays at minX. A pending snap (resize
        // button / title double-tap) re-evaluates the anchor from the
        // current X and animates to the nearest edge. Otherwise just clamp
        // the drag position to the margins. Dragging always clamps (never
        // re-anchors) so the pointer stays in control mid-drag.
        final parentResizing = _lastStageWidth != null &&
            constraints.maxWidth != _lastStageWidth;
        if (_pendingSnap) {
          _snappedToRight = raw.dx - minX > rightX - raw.dx;
          _pos = Offset(
              _snappedToRight ? rightX : minX, raw.dy.clamp(minY, bottomY));
        } else if (parentResizing && !_dragging) {
          _pos = Offset(
              _snappedToRight ? rightX : minX, raw.dy.clamp(minY, bottomY));
        } else {
          _pos = Offset(
              raw.dx.clamp(minX, rightX), raw.dy.clamp(minY, bottomY));
        }
        _pendingSnap = false;
        _lastStageWidth = constraints.maxWidth;
        // AnimatedPositioned must be a direct child of a Stack (a
        // LayoutBuilder accepts BoxParentData and would reject it). The
        // Stack spans the full webview area as the stage; the box floats on
        // top of it.
        return Stack(
          children: [
            AnimatedPositioned(
              left: _pos!.dx,
              top: _pos!.dy,
              width: widget.size.width,
              height: widget.size.height,
              // Animate discrete snaps (drag release / resize button); stay
              // instant while dragging or while the parent window is being
              // resized so the box tracks the edge in real time instead of
              // lagging behind a continuous resize.
              duration: (_dragging || parentResizing)
                  ? Duration.zero
                  : const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              child: GestureDetector(
                onPanStart: (_) => setState(() => _dragging = true),
                onPanUpdate: (details) {
                  setState(() {
                    _pos = _pos! + details.delta;
                  });
                },
                onPanEnd: (_) {
                  // Snap horizontally to the nearest edge on release and
                  // record which edge that is, so a later parent-window
                  // resize knows which edge to follow. The vertical
                  // position stays where it was dropped.
                  setState(() {
                    _dragging = false;
                    final pos = _pos!;
                    _snappedToRight = pos.dx - minX > rightX - pos.dx;
                    _pos = Offset(
                      _snappedToRight ? rightX : minX,
                      pos.dy,
                    );
                  });
                },
                child: widget.child,
              ),
            ),
          ],
        );
      },
    );
  }
}

// ── full-screen player ───────────────────────────────────────────────────

class _FullScreenPlayer extends StatefulWidget {
  const _FullScreenPlayer({required this.controller});

  final MediaPlayerController controller;

  @override
  State<_FullScreenPlayer> createState() => _FullScreenPlayerState();
}

class _FullScreenPlayerState extends State<_FullScreenPlayer> {
  /// Progress bar drag preview (null = not dragging).
  double? _dragValue;

  /// Whether the top bar / control bar are shown; toggled by tapping the
  /// video surface. Hiding keeps the layout space so the video size is
  /// unchanged.
  bool _controlsVisible = true;

  /// Last slider target (ms) rendered; null before the first build. Used to
  /// snap the bar instantly on large jumps instead of animating across the
  /// track (see _kSnapJumpMs).
  double? _lastSliderTargetMs;

  static const List<double> _speeds = [0.5, 1.0, 1.5, 2.0];

  MediaPlayerController get controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    final phase = controller.phase;
    final isAudio = controller.mediaType == MediaMediaType.audio;
    // The video surface spans the full WebView height; the top/control bars
    // overlay it (semi-transparent) so the playback area is maximized.
    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildSurface(context, phase, isAudio),
          Align(
            alignment: Alignment.topCenter,
            child: _AnimatedBar(
              visible: _controlsVisible,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: _buildTopBar(context),
                  ),
                  // Soft shadow below the bar, fading the video into it.
                  const _EdgeFade(
                    height: 32,
                    barColor: Color(0xC8000000),
                  ),
                ],
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: _AnimatedBar(
              visible: _controlsVisible,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Soft shadow above the bar, fading the video into it.
                  const _EdgeFade(
                    height: 32,
                    barColor: Color(0xC8000000),
                    barAtTop: false,
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: _buildControlBar(context),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: Colors.black.withAlpha(200),
      child: Row(
        children: [
          Expanded(
            child: Text(
              controller.title.isEmpty ? 'Media Player' : controller.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
          // Full-screen ⇄ floating window (Phase 2; video only).
          if (controller.mediaType == MediaMediaType.video)
            IconButton(
              tooltip: 'Floating window',
              icon:
                  const Icon(Icons.picture_in_picture_alt, color: Colors.white),
              onPressed: () =>
                  controller.setDisplayMode(MediaPlayerDisplayMode.floating),
            ),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: controller.close,
          ),
        ],
      ),
    );
  }

  Widget _buildSurface(
      BuildContext context, MediaPlaybackPhase phase, bool isAudio) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Tap the video surface to show/hide the controls.
      onTap: () => setState(() => _controlsVisible = !_controlsVisible),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Video surface (aspect-ratio-preserving) or audio backdrop.
          if (!isAudio && controller.textureId != null)
            _AspectVideo(controller: controller)
          else
            Center(
              child: Icon(
                Icons.music_note,
                size: 96,
                color: Colors.white.withAlpha(120),
              ),
            ),
          if (phase == MediaPlaybackPhase.loading)
            const Center(child: CircularProgressIndicator()),
          if (phase == MediaPlaybackPhase.error)
            _ErrorPanel(controller: controller),
          if (phase == MediaPlaybackPhase.ended)
            _EndedPanel(controller: controller),
        ],
      ),
    );
  }

  Widget _buildControlBar(BuildContext context) {
    final phase = controller.phase;
    final durationMs = controller.duration.inMilliseconds;
    final maxMs = durationMs > 0 ? durationMs.toDouble() : 1.0;
    final value = (_dragValue ?? controller.position.inMilliseconds.toDouble())
        .clamp(0.0, maxMs)
        .toDouble();
    // Snap instantly on large jumps (replay / end snap / far seek) instead
    // of animating the bar across the track; keep the 250ms smoothing for
    // ordinary poll ticks.
    final snap = _dragValue != null ||
        (_lastSliderTargetMs != null &&
            (value - _lastSliderTargetMs!).abs() > _kSnapJumpMs);
    _lastSliderTargetMs = value;
    final hasDuration = durationMs > 0;
    final current = Duration(
        milliseconds:
            (_dragValue ?? controller.position.inMilliseconds).round());
    final seekEnabled = hasDuration &&
        (phase == MediaPlaybackPhase.playing ||
            phase == MediaPlaybackPhase.paused);

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      color: Colors.black.withAlpha(200),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const SizedBox(width: 8),
              Text(_fmt(current),
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
              Expanded(
                // Keep the disabled (ended) state visually identical to the
                // enabled one — otherwise Material's near-transparent
                // disabled colors make the bar look hidden after playback.
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    disabledActiveTrackColor: Colors.blueAccent,
                    disabledInactiveTrackColor: Colors.white24,
                    disabledThumbColor: Colors.blueAccent,
                  ),
                  // Smoothly interpolate between the 250ms poll updates
                  // instead of stepping; no animation while dragging so the
                  // thumb tracks the pointer precisely.
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: value),
                    duration: snap
                        ? Duration.zero
                        : const Duration(milliseconds: 250),
                    builder: (context, animated, _) => Slider(
                      value: animated,
                      max: maxMs,
                      activeColor: Colors.blueAccent,
                      inactiveColor: Colors.white24,
                      thumbColor: Colors.blueAccent,
                      onChanged: seekEnabled
                          ? (v) => setState(() => _dragValue = v)
                          : null,
                      onChangeEnd: seekEnabled
                          ? (v) {
                              controller
                                  .seek(Duration(milliseconds: v.round()));
                              setState(() => _dragValue = null);
                            }
                          : null,
                    ),
                  ),
                ),
              ),
              Text(hasDuration ? _fmt(controller.duration) : '--:--',
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(width: 8),
            ],
          ),
          Row(
            children: [
              IconButton(
                tooltip: phase == MediaPlaybackPhase.playing ? 'Pause' : 'Play',
                icon: Icon(
                  phase == MediaPlaybackPhase.playing
                      ? Icons.pause
                      : Icons.play_arrow,
                  color: Colors.white,
                  size: 32,
                ),
                onPressed: (phase == MediaPlaybackPhase.playing ||
                        phase == MediaPlaybackPhase.paused ||
                        phase == MediaPlaybackPhase.ended ||
                        phase == MediaPlaybackPhase.error)
                    ? controller.togglePlayPause
                    : null,
              ),
              const Spacer(),
              Icon(Icons.volume_up, color: Colors.white70, size: 20),
              SizedBox(
                width: 90,
                child: Slider(
                  value: controller.volume,
                  activeColor: Colors.white70,
                  inactiveColor: Colors.white24,
                  onChanged: controller.setVolume,
                ),
              ),
              const SizedBox(width: 16),
              _SpeedButton(controller: controller, speeds: _speeds),
              const SizedBox(width: 4),
            ],
          ),
        ],
      ),
    );
  }

  static String _fmt(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = d.inHours;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }
}

// ── floating window (video) ──────────────────────────────────────────────

class _FloatingPlayer extends StatefulWidget {
  const _FloatingPlayer({required this.controller});

  final MediaPlayerController controller;

  @override
  State<_FloatingPlayer> createState() => _FloatingPlayerState();
}

class _FloatingPlayerState extends State<_FloatingPlayer> {
  /// Size presets (width × height), cycled by the resize button.
  static const List<Size> _presets = [
    Size(240, 135),
    Size(320, 180),
    Size(480, 270),
  ];
  int _presetIndex = 0;

  /// Bumped on every resize (button or title-area double-tap); the
  /// draggable box re-snaps to the right edge when it changes.
  int _resizeTick = 0;

  /// Cycles to the next size preset and asks the draggable box to re-snap
  /// to the right edge.
  void _resize() {
    setState(() {
      _presetIndex = (_presetIndex + 1) % _presets.length;
      _resizeTick++;
    });
  }

  /// Whether the header / bottom controls are shown; toggled by tapping the
  /// video surface. Hiding keeps the layout space so the video size is
  /// unchanged.
  bool _controlsVisible = true;

  MediaPlayerController get controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    final size = _presets[_presetIndex];
    return _DraggableBox(
      controller: controller,
      size: size,
      snapSignal: _resizeTick,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white24),
          boxShadow: const [
            BoxShadow(color: Colors.black54, blurRadius: 12, spreadRadius: 1),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        // The video surface spans the full window; the header and the
        // bottom control strip overlay it (semi-transparent) so the
        // playback area is maximized.
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Video surface; tap the video area to show/hide the controls.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _controlsVisible = !_controlsVisible),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (controller.textureId != null)
                    _AspectVideo(controller: controller),
                  if (controller.phase == MediaPlaybackPhase.loading)
                    const Center(child: CircularProgressIndicator()),
                  if (controller.phase == MediaPlaybackPhase.error)
                    _ErrorPanel(controller: controller, compact: true),
                  if (controller.phase == MediaPlaybackPhase.ended)
                    _EndedPanel(controller: controller, compact: true),
                ],
              ),
            ),
            // Header overlay: title, back to full-screen, resize, close.
            // Double-tap the title area to cycle the window size, same as
            // the Resize button — kept off the buttons so their taps never
            // compete with the double-tap recognizer in the gesture arena.
            Align(
              alignment: Alignment.topCenter,
              child: _AnimatedBar(
                visible: _controlsVisible,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: double.infinity,
                      child: Container(
                        height: 32,
                        padding: const EdgeInsets.only(left: 8),
                        color: Colors.black.withAlpha(220),
                        child: Row(
                          children: [
                            Expanded(
                              // Text does not hit-test, so the opaque
                              // behavior keeps the whole title area
                              // interactive (double-tap to resize) instead
                              // of passing events through to the video.
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onDoubleTap: _resize,
                                child: Text(
                                  controller.title.isEmpty
                                      ? 'Media Player'
                                      : controller.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 12),
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Full screen',
                              iconSize: 18,
                              icon: const Icon(Icons.fullscreen,
                                  color: Colors.white),
                              onPressed: () => controller.setDisplayMode(
                                  MediaPlayerDisplayMode.fullScreen),
                            ),
                            IconButton(
                              tooltip: 'Resize',
                              iconSize: 18,
                              icon: const Icon(Icons.aspect_ratio,
                                  color: Colors.white),
                              onPressed: _resize,
                            ),
                            IconButton(
                              tooltip: 'Close',
                              iconSize: 18,
                              icon: const Icon(Icons.close,
                                  color: Colors.white),
                              onPressed: controller.close,
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Soft shadow below the header, fading the video into it.
                    const _EdgeFade(height: 16, barColor: Color(0xDC000000)),
                  ],
                ),
              ),
            ),
            // Bottom mini control strip overlay: compact play/pause plus a
            // thin progress bar (the full-screen Slider is 48px tall and
            // would dominate the smallest window preset).
            Align(
              alignment: Alignment.bottomCenter,
              child: _AnimatedBar(
                visible: _controlsVisible,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Soft shadow above the strip, fading the video into it.
                    const _EdgeFade(
                      height: 16,
                      barColor: Color(0xA0000000),
                      barAtTop: false,
                    ),
                    Container(
                      width: double.infinity,
                      color: Colors.black.withAlpha(160),
                      // Extra right padding so the progress bar does not
                      // hug the floating window's right edge.
                      padding: const EdgeInsets.fromLTRB(4, 2, 12, 2),
                      child: Row(
                        children: [
                          IconButton(
                            iconSize: 18,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 28, minHeight: 28),
                            icon: Icon(
                              controller.phase == MediaPlaybackPhase.playing
                                  ? Icons.pause
                                  : Icons.play_arrow,
                              color: Colors.white,
                            ),
                            onPressed: (controller.phase ==
                                        MediaPlaybackPhase.playing ||
                                    controller.phase ==
                                        MediaPlaybackPhase.paused ||
                                    controller.phase ==
                                        MediaPlaybackPhase.ended ||
                                    controller.phase ==
                                        MediaPlaybackPhase.error)
                                ? controller.togglePlayPause
                                : null,
                          ),
                          Expanded(
                            child: _FloatingProgress(controller: controller),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── audio mini bar ───────────────────────────────────────────────────────

class _AudioMiniBar extends StatefulWidget {
  const _AudioMiniBar({required this.controller});

  final MediaPlayerController controller;

  @override
  State<_AudioMiniBar> createState() => _AudioMiniBarState();
}

class _AudioMiniBarState extends State<_AudioMiniBar> {
  static const List<double> _speeds = [0.5, 1.0, 1.5, 2.0];
  static const Size _size = Size(380, 56);

  MediaPlayerController get controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    return _DraggableBox(
      controller: controller,
      size: _size,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xF21E1E2E),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: Colors.white24),
          boxShadow: const [
            BoxShadow(color: Colors.black54, blurRadius: 12, spreadRadius: 1),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            const Icon(Icons.music_note, color: Colors.white70, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    controller.title.isEmpty ? 'Audio' : controller.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        _fmt(controller.position),
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 10),
                      ),
                      // Slider's default minimum height (48) would overflow
                      // the 56px bar together with the title row — cap it at
                      // 32px (still draggable, Material thumb ~20px).
                      Expanded(
                        child: SizedBox(
                          height: 32,
                          child: _MiniProgress(controller: controller),
                        ),
                      ),
                      Text(
                        controller.duration.inMilliseconds > 0
                            ? _fmt(controller.duration)
                            : '--:--',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 10),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              iconSize: 26,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: Icon(
                controller.phase == MediaPlaybackPhase.playing
                    ? Icons.pause_circle_filled
                    : Icons.play_circle_filled,
                color: Colors.white,
              ),
              onPressed: (controller.phase == MediaPlaybackPhase.playing ||
                      controller.phase == MediaPlaybackPhase.paused ||
                      controller.phase == MediaPlaybackPhase.ended ||
                      controller.phase == MediaPlaybackPhase.error)
                  ? controller.togglePlayPause
                  : null,
            ),
            _SpeedButton(
                controller: controller, speeds: _speeds, compact: true),
            IconButton(
              tooltip: 'Close',
              iconSize: 20,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: const Icon(Icons.close, color: Colors.white54),
              onPressed: controller.close,
            ),
          ],
        ),
      ),
    );
  }

  static String _fmt(Duration d) {
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

// ── shared sub-widgets ───────────────────────────────────────────────────

/// Video texture scaled with BoxFit.contain inside a FittedBox sized to the
/// video's pixel dimensions, so resizing the window only scales the video
/// and never distorts its aspect ratio. Falls back to a stretched texture
/// when the pixel size is unknown (no stream metadata).
class _AspectVideo extends StatelessWidget {
  const _AspectVideo({required this.controller});

  final MediaPlayerController controller;

  @override
  Widget build(BuildContext context) {
    final w = controller.videoWidth;
    final h = controller.videoHeight;
    if (w == null || h == null || w <= 0 || h <= 0) {
      return Texture(textureId: controller.textureId!);
    }
    return FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(
        width: w.toDouble(),
        height: h.toDouble(),
        child: Texture(textureId: controller.textureId!),
      ),
    );
  }
}

/// Fades a control bar in/out while keeping its layout space (the video
/// surface size is unchanged) and blocks hit testing while hidden.
class _AnimatedBar extends StatelessWidget {
  const _AnimatedBar({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: child,
      ),
    );
  }
}

/// Soft shadow gradient at a control bar's edge, fading the video content
/// into the bar instead of a hard cutoff. [barColor] is the bar's solid
/// color; the gradient runs from it to transparent away from the bar
/// ([barAtTop] = the bar sits above this fade). IgnorePointer lets taps fall
/// through to the video surface below.
class _EdgeFade extends StatelessWidget {
  const _EdgeFade({
    required this.height,
    required this.barColor,
    this.barAtTop = true,
  });

  final double height;
  final Color barColor;
  final bool barAtTop;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        height: height,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: barAtTop
                ? [barColor, Colors.transparent]
                : [Colors.transparent, barColor],
          ),
        ),
      ),
    );
  }
}

/// Ultra-thin bottom progress bar for the floating window: a 3px track glued
/// to the bottom edge, seek by tap or horizontal drag. Replaces the
/// full-screen Slider (48px minimum height) so the window stays compact.
class _FloatingProgress extends StatefulWidget {
  const _FloatingProgress({required this.controller});

  final MediaPlayerController controller;

  @override
  State<_FloatingProgress> createState() => _FloatingProgressState();
}

class _FloatingProgressState extends State<_FloatingProgress> {
  /// Drag/tap preview value in milliseconds (null = not interacting).
  double? _dragMs;

  /// Last progress target (ms) rendered; null before the first build. Used
  /// to snap the bar instantly on large jumps (replay / end snap / far seek)
  /// instead of animating across the track (see _kSnapJumpMs).
  double? _lastTargetMs;

  MediaPlayerController get controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    final durationMs = controller.duration.inMilliseconds;
    final maxMs = durationMs > 0 ? durationMs.toDouble() : 1.0;
    final enabled = durationMs > 0 &&
        (controller.phase == MediaPlaybackPhase.playing ||
            controller.phase == MediaPlaybackPhase.paused);
    final valueMs = (_dragMs ?? controller.position.inMilliseconds.toDouble())
        .clamp(0.0, maxMs);
    // Snap instantly on large jumps (replay / end snap / far seek) instead
    // of animating the bar across the track; keep the 250ms smoothing for
    // ordinary poll ticks.
    final snap = _dragMs != null ||
        (_lastTargetMs != null &&
            (valueMs - _lastTargetMs!).abs() > _kSnapJumpMs);
    _lastTargetMs = valueMs;
    final ratio = maxMs > 0 ? valueMs / maxMs : 0.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        double msAtDx(double dx) =>
            (maxMs * (dx / width).clamp(0.0, 1.0)).roundToDouble();
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Seek on tap; preview while dragging, seek on release.
          onTapDown: enabled
              ? (details) =>
                  setState(() => _dragMs = msAtDx(details.localPosition.dx))
              : null,
          onTapUp: enabled
              ? (details) {
                  controller.seek(Duration(milliseconds: _dragMs!.round()));
                  setState(() => _dragMs = null);
                }
              : null,
          onTapCancel: enabled ? () => setState(() => _dragMs = null) : null,
          onHorizontalDragStart: enabled
              ? (details) =>
                  setState(() => _dragMs = msAtDx(details.localPosition.dx))
              : null,
          onHorizontalDragUpdate: enabled
              ? (details) =>
                  setState(() => _dragMs = msAtDx(details.localPosition.dx))
              : null,
          onHorizontalDragEnd: enabled
              ? (_) {
                  controller.seek(Duration(milliseconds: _dragMs!.round()));
                  setState(() => _dragMs = null);
                }
              : null,
          child: SizedBox(
            height: 28,
            // Smoothly interpolate between the 250ms poll updates instead of
            // stepping; no animation while dragging. Vertically centered so
            // the track lines up with the play/pause button icon on the same
            // control strip.
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: ratio),
              duration:
                  snap ? Duration.zero : const Duration(milliseconds: 250),
              builder: (context, animatedRatio, _) => Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  height: 3,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(1.5),
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: animatedRatio,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.blueAccent,
                          borderRadius: BorderRadius.circular(1.5),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Narrow progress slider shared by the floating window and the mini bar.
class _MiniProgress extends StatelessWidget {
  const _MiniProgress({required this.controller});

  final MediaPlayerController controller;

  @override
  Widget build(BuildContext context) {
    final durationMs = controller.duration.inMilliseconds;
    final maxMs = durationMs > 0 ? durationMs.toDouble() : 1.0;
    final value =
        controller.position.inMilliseconds.toDouble().clamp(0.0, maxMs);
    final enabled = durationMs > 0 &&
        (controller.phase == MediaPlaybackPhase.playing ||
            controller.phase == MediaPlaybackPhase.paused);
    return Slider(
      value: value,
      max: maxMs,
      activeColor: Colors.blueAccent,
      inactiveColor: Colors.white24,
      onChanged: enabled
          ? (v) => controller.seek(Duration(milliseconds: v.round()))
          : null,
    );
  }
}

/// Playback-speed selector (0.5x / 1.0x / 1.5x / 2.0x).
class _SpeedButton extends StatelessWidget {
  const _SpeedButton(
      {required this.controller, required this.speeds, this.compact = false});

  final MediaPlayerController controller;
  final List<double> speeds;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<double>(
      initialValue: controller.playbackRate,
      tooltip: 'Playback speed',
      onSelected: controller.setPlaybackRate,
      itemBuilder: (context) => [
        for (final speed in speeds)
          PopupMenuItem(value: speed, child: Text('${speed}x')),
      ],
      child: Container(
        padding:
            EdgeInsets.symmetric(horizontal: compact ? 6 : 10, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white38),
        ),
        child: Text(
          '${controller.playbackRate.toStringAsFixed(1)}x',
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      ),
    );
  }
}

/// Ended state: stays on the last frame with a replay control; the user
/// closes explicitly. Full screen uses a capsule button (replay icon +
/// "重播" text), the floating window uses a plain replay icon (compact) —
/// the capsule is too prominent on the small window.
class _EndedPanel extends StatelessWidget {
  const _EndedPanel({required this.controller, this.compact = false});

  final MediaPlayerController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      // A plain icon (no IconButton tap-target box) so the glyph sits exactly
      // at the video area's center; the padding keeps a comfortable hit area.
      return Center(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: controller.togglePlayPause,
          child: const Padding(
            padding: EdgeInsets.all(10),
            child: Icon(Icons.replay, color: Colors.white, size: 32),
          ),
        ),
      );
    }
    return Center(
      child: GestureDetector(
        onTap: controller.togglePlayPause,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withAlpha(150),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.replay, color: Colors.white, size: 22),
              const SizedBox(width: 8),
              const Text('重播',
                  style: TextStyle(color: Colors.white, fontSize: 14)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Unified error state (decision 22): "无法播放该视频" (or the blob/MSE
/// message, decision 11) + retry button that reloads the same URL.
class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.controller, this.compact = false});

  final MediaPlayerController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.error_outline,
            size: compact ? 28 : 56, color: Colors.white.withAlpha(180)),
        const SizedBox(height: 8),
        Text(
          controller.errorMessage,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
        const SizedBox(height: 6),
        TextButton.icon(
          onPressed: controller.togglePlayPause,
          icon: const Icon(Icons.refresh, color: Colors.blueAccent),
          label: const Text('重试', style: TextStyle(color: Colors.blueAccent)),
        ),
      ],
    );
    return Center(
      child: compact
          ? content
          : Container(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(180),
                borderRadius: BorderRadius.circular(12),
              ),
              child: content,
            ),
    );
  }
}
