/// Injected into the page before its own scripts run. It gives the web app what Safari on iPhone lacks:
/// speech recognition (window.SpeechRecognition backed by SpeechBridge), real vibration (navigator.vibrate),
/// keeping the screen on (navigator.wakeLock) and a native mistake tone (window.HIFZ_NATIVE.beep).
enum BridgeScript {
    static let source = #"""
(function () {
  if (window.HIFZ_NATIVE) return;
  var handlers = window.webkit && window.webkit.messageHandlers;
  var H = handlers && handlers.hifz;
  if (!H) return;
  function post(m) { try { H.postMessage(m); } catch (e) {} }

  var seq = 0, current = null;
  function NativeSpeechRecognition() {
    this.lang = "ar-SA";
    this.continuous = false;
    this.interimResults = false;
    this.maxAlternatives = 1;
    this.contextualStrings = [];
    this.onstart = null; this.onresult = null; this.onerror = null; this.onend = null;
    this._id = 0;
  }
  NativeSpeechRecognition.prototype.start = function () {
    if (current && current !== this) current.abort();
    current = this;
    this._id = ++seq;
    post({ type: "sr-start", id: this._id, lang: this.lang || "ar-SA", ctx: (this.contextualStrings || []).slice(0, 100) });
  };
  NativeSpeechRecognition.prototype.stop = function () { if (current === this) post({ type: "sr-stop", id: this._id }); };
  NativeSpeechRecognition.prototype.abort = function () { if (current === this) post({ type: "sr-abort", id: this._id }); };
  NativeSpeechRecognition.prototype.addEventListener = function (type, fn) { this["on" + type] = fn; };
  NativeSpeechRecognition.prototype.removeEventListener = function (type) { this["on" + type] = null; };

  window.__hifzSR = function (id, kind, data) {
    var r = current;
    if (!r || r._id !== id) return;
    if (kind === "start") {
      if (r.onstart) r.onstart({ type: "start" });
    } else if (kind === "result") {
      var results = (data.results || []).map(function (x) {
        var res = [{ transcript: x.t, confidence: 0.9 }];
        res.isFinal = !!x.f;
        return res;
      });
      if (r.onresult) r.onresult({ type: "result", resultIndex: 0, results: results });
    } else if (kind === "error") {
      if (r.onerror) r.onerror({ type: "error", error: data.error, message: data.message || "" });
    } else if (kind === "end") {
      current = null;
      if (r.onend) r.onend({ type: "end" });
    }
  };
  window.SpeechRecognition = NativeSpeechRecognition;
  window.webkitSpeechRecognition = NativeSpeechRecognition;

  try { navigator.vibrate = function () { post({ type: "haptic" }); return true; }; } catch (e) {}

  var lock = {
    released: false,
    release: function () { this.released = true; post({ type: "awake", on: false }); return Promise.resolve(); },
    addEventListener: function () {}
  };
  try {
    Object.defineProperty(navigator, "wakeLock", {
      configurable: true,
      value: { request: function () { lock.released = false; post({ type: "awake", on: true }); return Promise.resolve(lock); } }
    });
  } catch (e) {}

  window.HIFZ_NATIVE = {
    platform: "ios",
    version: "__APP_VERSION__",
    beep: function () { post({ type: "beep" }); },
    open: function (url) { post({ type: "open", url: String(url) }); }
  };
})();
"""#
}
