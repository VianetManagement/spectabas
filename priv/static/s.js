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

  function fingerprint() {
    var data = [
      navigator.userAgent,
      screen.width + "x" + screen.height,
      Intl.DateTimeFormat().resolvedOptions().timeZone || "",
      navigator.language || "",
    ].join("|");

    // Simple hash
    var hash = 0;
    for (var i = 0; i < data.length; i++) {
      var chr = data.charCodeAt(i);
      hash = (hash << 5) - hash + chr;
      hash |= 0;
    }
    return "fp_" + Math.abs(hash).toString(36);
  }

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
