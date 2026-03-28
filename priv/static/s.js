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

  // Track human interaction signals (passive, non-blocking)
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

  var browserFp = quickFingerprint();

  // GDPR-off: use cookies, fingerprint sent separately for dedup
  if (gdpr === "off") {
    vid = getCookie("_sab");
    if (!vid) {
      vid = generateId();
      setCookie("_sab", vid, 63072000);
    }
  } else {
    // GDPR-on: fingerprint IS the visitor id
    vid = browserFp;
  }

  // Clean cross-domain token from URL (only if present)
  if (window.location.search.indexOf("_sabt") !== -1) {
    try {
      var url = new URL(window.location.href);
      var xdToken = url.searchParams.get("_sabt");
      if (xdToken) {
        url.searchParams.delete("_sabt");
        window.history.replaceState({}, "", url.toString());
      }
    } catch (e) {}
  }

  // Persist UTMs in sessionStorage (GDPR-off only)
  if (gdpr === "off" && window.location.search.indexOf("utm_") !== -1) {
    var utmParams = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content"];
    utmParams.forEach(function (key) {
      try {
        var match = window.location.search.match(new RegExp("[?&]" + key + "=([^&]+)"));
        if (match) sessionStorage.setItem("_sab_" + key, decodeURIComponent(match[1]));
      } catch (e) {}
    });
  }

  // Decorate cross-domain links
  if (gdpr === "off" && xdSites.length > 0) {
    decorateLinks();
  }

  // Send initial pageview immediately (non-blocking)
  sendEvent("pageview");

  // Compute enhanced fingerprint asynchronously after first paint
  setTimeout(function () {
    var enhanced = enhancedFingerprint();
    browserFp = enhanced;
    if (gdpr !== "off") {
      // GDPR-on: fingerprint IS the vid
      if (enhanced !== vid) {
        vid = enhanced;
        sendEvent("duration");
      }
    }
  }, 50);

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
      !!navigator.webdriver ||
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
      _fp: browserFp,
    };

    if (extra) {
      if (extra.n) payload.n = extra.n;
      if (extra.p) payload.p = extra.p;
    }

    // Add UTMs from sessionStorage
    if (gdpr === "off") {
      try {
        var utms = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content"];
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

    send(endpoint + "/c/e?s=" + encodeURIComponent(site), {
      t: "duration",
      u: window.location.href,
      vid: vid,
      sid: sid,
      d: duration,
      sw: 0,
      sh: 0,
      p: {},
    });
  }

  function send(url, data) {
    var body = JSON.stringify(data);
    if (body.length > 8192) return;

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

  // ---- Fingerprinting ----

  // Quick fingerprint: runs synchronously before first beacon (~0.1ms)
  // Uses only fast, non-blocking signals
  function quickFingerprint() {
    var s = [
      navigator.userAgent,
      screen.width + "x" + screen.height,
      Intl.DateTimeFormat().resolvedOptions().timeZone || "",
      navigator.language || "",
      navigator.hardwareConcurrency || 0,
      navigator.maxTouchPoints || 0,
      new Date().getTimezoneOffset(),
    ].join("|");
    return "fp_" + murmurHash(s);
  }

  // Enhanced fingerprint: runs async after first paint (~5ms)
  // Adds canvas, WebGL, and deeper browser probing
  function enhancedFingerprint() {
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

    // Canvas fingerprint — hash pixel data directly (not toDataURL)
    try {
      var canvas = document.createElement("canvas");
      canvas.width = 120;
      canvas.height = 30;
      var ctx = canvas.getContext("2d");
      ctx.textBaseline = "top";
      ctx.font = "14px Arial";
      ctx.fillStyle = "#f60";
      ctx.fillRect(0, 0, 120, 30);
      ctx.fillStyle = "#069";
      ctx.fillText("Sptbs\ud83d\ude00", 2, 5);
      // Hash raw pixel data instead of base64 toDataURL (~100x less data)
      var pixels = ctx.getImageData(0, 0, 120, 30).data;
      var canvasHash = 0;
      for (var i = 0; i < pixels.length; i += 37) {
        canvasHash = ((canvasHash << 5) - canvasHash + pixels[i]) | 0;
      }
      signals.push("c:" + canvasHash);
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
        gl.getExtension("WEBGL_lose_context").loseContext();
      }
    } catch (e) {
      signals.push("no-webgl");
    }

    return "fp_" + murmurHash(signals.join("|||"));
  }

  // MurmurHash3 (32-bit) — fast, good distribution
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
  // Deferred to after page load to avoid any impact on initial render

  setTimeout(function () {
    var formStats = { submits: 0, pastes: 0, rapidClicks: 0, lastClickTime: 0 };

    document.addEventListener(
      "submit",
      function () {
        formStats.submits++;
        var timeSinceLoad = (Date.now() - pageStart) / 1000;
        var suspicious = timeSinceLoad < 2 || formStats.submits > 3;

        if (suspicious || formStats.pastes > 3 || formStats.rapidClicks > 10) {
          sendEvent("custom", {
            n: "_form_abuse",
            p: {
              submits: String(formStats.submits),
              pastes: String(formStats.pastes),
              rapid_clicks: String(formStats.rapidClicks),
              time_to_submit: String(Math.round(timeSinceLoad)),
              had_interaction: hadInteraction ? "1" : "0",
            },
          });
        }
      },
      true
    );

    document.addEventListener("paste", function () { formStats.pastes++; }, true);

    document.addEventListener(
      "click",
      function () {
        var now = Date.now();
        if (now - formStats.lastClickTime < 200) formStats.rapidClicks++;
        formStats.lastClickTime = now;
      },
      true
    );
  }, 100);

  // ---- Utilities ----

  function getCookie(name) {
    var match = document.cookie.match(new RegExp("(^| )" + name + "=([^;]+)"));
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
          fetch(endpoint + "/c/x", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              vid: vid,
              destination: domain,
            }),
          })
            .then(function (res) { return res.json(); })
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
