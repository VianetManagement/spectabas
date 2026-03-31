(function () {
  "use strict";

  var script = document.currentScript;
  if (!script) return;

  var site = script.getAttribute("data-id");
  if (!site) return;

  var gdpr = script.getAttribute("data-gdpr") || "off";
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

  // Single consistent fingerprint — no two-phase to avoid split visitor IDs
  var browserFp = enhancedFingerprint();

  if (gdpr === "off") {
    vid = getCookie("_sab");
    if (!vid) {
      // Try to set a cookie
      var newId = generateId();
      setCookie("_sab", newId, 63072000);

      // Verify cookie actually persisted (may be blocked by browser/extension)
      vid = getCookie("_sab");
      if (!vid) {
        // Cookies blocked — fall back to fingerprint (same as GDPR-on behavior)
        // This ensures the same visitor gets the same ID across page loads
        vid = browserFp;
      }
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

  // Rate-limited pageview sending — prevents overcounting from rapid refreshes,
  // auto-refresh, or iframes reloading. Max 1 pageview per pathname per 5 seconds.
  // Uses pathname (not full URL) so query-string changes on the same page
  // (e.g. search filters, pagination) don't each count as a separate pageview.
  var lastSentUrl = window.location.href;
  var pvMinInterval = 5000;

  function sendPageview() {
    var url = window.location.href;
    var now = Date.now();
    try {
      var key = "_sab_pv_" + window.location.pathname;
      var lastSent = parseInt(sessionStorage.getItem(key) || "0", 10);
      if (now - lastSent < pvMinInterval) return;
      sessionStorage.setItem(key, String(now));
    } catch (e) {}
    lastSentUrl = url;
    sendEvent("pageview");
  }

  sendPageview();

  // SPA support — only fire pageview if pathname changed (not just query string).
  // Query-string-only changes (search filters, pagination, sorting) are not
  // separate pageviews — they're interactions on the same page.
  var lastSentPath = window.location.pathname;
  var origPushState = history.pushState;
  history.pushState = function () {
    origPushState.apply(this, arguments);
    if (window.location.pathname !== lastSentPath) {
      sendDuration();
      pageStart = Date.now();
      lastSentPath = window.location.pathname;
      sendPageview();
    }
  };

  window.addEventListener("popstate", function () {
    if (window.location.pathname !== lastSentPath) {
      sendDuration();
      pageStart = Date.now();
      lastSentPath = window.location.pathname;
      sendPageview();
    }
  });

  // Track foreground time, not wall-clock time
  var foregroundStart = Date.now();
  var accumulatedForeground = 0;

  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState === "hidden") {
      // Accumulate foreground time and send duration
      accumulatedForeground += Date.now() - foregroundStart;
      sendDuration();
    } else {
      // Resuming foreground — reset the timer
      foregroundStart = Date.now();
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
    // Use accumulated foreground time, not wall-clock time
    var currentForeground = document.visibilityState === "visible" ? Date.now() - foregroundStart : 0;
    var duration = Math.round((accumulatedForeground + currentForeground) / 1000);
    if (duration < 1) return;
    // Reset for next SPA page
    accumulatedForeground = 0;
    foregroundStart = Date.now();

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

  // Browser fingerprint: canvas + WebGL + navigator signals (~3-5ms)
  // Single consistent fingerprint used for both GDPR-on vid and dedup
  function enhancedFingerprint() {
    // Use browser family + major version instead of full UA string for stability.
    // Full UA changes on every minor browser update, causing fingerprint rotation.
    var uaBrowser = (function () {
      var ua = navigator.userAgent;
      var m = ua.match(/(Chrome|Firefox|Safari|Edge|Opera|MSIE|Trident)[\/ ]([\d]+)/);
      return m ? m[1] + m[2] : "other";
    })();

    var signals = [
      navigator.userAgent,
      uaBrowser,
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

    // 64-bit hash (two 32-bit hashes with different seeds) — collision probability
    // drops from ~50% at 77K visitors (32-bit) to ~50% at 5 billion (64-bit)
    var input = signals.join("|||");
    return "fp_" + murmurHash(input, 0x12345678) + murmurHash(input, 0x9e3779b9);
  }

  // MurmurHash3 (32-bit) — fast, good distribution. Seeded for 64-bit output.
  function murmurHash(str, seed) {
    var h = seed || 0x12345678;
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

  // ---- Outbound Link & File Download Tracking ----
  // Intercepts clicks on <a> elements to auto-track external links and file downloads

  document.addEventListener("click", function(e) {
    var link = e.target.closest("a");
    if (!link || !link.href) return;
    try {
      var url = new URL(link.href);
      if (url.protocol.indexOf("http") !== 0) return;

      // Outbound link tracking
      if (url.hostname && url.hostname !== window.location.hostname) {
        sendEvent("custom", { n: "_outbound", p: { url: link.href, domain: url.hostname } });
      }

      // File download tracking
      var downloadExts = /\.(pdf|zip|doc|docx|xls|xlsx|csv|mp3|mp4|avi|mov|dmg|exe|iso)$/i;
      if (downloadExts.test(url.pathname)) {
        sendEvent("custom", { n: "_download", p: { url: link.href, filename: url.pathname.split("/").pop() } });
      }
    } catch(e) {}
  }, true);

  // ---- Real User Monitoring ----
  // Collects Core Web Vitals + page load timing after page is fully loaded.
  // Uses requestIdleCallback to avoid any impact on user experience.

  var rumSent = false;

  function collectRUM(force) {
    if (rumSent) return;

    var perf = {};
    var hasPageLoad = false;

    // Navigation timing — try PerformanceNavigationTiming first, fall back to performance.timing
    try {
      var nav = performance.getEntriesByType("navigation")[0];
      if (nav) {
        // PerformanceNavigationTiming uses startTime (always 0) not navigationStart
        // navigationStart only exists on the deprecated performance.timing object
        var navStart = nav.startTime || 0;
        perf.dns = Math.round(nav.domainLookupEnd - nav.domainLookupStart);
        perf.tcp = Math.round(nav.connectEnd - nav.connectStart);
        perf.tls = nav.secureConnectionStart > 0 ? Math.round(nav.connectEnd - nav.secureConnectionStart) : 0;
        perf.ttfb = Math.round(nav.responseStart - nav.requestStart);
        perf.download = Math.round(nav.responseEnd - nav.responseStart);
        if (nav.domInteractive > 0) perf.dom_interactive = Math.round(nav.domInteractive - navStart);
        if (nav.domContentLoadedEventEnd > 0) perf.dom_complete = Math.round(nav.domContentLoadedEventEnd - navStart);
        if (nav.loadEventEnd > 0) {
          perf.page_load = Math.round(nav.loadEventEnd - navStart);
          hasPageLoad = true;
        }
        perf.transfer_size = nav.transferSize || 0;
        perf.dom_size = document.getElementsByTagName("*").length;
      } else if (performance.timing) {
        var t = performance.timing;
        if (t.requestStart > 0) perf.ttfb = Math.round(t.responseStart - t.requestStart);
        if (t.domInteractive > 0) perf.dom_interactive = Math.round(t.domInteractive - t.navigationStart);
        if (t.domContentLoadedEventEnd > 0) perf.dom_complete = Math.round(t.domContentLoadedEventEnd - t.navigationStart);
        if (t.loadEventEnd > 0) {
          perf.page_load = Math.round(t.loadEventEnd - t.navigationStart);
          hasPageLoad = true;
        }
        perf.dom_size = document.getElementsByTagName("*").length;
      }
    } catch (e) {}

    // First Contentful Paint
    try {
      var paints = performance.getEntriesByType("paint");
      for (var i = 0; i < paints.length; i++) {
        if (paints[i].name === "first-contentful-paint") {
          perf.fcp = Math.round(paints[i].startTime);
        }
      }
    } catch (e) {}

    // Wait for page_load if possible — send early only if forced (timeout/visibilitychange)
    if (perf.ttfb && perf.ttfb > 0 && (hasPageLoad || force)) {
      rumSent = true;
      sendEvent("custom", { n: "_rum", p: mapToStrings(perf) });
    }
  }

  // Collect Core Web Vitals via PerformanceObserver (LCP, CLS, FID)
  var cwv = {};
  var cwvSent = false;

  try {
    // Largest Contentful Paint
    new PerformanceObserver(function (list) {
      var entries = list.getEntries();
      if (entries.length > 0) {
        cwv.lcp = Math.round(entries[entries.length - 1].startTime);
      }
    }).observe({ type: "largest-contentful-paint", buffered: true });

    // Cumulative Layout Shift — session window method per Google's web-vitals spec:
    // max session window with 1s gap, capped at 5s duration
    var clsSessionValue = 0;
    var clsSessionEntries = [];
    var clsMaxSessionValue = 0;

    new PerformanceObserver(function (list) {
      var entries = list.getEntries();
      for (var i = 0; i < entries.length; i++) {
        if (!entries[i].hadRecentInput) {
          var entry = entries[i];

          // Start new session if gap > 1s or session > 5s
          if (clsSessionEntries.length > 0) {
            var lastEntry = clsSessionEntries[clsSessionEntries.length - 1];
            var gap = entry.startTime - lastEntry.startTime - lastEntry.duration;
            var sessionDuration = entry.startTime - clsSessionEntries[0].startTime;

            if (gap > 1000 || sessionDuration > 5000) {
              clsSessionValue = 0;
              clsSessionEntries = [];
            }
          }

          clsSessionEntries.push(entry);
          clsSessionValue += entry.value;

          if (clsSessionValue > clsMaxSessionValue) {
            clsMaxSessionValue = clsSessionValue;
          }
        }
      }
      cwv.cls = Math.round(clsMaxSessionValue * 1000) / 1000;
    }).observe({ type: "layout-shift", buffered: true });

    // First Input Delay
    new PerformanceObserver(function (list) {
      var entries = list.getEntries();
      if (entries.length > 0) {
        cwv.fid = Math.round(entries[0].processingStart - entries[0].startTime);
      }
    }).observe({ type: "first-input", buffered: true });
  } catch (e) {}

  function sendCWV() {
    if (cwvSent || !cwv.lcp) return;
    cwvSent = true;
    sendEvent("custom", { n: "_cwv", p: mapToStrings(cwv) });
  }

  // RUM scheduling: event-driven, no polling.
  // Primary trigger: load event (when loadEventEnd is guaranteed ready).
  // Safety net: visibilitychange (visitor leaves before load fires).
  // Final fallback: 30s timeout (in case load event never fires).
  // This eliminates the race condition where early force-sends at 10s
  // block later complete sends when load fires at 12-20s on heavy pages.

  window.addEventListener("load", function () {
    // After load fires, wait 500ms for loadEventEnd to populate in the
    // PerformanceNavigationTiming entry, then collect complete metrics.
    setTimeout(function () { collectRUM(false); }, 500);
  });

  // Safety net: if visitor leaves before load fires, force-send whatever we have
  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState === "hidden") {
      collectRUM(true);
      sendCWV();
    }
  });

  // Final fallback: 30s timeout force-sends (covers edge cases where
  // load event never fires, e.g. streaming pages, broken resources)
  setTimeout(function () { collectRUM(true); }, 30000);

  // CWV: try at 5s and 10s
  setTimeout(sendCWV, 5000);
  setTimeout(sendCWV, 10000);

  function mapToStrings(obj) {
    var result = {};
    for (var k in obj) {
      if (obj.hasOwnProperty(k)) {
        var v = obj[k];
        // Skip NaN/undefined/null values — they'd become "NaN"/"undefined"/"null" strings
        // which ClickHouse's toFloat64OrZero converts to 0 anyway
        if (v !== null && v !== undefined && v === v) {  // v === v is false for NaN
          result[k] = String(v);
        }
      }
    }
    return result;
  }

  // ---- Utilities ----

  function getCookie(name) {
    var match = document.cookie.match(new RegExp("(^| )" + name + "=([^;]+)"));
    return match ? match[2] : null;
  }

  function setCookie(name, value, maxAge) {
    var cookie = name + "=" + value + ";path=/;max-age=" + maxAge + ";SameSite=Lax";
    if (window.location.protocol === "https:") {
      cookie += ";Secure";
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
