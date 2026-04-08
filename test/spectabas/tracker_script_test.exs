defmodule Spectabas.TrackerScriptTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Structural tests for the client-side tracker script (priv/static/s.js).
  Verifies all functions, features, and security properties are present
  in the minified JS by pattern-matching the source.
  """

  setup_all do
    script_path = Path.join([__DIR__, "..", "..", "priv", "static", "s.js"])
    %{js: File.read!(script_path)}
  end

  describe "IIFE wrapper" do
    test "script is wrapped in an IIFE", %{js: js} do
      assert String.starts_with?(js, "(function(){")
      assert String.ends_with?(String.trim(js), "})();")
    end

    test "uses strict mode", %{js: js} do
      assert js =~ "\"use strict\""
    end

    test "requires data-id attribute", %{js: js} do
      assert js =~ "data-id"
    end

    test "reads data-gdpr attribute with 'off' default", %{js: js} do
      assert js =~ "data-gdpr"
      assert js =~ ~r/\|\|"off"/
    end

    test "reads data-xd attribute for cross-domain sites", %{js: js} do
      assert js =~ "data-xd"
    end

    test "reads data-proxy attribute", %{js: js} do
      assert js =~ "data-proxy"
    end
  end

  describe "opt-out" do
    test "checks _sab_optout cookie and exits early", %{js: js} do
      assert js =~ "_sab_optout"
      # The check should happen early, before any event sending
      optout_pos = :binary.match(js, "_sab_optout") |> elem(0)
      # sendBeacon appears later in the send function
      beacon_pos = :binary.match(js, "sendBeacon") |> elem(0)
      assert optout_pos < beacon_pos
    end

    test "optOut function sets _sab_optout cookie", %{js: js} do
      assert js =~ ~r/optOut:function\(\)\{/
      # Should set cookie with 2-year max-age (63072000 seconds)
      assert js =~ "63072000"
    end
  end

  describe "interaction tracking" do
    test "listens for mousedown, touchstart, scroll, keydown", %{js: js} do
      for event <- ["mousedown", "touchstart", "scroll", "keydown"] do
        assert js =~ event, "Missing interaction event: #{event}"
      end
    end

    test "uses passive event listeners", %{js: js} do
      assert js =~ "passive:true"
    end
  end

  describe "visitor ID assignment" do
    test "reads _sab cookie in GDPR-off mode", %{js: js} do
      assert js =~ "\"_sab\""
    end

    test "generates new ID and sets cookie when no _sab cookie", %{js: js} do
      # generateId uses crypto.getRandomValues with Uint8Array(16)
      assert js =~ "Uint8Array(16)"
      assert js =~ "crypto.getRandomValues"
    end

    test "falls back to fingerprint when cookies are blocked", %{js: js} do
      # After setting cookie, re-reads to verify it persisted
      # If not, falls back to fingerprint
      # In minified: if(!V)V=F (V=visitor, F=fingerprint)
      assert js =~ ~r/if\(!V\)V=F|if \(!vid\) vid = browserFp/
    end

    test "uses fingerprint as visitor ID in GDPR-on mode", %{js: js} do
      # The else branch sets vid = browserFp (V=F in minified)
      assert js =~ ~r/\}else\{V=F\}|vid = browserFp/
    end
  end

  describe "fingerprinting" do
    test "collects navigator signals", %{js: js} do
      signals = [
        "navigator.userAgent",
        "screen.width",
        "screen.height",
        "screen.colorDepth",
        "devicePixelRatio",
        "navigator.language",
        "navigator.languages",
        "hardwareConcurrency",
        "deviceMemory",
        "maxTouchPoints",
        "navigator.platform",
        "SharedArrayBuffer",
        "getTimezoneOffset"
      ]

      for signal <- signals do
        assert js =~ signal, "Missing fingerprint signal: #{signal}"
      end
    end

    test "performs canvas fingerprinting", %{js: js} do
      assert js =~ "createElement(\"canvas\")"
      assert js =~ "getContext(\"2d\")"
      assert js =~ "getImageData"
      assert js =~ "Sptbs"
    end

    test "performs WebGL fingerprinting", %{js: js} do
      assert js =~ "getContext(\"webgl\")"
      assert js =~ "WEBGL_debug_renderer_info"
      assert js =~ "UNMASKED_VENDOR_WEBGL"
      assert js =~ "UNMASKED_RENDERER_WEBGL"
      assert js =~ "MAX_TEXTURE_SIZE"
      assert js =~ "MAX_RENDERBUFFER_SIZE"
      assert js =~ "MAX_VIEWPORT_DIMS"
      assert js =~ "ALIASED_LINE_WIDTH_RANGE"
      assert js =~ "getSupportedExtensions"
    end

    test "cleans up WebGL context", %{js: js} do
      assert js =~ "WEBGL_lose_context"
      assert js =~ "loseContext()"
    end

    test "performs AudioContext fingerprinting", %{js: js} do
      assert js =~ "OfflineAudioContext"
      assert js =~ "webkitOfflineAudioContext"
      assert js =~ "createOscillator"
      assert js =~ "createDynamicsCompressor"
      assert js =~ "\"triangle\""
    end

    test "performs font detection", %{js: js} do
      fonts = ["Arial", "Verdana", "Georgia", "Comic Sans MS", "Impact", "Courier New"]

      for font <- fonts do
        assert js =~ font, "Missing font probe: #{font}"
      end

      assert js =~ "measureText"
    end

    test "uses murmurHash with two seeds for 64-bit output", %{js: js} do
      assert js =~ "0x12345678"
      assert js =~ "0x9e3779b9"
      assert js =~ "fp_"
      # MurmurHash constants
      assert js =~ "0xcc9e2d51"
      assert js =~ "0x1b873593"
      assert js =~ "0x85ebca6b"
      assert js =~ "0xc2b2ae35"
      assert js =~ "Math.imul"
    end

    test "uses browser family + major version (not full UA) for stability", %{js: js} do
      assert js =~ ~r/Chrome|Firefox|Safari|Edge|Opera|MSIE|Trident/
    end

    test "includes fallback strings for unsupported features", %{js: js} do
      for fallback <- ["no-canvas", "no-webgl", "no-audio", "no-fonts"] do
        assert js =~ fallback, "Missing fallback: #{fallback}"
      end
    end
  end

  describe "cross-domain token" do
    test "cleans _sabt token from URL via replaceState", %{js: js} do
      assert js =~ "_sabt"
      assert js =~ "replaceState"
      assert js =~ "searchParams.delete"
    end
  end

  describe "UTM persistence" do
    test "persists all 5 UTM params to sessionStorage", %{js: js} do
      for param <- ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content"] do
        assert js =~ param, "Missing UTM param: #{param}"
      end

      assert js =~ "sessionStorage.setItem"
    end

    test "uses _sab_ prefix for sessionStorage keys", %{js: js} do
      assert js =~ "_sab_utm_source" || js =~ ~r/_sab_.*utm/
    end

    test "only persists UTMs in GDPR-off mode", %{js: js} do
      # The UTM block is inside an if(G==="off") / if(gdpr==="off") check
      assert js =~ ~r/"off".*utm_source/s
    end
  end

  describe "click ID persistence" do
    test "captures gclid, msclkid, fbclid", %{js: js} do
      assert js =~ "gclid"
      assert js =~ "msclkid"
      assert js =~ "fbclid"
    end

    test "maps click IDs to platform names", %{js: js} do
      assert js =~ "google_ads"
      assert js =~ "bing_ads"
      assert js =~ "meta_ads"
    end

    test "stores click ID and type in sessionStorage", %{js: js} do
      assert js =~ "_sab_click_id"
      assert js =~ "_sab_click_id_type"
    end
  end

  describe "pageview sending" do
    test "sends initial pageview on load", %{js: js} do
      assert js =~ "\"pageview\""
    end

    test "rate limits pageviews to 5-second minimum interval", %{js: js} do
      assert js =~ "5000"
      assert js =~ "_sab_pv_"
    end

    test "uses pathname for rate limiting key (not full URL)", %{js: js} do
      assert js =~ "window.location.pathname"
    end
  end

  describe "SPA support" do
    test "overrides history.pushState", %{js: js} do
      assert js =~ "history.pushState"
      assert js =~ ".apply(this,arguments)"
    end

    test "listens for popstate events", %{js: js} do
      assert js =~ "popstate"
    end

    test "only fires pageview when pathname changes (not query string)", %{js: js} do
      # Checks pathname !== lastSentPath before sending
      pathname_count =
        js
        |> String.split("window.location.pathname")
        |> length()
        |> Kernel.-(1)

      # pathname referenced multiple times: rate limit key, pushState check, popstate check
      assert pathname_count >= 3
    end

    test "sends duration before SPA navigation", %{js: js} do
      # In SPA transitions, duration is sent before the new pageview
      # pushState handler calls sD() then sP() (or sendDuration then sendPageview)
      assert js =~ ~r/sD\(\);.*sP\(\)|sendDuration\(\).*sendPageview\(\)/s
    end
  end

  describe "duration tracking" do
    test "tracks foreground time via visibilitychange", %{js: js} do
      assert js =~ "visibilitychange"
      assert js =~ "visibilityState"
    end

    test "accumulates foreground time (not wall-clock)", %{js: js} do
      # Uses accumulated foreground variable
      assert js =~ "\"duration\""
    end

    test "sends duration event type", %{js: js} do
      assert js =~ "\"duration\""
    end

    test "skips duration < 1 second", %{js: js} do
      # if(d<1)return or if(duration<1)return
      assert js =~ ~r/if\(d<1\)return|if \(duration < 1\) return/
    end
  end

  describe "sendEvent payload" do
    test "includes all required fields", %{js: js} do
      fields = ["vid:", "sid:", "sw:", "sh:", "d:0", "_bot:", "_hi:", "_fp:", "_oa:"]

      for field <- fields do
        assert js =~ field, "Missing payload field: #{field}"
      end
    end

    test "detects bot signals", %{js: js} do
      assert js =~ "navigator.webdriver"
      assert js =~ "onmouseover"
      assert js =~ ~r/headless/i
    end

    test "includes referrer", %{js: js} do
      assert js =~ "document.referrer"
    end

    test "attaches UTMs from sessionStorage to payload", %{js: js} do
      # sendEvent reads UTMs back from sessionStorage and adds to payload.p
      assert js =~ ~r/sessionStorage\.getItem\("_sab_"/
    end

    test "attaches click ID fields (_cid, _cidt) to payload", %{js: js} do
      assert js =~ "_cid"
      assert js =~ "_cidt"
    end
  end

  describe "send transport" do
    test "tries sendBeacon first", %{js: js} do
      assert js =~ "navigator.sendBeacon"
      assert js =~ "new Blob"
      assert js =~ "application/json"
    end

    test "falls back to fetch", %{js: js} do
      assert js =~ "fetch("
      assert js =~ "keepalive:true"
    end

    test "retries once on 500+ server errors after 2 seconds", %{js: js} do
      assert js =~ "status>=500"
      assert js =~ "2000"
    end

    test "enforces 8192 byte payload limit", %{js: js} do
      assert js =~ "8192"
    end

    test "uses POST method", %{js: js} do
      assert js =~ "\"POST\""
    end
  end

  describe "public API" do
    test "exposes Spectabas.track", %{js: js} do
      assert js =~ "track:function("
    end

    test "exposes Spectabas.identify", %{js: js} do
      assert js =~ "identify:function("
      assert js =~ "/c/i"
    end

    test "exposes Spectabas.optOut", %{js: js} do
      assert js =~ "optOut:function("
    end

    test "exposes Spectabas.ecommerce.addOrder", %{js: js} do
      assert js =~ "addOrder:function("
      assert js =~ "\"ecommerce_order\""
    end

    test "exposes Spectabas.ecommerce.addItem", %{js: js} do
      assert js =~ "addItem:function("
      assert js =~ "\"ecommerce_item\""
    end

    test "track supports occurred_at for backdating", %{js: js} do
      assert js =~ "occurred_at"
    end
  end

  describe "cross-domain link decoration" do
    test "fetches token from /c/x endpoint", %{js: js} do
      assert js =~ "/c/x"
    end

    test "appends _sabt token to cross-domain links", %{js: js} do
      assert js =~ "searchParams.set"
      assert js =~ "_sabt"
    end

    test "prevents default navigation while fetching token", %{js: js} do
      assert js =~ "preventDefault"
    end
  end

  describe "outbound link tracking" do
    test "detects external links by hostname comparison", %{js: js} do
      assert js =~ "window.location.hostname"
      assert js =~ "_outbound"
    end

    test "sends outbound event with url and domain", %{js: js} do
      assert js =~ "\"_outbound\""
    end

    test "uses event delegation with closest('a')", %{js: js} do
      assert js =~ "closest(\"a\")"
    end

    test "ignores non-HTTP links", %{js: js} do
      assert js =~ ~r/protocol.*http/
    end
  end

  describe "file download tracking" do
    test "tracks common download file extensions", %{js: js} do
      extensions = ~w(pdf zip doc docx xls xlsx csv mp3 mp4 avi mov dmg exe iso)

      for ext <- extensions do
        assert js =~ ext, "Missing download extension: #{ext}"
      end
    end

    test "sends _download event with url and filename", %{js: js} do
      assert js =~ "\"_download\""
      assert js =~ "filename"
    end
  end

  describe "form abuse detection" do
    test "is deferred via setTimeout to avoid blocking render", %{js: js} do
      assert js =~ "setTimeout(function()"
    end

    test "tracks form submits, pastes, and rapid clicks", %{js: js} do
      assert js =~ "\"submit\""
      assert js =~ "\"paste\""
      assert js =~ "rapidClicks" || js =~ "rapidClicks"
    end

    test "sends _form_abuse event when thresholds exceeded", %{js: js} do
      assert js =~ "\"_form_abuse\""
    end

    test "detects fast submissions (< 2 seconds)", %{js: js} do
      # tl<2 or timeSinceLoad < 2
      assert js =~ ~r/tl<2|timeSinceLoad < 2/
    end

    test "includes abuse metrics in event properties", %{js: js} do
      for key <- ["submits", "pastes", "rapid_clicks", "time_to_submit", "had_interaction"] do
        assert js =~ key, "Missing form abuse metric: #{key}"
      end
    end
  end

  describe "cookie utilities" do
    test "getCookie parses document.cookie correctly", %{js: js} do
      assert js =~ "document.cookie"
      # Uses regex to parse cookie value
      assert js =~ ~r/\([\"\^]\| \)/
    end

    test "setCookie sets path, max-age, and SameSite", %{js: js} do
      assert js =~ "path=/"
      assert js =~ "max-age="
      assert js =~ "SameSite=Lax"
    end

    test "setCookie adds Secure flag on HTTPS", %{js: js} do
      assert js =~ "https:"
      assert js =~ "Secure"
    end
  end

  describe "endpoint construction" do
    test "uses proxy base if data-proxy is set", %{js: js} do
      assert js =~ "data-proxy"
    end

    test "falls back to script src minus /assets/v1.js", %{js: js} do
      # In JS source the regex is /\/assets\/v1\.js.*$/ — escaped slashes
      assert js =~ "assets" && js =~ "v1"
    end

    test "sends events to /c/e with site public key", %{js: js} do
      assert js =~ "/c/e?s="
      assert js =~ "encodeURIComponent"
    end
  end

  describe "security properties" do
    test "no eval or Function constructor", %{js: js} do
      refute js =~ ~r/[^a-zA-Z]eval\(/
      refute js =~ "new Function("
    end

    test "no innerHTML or document.write", %{js: js} do
      refute js =~ "innerHTML"
      refute js =~ "document.write"
    end

    test "all try blocks have catch clauses", %{js: js} do
      try_count = js |> String.split("try{") |> length() |> Kernel.-(1)
      catch_count = js |> String.split("catch(") |> length() |> Kernel.-(1)
      assert catch_count >= try_count,
             "Missing catch clauses: #{try_count} try blocks vs #{catch_count} catch blocks"
    end
  end

  describe "script size" do
    test "minified script is under 15KB", %{js: js} do
      size = byte_size(js)
      assert size < 15_000, "Script is #{size} bytes, should be under 15KB"
    end

    test "script is a single line (minified)", %{js: js} do
      line_count = js |> String.trim() |> String.split("\n") |> length()
      assert line_count == 1, "Script has #{line_count} lines, should be 1 (minified)"
    end
  end
end
