// Media player takeover — JS injection script.
//
// This script is evaluated in every frame's V8 context by the renderer side
// (WebviewApp::OnContextCreated) before any page script runs, so the
// HTMLMediaElement hijack always wins. It is also shipped through the $cef
// V8 extension path: the `$cef.MediaPlayer` channel is directly available in
// every frame (including cross-origin iframes / OOPIF processes), with the
// frameId attached natively to each message.
//
// Behavior contract (media_player_design.md §4.1):
// - Hijack HTMLMediaElement.prototype.play/.pause. play() decides by gesture:
//   - has gesture (navigator.userActivation.hasBeenActive, fallback: 500ms
//     window) → post mediaPlayRequest, return a promise that stays pending
//     while playing, rejects with AbortError when the player closes, or
//     rejects when fvp reports failure (mediaPlayResult success:false).
//   - no gesture (page never activated) → silent ignore, reject with
//     NotAllowedError like Chrome's autoplay policy.
// - pause() posts mediaPauseRequest (no native playback exists anymore).
// - Dynamically created media elements are covered by the prototype hijack;
//   a MutationObserver watches for element removal / display:none and posts
//   mediaElementRemoved (decision 21).
// - Dart → JS write-backs arrive through window.__cefMediaPlayerDispatch
//   (executed in the owning frame via executeJavaScriptInFrame):
//   'state' (mediaStateUpdate), 'playResult' (mediaPlayResult),
//   'closed' (mediaClosed).
//
// Phase 1 (B-level): paused / currentTime / duration / ended plus
// timeupdate / play / pause / ended / error / abort events.
// Phase 3: full HTMLMediaElement shim — volume / muted / playbackRate
// setters forward to the native player (mediaPropertyChange), currentTime
// setter issues mediaSeekRequest, readyState / networkState / buffered /
// seekable / played / seeking are mirrored from write-backs, and
// seeking / seeked / waiting / canplay / loadedmetadata events are
// dispatched on transitions.

/// JS injection script (string constant, no Dart interpolation).
const String mediaPlayerInjectScript = r'''
(function() {
  if (window.__cefMediaPlayerInjected) return;
  window.__cefMediaPlayerInjected = true;

  var CHANNEL = 'MediaPlayer';
  var nextMediaId = 1;
  // mediaId -> { el, mediaId, state, pendingResolve, pendingReject }
  var managed = Object.create(null);

  // ── gesture detection (decision 20) ────────────────────────────────────
  // Primary: navigator.userActivation.hasBeenActive — sticky per-window, true
  // once the user ever interacted with this frame's window. A play() called
  // asynchronously (>500ms) after the click still hits it.
  // Fallback for very old kernels without the API: 500ms interaction window.
  var hasUserActivationApi = typeof navigator.userActivation === 'object' &&
      typeof navigator.userActivation.hasBeenActive === 'boolean';
  var lastInteraction = 0;
  if (!hasUserActivationApi) {
    ['mousedown', 'keydown', 'touchstart'].forEach(function(type) {
      window.addEventListener(type, function() {
        lastInteraction = Date.now();
      }, true);
    });
  }
  function hasGesture() {
    var gesture;
    if (hasUserActivationApi) {
      gesture = navigator.userActivation.hasBeenActive;
    } else {
      gesture = (Date.now() - lastInteraction) < 500;
    }
    console.log('[cef-media-player] play() gesture check ->', gesture,
        '(userActivationApi:', hasUserActivationApi + ')');
    return gesture;
  }

  // ── messaging ──────────────────────────────────────────────────────────
  function post(payload) {
    try {
      $cef.MediaPlayer.postMessage(payload);
    } catch (e) {
      console.log('[cef-media-player] postMessage failed:', e);
    }
  }

  // ── media element helpers ──────────────────────────────────────────────
  function resolveMediaUrl(el) {
    var src = '';
    try { src = el.currentSrc || el.src || ''; } catch (e) {}
    if (!src) {
      var sources = el.querySelectorAll && el.querySelectorAll('source');
      for (var i = 0; sources && i < sources.length; i++) {
        if (sources[i].src) { src = sources[i].src; break; }
      }
    }
    if (!src) return '';
    try {
      // Resolve relative URLs against the frame's own location (the element
      // lives in this frame, so location.href is the correct base).
      return new URL(src, location.href).href;
    } catch (e) {
      return src;
    }
  }

  function mediaType(el) {
    return el.tagName === 'VIDEO' ? 'video' : 'audio';
  }

  function mediaTitle(el) {
    return el.getAttribute && (el.getAttribute('title') || document.title) || document.title;
  }

  function dispatchEvent(el, type) {
    try { el.dispatchEvent(new Event(type)); } catch (e) {}
  }

  function rejectPending(entry, err) {
    if (entry.pendingReject) {
      entry.pendingReject(err);
      entry.pendingReject = null;
      entry.pendingResolve = null;
    }
  }

  // ── per-element shim ───────────────────────────────────────────────────
  // Phase 1: B-level minimal set (paused/currentTime/duration/ended).
  // Phase 3: full property proxy — volume/muted/playbackRate setters forward
  // to the native player via mediaPropertyChange, currentTime setter issues
  // mediaSeekRequest, readyState/networkState/buffered/seekable/played/
  // seeking are mirrored from Dart write-backs.
  function installShim(el, entry) {
    var data = {
      paused: true,
      currentTime: 0,
      duration: NaN,
      ended: false,
      volume: 1,
      muted: false,
      playbackRate: 1,
      readyState: 0,
      networkState: 0,
      buffered: [],      // [[startSec, endSec], ...]
      seeking: false,
      waiting: false,
      lastTimeupdate: 0
    };
    el.__cefMediaData = data;
    var postProperty = function(property, value) {
      post({ cmd: 'mediaPropertyChange', mediaId: entry.mediaId,
             property: property, value: value });
    };
    Object.defineProperty(el, 'paused', {
      configurable: true,
      get: function() { return data.paused; }
    });
    Object.defineProperty(el, 'ended', {
      configurable: true,
      get: function() { return data.ended; }
    });
    Object.defineProperty(el, 'duration', {
      configurable: true,
      get: function() { return data.duration; }
    });
    Object.defineProperty(el, 'currentTime', {
      configurable: true,
      get: function() { return data.currentTime; },
      // Page custom seek bar drag → mediaSeekRequest (Phase 3); the native
      // side seeks and writes the position back (seeked event follows).
      set: function(v) {
        var nv = Number(v);
        if (!isFinite(nv) || nv < 0) return;
        data.currentTime = nv;
        if (entry.state !== 'playing' && entry.state !== 'paused') return;
        if (data.seeking) return; // already seeking — avoid event spam
        data.seeking = true;
        dispatchEvent(el, 'seeking');
        post({ cmd: 'mediaSeekRequest', mediaId: entry.mediaId, position: nv });
      }
    });
    Object.defineProperty(el, 'volume', {
      configurable: true,
      get: function() { return data.volume; },
      set: function(v) {
        var nv = Math.min(1, Math.max(0, Number(v) || 0));
        if (nv === data.volume) return;
        data.volume = nv;
        postProperty('volume', nv);
      }
    });
    Object.defineProperty(el, 'muted', {
      configurable: true,
      get: function() { return data.muted; },
      set: function(v) {
        var nv = !!v;
        if (nv === data.muted) return;
        data.muted = nv;
        postProperty('muted', nv);
      }
    });
    Object.defineProperty(el, 'playbackRate', {
      configurable: true,
      get: function() { return data.playbackRate; },
      set: function(v) {
        var nv = Number(v);
        if (!isFinite(nv) || nv <= 0 || nv === data.playbackRate) return;
        data.playbackRate = nv;
        postProperty('playbackRate', nv);
      }
    });
    Object.defineProperty(el, 'readyState', {
      configurable: true,
      get: function() { return data.readyState; }
    });
    Object.defineProperty(el, 'networkState', {
      configurable: true,
      get: function() { return data.networkState; }
    });
    Object.defineProperty(el, 'seeking', {
      configurable: true,
      get: function() { return data.seeking; }
    });
    // TimeRanges-like proxies (ranges mirrored from Dart; played is a
    // progressive approximation). Dart writes a flat [s1,e1,s2,e2,...]
    // array; page-facing TimeRanges uses nested [start, end] pairs.
    function makeTimeRanges(ranges) {
      var r = [];
      if (ranges) {
        if (ranges.length && Array.isArray(ranges[0])) {
          r = ranges;
        } else {
          for (var i = 0; i + 1 < ranges.length; i += 2) {
            r.push([ranges[i], ranges[i + 1]]);
          }
        }
      }
      return {
        length: r.length,
        start: function(i) { return r[i][0]; },
        end: function(i) { return r[i][1]; }
      };
    }
    Object.defineProperty(el, 'buffered', {
      configurable: true,
      get: function() { return makeTimeRanges(data.buffered); }
    });
    Object.defineProperty(el, 'seekable', {
      configurable: true,
      get: function() { return makeTimeRanges(data.buffered); }
    });
    Object.defineProperty(el, 'played', {
      configurable: true,
      get: function() { return makeTimeRanges([[0, data.currentTime]]); }
    });
  }

  function getOrCreateEntry(el) {
    var mediaId = el.__cefMediaId;
    if (mediaId !== undefined && managed[mediaId]) {
      return managed[mediaId];
    }
    // mediaId is a string end-to-end (design §4.2): the Dart bridge decodes
    // it as String. Keep the protocol type-stable across postMessage, state
    // write-backs and element removal tracking.
    mediaId = String(nextMediaId++);
    el.__cefMediaId = mediaId;
    var entry = { el: el, mediaId: mediaId, state: 'idle',
                  pendingResolve: null, pendingReject: null };
    managed[mediaId] = entry;
    installShim(el, entry);
    return entry;
  }

  function abandonEntry(entry) {
    delete managed[entry.mediaId];
    try { delete entry.el.__cefMediaId; } catch (e) {}
  }

  // ── element removal / display:none monitoring (decision 21) ─────────────
  // Inline style.display changes and DOM removal are cheap to check on every
  // mutation; cascaded display (class / media queries) is re-checked via
  // getComputedStyle on a throttled cadence (millisecond-level delay is
  // accepted — see known limitation 8 in the design doc).
  var lastComputedCheck = 0;
  function checkRemoved() {
    var now = Date.now();
    var computedDue = (now - lastComputedCheck) > 300;
    var removed = [];
    for (var mediaId in managed) {
      var entry = managed[mediaId];
      var el = entry.el;
      try {
        if (!el.isConnected) { removed.push(entry); continue; }
        if (el.style && el.style.display === 'none') { removed.push(entry); continue; }
        if (computedDue && getComputedStyle(el).display === 'none') {
          removed.push(entry);
          continue;
        }
      } catch (e) {
        // Detached / destroyed element — treat as removed.
        removed.push(entry);
      }
    }
    if (computedDue) lastComputedCheck = now;
    removed.forEach(function(entry) {
      post({ cmd: 'mediaElementRemoved', mediaId: entry.mediaId });
      rejectPending(entry,
          new DOMException('The element was removed from the document.', 'AbortError'));
      dispatchEvent(entry.el, 'abort');
      abandonEntry(entry);
    });
  }

  var observer = null;
  function ensureObserver() {
    if (observer) return;
    observer = new MutationObserver(checkRemoved);
    observer.observe(document, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['style', 'class']
    });
  }

  // ── Dart → JS write-back entry (mediaStateUpdate / mediaPlayResult /
  //    mediaClosed), executed in the owning frame via executeJavaScriptInFrame
  window.__cefMediaPlayerDispatch = function(type, data) {
    var entry = data && managed[data.mediaId];
    if (!entry) return;
    var el = entry.el;
    var d = el.__cefMediaData;
    if (!d) return;
    var wasPaused = d.paused;

    if (type === 'state') {
      if (typeof data.currentTime === 'number') d.currentTime = data.currentTime;
      if (typeof data.duration === 'number') d.duration = data.duration;
      if (data.ended === true) {
        d.ended = true;
        d.paused = true;
        entry.state = 'ended';
      } else {
        if (data.ended === false) d.ended = false;
        if (typeof data.paused === 'boolean') d.paused = data.paused;
      }
      if (d.ended) {
        dispatchEvent(el, 'ended');
        if (!wasPaused) dispatchEvent(el, 'pause');
      } else if (typeof data.paused === 'boolean' && data.paused !== wasPaused) {
        dispatchEvent(el, data.paused ? 'pause' : 'play');
      }
      if (typeof data.currentTime === 'number') {
        // timeupdate throttled to >= 250ms.
        var now = Date.now();
        if (now - d.lastTimeupdate >= 250) {
          d.lastTimeupdate = now;
          dispatchEvent(el, 'timeupdate');
        }
      }
      // ── Phase 3: full property mirror ───────────────────────────────────
      if (typeof data.volume === 'number') {
        d.volume = Math.min(1, Math.max(0, data.volume));
      }
      if (typeof data.muted === 'boolean') d.muted = data.muted;
      if (typeof data.playbackRate === 'number' && data.playbackRate > 0) {
        d.playbackRate = data.playbackRate;
      }
      if (typeof data.readyState === 'number') {
        var oldReady = d.readyState;
        d.readyState = data.readyState;
        // Events fired on readiness transitions (Phase 3).
        if (oldReady < 1 && data.readyState >= 1) {
          dispatchEvent(el, 'loadedmetadata');
        }
        if (oldReady < 4 && data.readyState >= 4) {
          dispatchEvent(el, 'canplay');
        }
      }
      if (typeof data.networkState === 'number') {
        var oldNet = d.networkState;
        d.networkState = data.networkState;
        if (oldNet === 2 && data.networkState !== 2) {
          d.waiting = false;
          dispatchEvent(el, 'playing');
        }
      }
      if (Array.isArray(data.buffered)) d.buffered = data.buffered;
      if (data.seeking === true && !d.seeking) {
        d.seeking = true;
        dispatchEvent(el, 'seeking');
      } else if (data.seeking === false && d.seeking) {
        d.seeking = false;
        dispatchEvent(el, 'seeked');
      }
      if (data.waiting === true && !d.waiting) {
        d.waiting = true;
        dispatchEvent(el, 'waiting');
      } else if (data.waiting === false && d.waiting) {
        d.waiting = false;
      }
    } else if (type === 'playResult') {
      console.log('[cef-media-player] playResult received: mediaId=' +
          data.mediaId + ' success=' + data.success +
          (data.error ? ' error="' + data.error + '"' : ''));
      if (data.success) {
        entry.state = 'playing';
        d.paused = false;
        if (typeof data.duration === 'number') d.duration = data.duration;
        dispatchEvent(el, 'play');
      } else {
        // fvp failed → play() rejects, element stays paused (design §4.2).
        entry.state = 'idle';
        d.paused = true;
        d.currentTime = 0;
        rejectPending(entry,
            new DOMException(data.error || 'Unable to play the media.', 'NotSupportedError'));
        dispatchEvent(el, 'error');
      }
    } else if (type === 'closed') {
      // Player closed by user / cross-document navigation / element removal
      // → element back to initial state, pending play() rejects with
      // AbortError so page-side `await play()` never hangs (design §4.1).
      d.paused = true;
      d.ended = false;
      d.currentTime = 0;
      d.duration = NaN;
      d.volume = 1;
      d.muted = false;
      d.playbackRate = 1;
      d.readyState = 0;
      d.networkState = 0;
      d.buffered = [];
      d.seeking = false;
      d.waiting = false;
      entry.state = 'idle';
      rejectPending(entry,
          new DOMException('The media player was closed.', 'AbortError'));
      dispatchEvent(el, 'abort');
      if (!wasPaused) dispatchEvent(el, 'pause');
    }
  };

  // ── hijack play / pause ────────────────────────────────────────────────
  // New elements are covered automatically: dynamic <video>/<audio> inherit
  // the patched prototype methods (design §4.1 item 2).
  var origPlay = HTMLMediaElement.prototype.play;
  var origPause = HTMLMediaElement.prototype.pause;

  HTMLMediaElement.prototype.play = function() {
    var el = this;
    var entry = getOrCreateEntry(el);
    ensureObserver();

    if (!hasGesture()) {
      // Page never activated → silent ignore, reject like the browser's
      // autoplay policy so the page can show a "tap to play" affordance.
      return Promise.reject(new DOMException(
          'play() failed because the user did not interact with the document.',
          'NotAllowedError'));
    }

    // url may be '' for unresolvable sources (blob/MSE): still hand it to the
    // player which reports the unified error state (blob-specific messaging
    // lands in Phase 2, decision 11/22).
    entry.state = 'loading';
    post({
      cmd: 'mediaPlayRequest',
      mediaId: entry.mediaId,
      url: resolveMediaUrl(el),
      type: mediaType(el),
      title: mediaTitle(el),
      gesture: true
    });

    // Pending promise: resolved never on success — stays pending while the
    // player is open; rejected on fvp failure (playResult success:false) or
    // player close (AbortError).
    return new Promise(function(resolve, reject) {
      entry.pendingResolve = resolve;
      entry.pendingReject = reject;
    });
  };

  HTMLMediaElement.prototype.pause = function() {
    var el = this;
    var mediaId = el.__cefMediaId;
    if (mediaId === undefined || !managed[mediaId]) {
      // Not yet taken over — fall back to native behavior.
      return origPause.apply(this, arguments);
    }
    var entry = managed[mediaId];
    if (entry.state === 'idle' || entry.state === 'ended') return;
    entry.state = 'paused';
    post({ cmd: 'mediaPauseRequest', mediaId: mediaId });
  };
})();
''';
