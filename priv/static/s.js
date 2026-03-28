(function () {
  "use strict";

  var script = document.currentScript;
  if (!script) return;

  var site = script.getAttribute("data-id");
  if (!site) return;

  var gdpr = script.getAttribute("data-gdpr") || "on";
  var xdSites = (script.getAttribute("data-xd") || "").split(",").filter(Boolean);
  var endpoint = script.src.replace(/\/assets\/v1\.js.*$/, "");

  // Check opt-out
  if (getCookie("_sab_optout")) return;

  var vid = null;
  var sid = null;
  var pageStart = Date.now();
  var hadInteraction = false;

  // Track human interaction signals
  var interactionEvents = ["mousedown", "touchstart", "scroll", "keydown"];
  function markInteraction() {
    hadInteraction = true;
    interactionEvents.forEach(function (e) {
      document.removeEventListener(e, markInteraction);
    });
  }
  interactionEvents.forEach(function (e) {
    document.addEventListener(e, markInteraction, { once: false, passive: true });
  });

  // GDPR-off: use cookies
  if (gdpr === "off") {
    vid = getCookie("_sab");
    if (!vid) {
      vid = generateId();
      setCookie("_sab", vid, 63072000); // 2 years
    }
  } else {
    // GDPR-on: fingerprint
    vid = fingerprint();
  }

  // Clean cross-domain token from URL
  var url = new URL(window.location.href);
  var xdToken = url.searchParams.get("_sabt");
  if (xdToken) {
    url.searchParams.delete("_sabt");
    window.history.replaceState({}, "", url.toString());
  }

  // Persist UTMs in sessionStorage (GDPR-off only)
  if (gdpr === "off") {
    var utmParams = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content"];
    utmParams.forEach(function (key) {
      var val = url.searchParams.get(key);
      if (val) {
        try {
          sessionStorage.setItem("_sab_" + key, val);
        } catch (e) {}
      }
    });
  }

  // Decorate cross-domain links
  if (gdpr === "off" && xdSites.length > 0) {
    decorateLinks();
  }

  // Send initial pageview
  sendEvent("pageview");

  // SPA support
  var origPushState = history.pushState;
  history.pushState = function () {
    origPushState.apply(this, arguments);
    sendDuration();
    pageStart = Date.now();
    sendEvent("pageview");
  };

  window.addEventListener("popstate", function () {
    sendDuration();
    pageStart = Date.now();
    sendEvent("pageview");
  });

  // Duration on visibility change
  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState === "hidden") {
      sendDuration();
    }
  });

  // Public API
  window.Spectabas = {
    track: function (name, props) {
      sendEvent("custom", { n: name, p: props || {} });
    },
    identify: function (traits) {
      send(endpoint + "/c/i", {
        vid: vid,
        traits: traits,
      });
    },
    optOut: function () {
      setCookie("_sab_optout", "1", 63072000);
    },
    ecommerce: {
      addOrder: function (order) {
        sendEvent("ecommerce_order", { p: order });
      },
      addItem: function (item) {
        sendEvent("ecommerce_item", { p: item });
      },
    },
  };

  function sendEvent(type, extra) {
    var botHints =
      !!(navigator.webdriver) ||
      (window.screen.width === 0 && window.screen.height === 0) ||
      !("onmouseover" in document) ||
      /headless/i.test(navigator.userAgent);

    var payload = {
      t: type,
      u: window.location.href,
      r: document.referrer || "",
      vid: vid,
      sid: sid,
      sw: window.screen.width || 0,
      sh: window.screen.height || 0,
      d: 0,
      p: {},
      _bot: botHints ? 1 : 0,
      _hi: hadInteraction ? 1 : 0,
    };

    if (extra) {
      if (extra.n) payload.n = extra.n;
      if (extra.p) payload.p = extra.p;
    }

    // Add UTMs from sessionStorage
    if (gdpr === "off") {
      try {
        var utms = [
          "utm_source",
          "utm_medium",
          "utm_campaign",
          "utm_term",
          "utm_content",
        ];
        utms.forEach(function (key) {
          var val = sessionStorage.getItem("_sab_" + key);
          if (val) payload.p[key] = val;
        });
      } catch (e) {}
    }

    send(endpoint + "/c/e?s=" + encodeURIComponent(site), payload);
  }

  function sendDuration() {
    var duration = Math.round((Date.now() - pageStart) / 1000);
    if (duration < 1) return;

    var payload = {
      t: "duration",
      u: window.location.href,
      vid: vid,
      sid: sid,
      d: duration,
      sw: 0,
      sh: 0,
      p: {},
    };

    send(
      endpoint + "/c/e?s=" + encodeURIComponent(site),
      payload
    );
  }

  function send(url, data) {
    var body = JSON.stringify(data);
    if (body.length > 8192) return; // Drop oversized payloads

    try {
      if (navigator.sendBeacon) {
        var blob = new Blob([body], { type: "application/json" });
        if (navigator.sendBeacon(url, blob)) return;
      }
    } catch (e) {}

    try {
      fetch(url, {
        method: "POST",
        body: body,
        headers: { "Content-Type": "application/json" },
        keepalive: true,
      });
    } catch (e) {}
  }

  function generateId() {
    var array = new Uint8Array(16);
    crypto.getRandomValues(array);
    return Array.from(array, function (b) {
      return ("0" + b.toString(16)).slice(-2);
    }).join("");
  }

  // ---- Enhanced Browser Fingerprint ----
  // Combines multiple browser signals into a stable hash for cross-session correlation.
  // Survives cookie clearing, incognito, and VPN changes.

  function fingerprint() {
    var signals = [
      navigator.userAgent,
      screen.width + "x" + screen.height + "x" + (screen.colorDepth || 0),
      window.devicePixelRatio || 1,
      Intl.DateTimeFormat().resolvedOptions().timeZone || "",
      navigator.language || "",
      navigator.languages ? navigator.languages.join(",") : "",
      navigator.hardwareConcurrency || 0,
      navigator.deviceMemory || 0,
      navigator.maxTouchPoints || 0,
      navigator.platform || "",
      !!window.chrome,
      !!window.safari,
      typeof window.SharedArrayBuffer !== "undefined",
      new Date().getTimezoneOffset(),
    ];

    // Canvas fingerprint (GPU/driver differences)
    try {
      var canvas = document.createElement("canvas");
      canvas.width = 200;
      canvas.height = 50;
      var ctx = canvas.getContext("2d");
      ctx.textBaseline = "top";
      ctx.font = "14px Arial";
      ctx.fillStyle = "#f60";
      ctx.fillRect(0, 0, 200, 50);
      ctx.fillStyle = "#069";
      ctx.fillText("Spectabas\ud83d\ude00", 2, 15);
      ctx.fillStyle = "rgba(102, 204, 0, 0.7)";
      ctx.fillText("analytics", 4, 30);
      signals.push(canvas.toDataURL());
    } catch (e) {
      signals.push("no-canvas");
    }

    // WebGL renderer
    try {
      var gl = document.createElement("canvas").getContext("webgl");
      if (gl) {
        var dbg = gl.getExtension("WEBGL_debug_renderer_info");
        if (dbg) {
          signals.push(gl.getParameter(dbg.UNMASKED_VENDOR_WEBGL) || "");
          signals.push(gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) || "");
        }
      }
    } catch (e) {
      signals.push("no-webgl");
    }

    // AudioContext fingerprint
    try {
      var audioCtx = new (window.OfflineAudioContext || window.webkitOfflineAudioContext)(1, 44100, 44100);
      var osc = audioCtx.createOscillator();
      osc.type = "triangle";
      osc.frequency.setValueAtTime(10000, audioCtx.currentTime);
      var comp = audioCtx.createDynamicsCompressor();
      osc.connect(comp);
      comp.connect(audioCtx.destination);
      osc.start(0);
      audioCtx.startRendering();
      audioCtx.oncomplete = function (e) {
        var buf = e.renderedBuffer.getChannelData(0);
        var sum = 0;
        for (var i = 4500; i < 5000; i++) sum += Math.abs(buf[i]);
        signals.push("audio:" + sum.toFixed(6));
      };
    } catch (e) {
      signals.push("no-audio");
    }

    return "fp_" + murmurHash(signals.join("|||"));
  }

  // MurmurHash3 (32-bit) — fast, good distribution, not cryptographic
  function murmurHash(str) {
    var h = 0x12345678;
    for (var i = 0; i < str.length; i++) {
      var k = str.charCodeAt(i);
      k = Math.imul(k, 0xcc9e2d51);
      k = (k << 15) | (k >>> 17);
      k = Math.imul(k, 0x1b873593);
      h ^= k;
      h = (h << 13) | (h >>> 19);
      h = Math.imul(h, 5) + 0xe6546b64;
    }
    h ^= str.length;
    h ^= h >>> 16;
    h = Math.imul(h, 0x85ebca6b);
    h ^= h >>> 13;
    h = Math.imul(h, 0xc2b2ae35);
    h ^= h >>> 16;
    return (h >>> 0).toString(36);
  }

  // ---- Form Abuse Detection ----
  // Monitors form interactions to detect spam/abuse patterns.

  var formStats = { submits: 0, pastes: 0, rapidClicks: 0, lastClickTime: 0 };

  document.addEventListener("submit", function (e) {
    formStats.submits++;
    var timeSinceLoad = (Date.now() - pageStart) / 1000;

    // Suspicious: form submitted < 2 seconds after page load
    var suspicious = timeSinceLoad < 2 || formStats.submits > 3;

    if (suspicious || formStats.pastes > 3 || formStats.rapidClicks > 10) {
      sendEvent("custom", {
        n: "_form_abuse",
        p: {
          submits: String(formStats.submits),
          pastes: String(formStats.pastes),
          rapid_clicks: String(formStats.rapidClicks),
          time_to_submit: String(Math.round(timeSinceLoad)),
          had_interaction: hadInteraction ? "1" : "0"
        }
      });
    }
  }, true);

  document.addEventListener("paste", function () {
    formStats.pastes++;
  }, true);

  document.addEventListener("click", function () {
    var now = Date.now();
    if (now - formStats.lastClickTime < 200) formStats.rapidClicks++;
    formStats.lastClickTime = now;
  }, true);

  function getCookie(name) {
    var match = document.cookie.match(
      new RegExp("(^| )" + name + "=([^;]+)")
    );
    return match ? match[2] : null;
  }

  function setCookie(name, value, maxAge) {
    var cookie = name + "=" + value + ";path=/;max-age=" + maxAge;
    if (gdpr === "off") {
      cookie += ";SameSite=None;Secure";
    }
    document.cookie = cookie;
  }

  function decorateLinks() {
    document.addEventListener("click", function (e) {
      var link = e.target.closest("a");
      if (!link || !link.href) return;

      try {
        var linkUrl = new URL(link.href);
        var domain = linkUrl.hostname;

        if (xdSites.indexOf(domain) !== -1) {
          // Request cross-domain token
          fetch(endpoint + "/c/x", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              vid: vid,
              destination: domain,
            }),
          })
            .then(function (res) {
              return res.json();
            })
            .then(function (data) {
              if (data.token) {
                linkUrl.searchParams.set("_sabt", data.token);
                window.location.href = linkUrl.toString();
              }
            });

          e.preventDefault();
        }
      } catch (e) {}
    });
  }
})();
