defmodule Spectabas.SEOTest do
  use ExUnit.Case, async: true

  alias Spectabas.SEO

  describe "parse_html/2" do
    test "extracts title, meta description, H1, canonical, OG tags" do
      html = """
      <html>
        <head>
          <title>Example Page</title>
          <meta name="description" content="A short description of the page.">
          <link rel="canonical" href="https://example.com/page">
          <meta property="og:title" content="OG Example">
          <meta property="og:description" content="OG description here.">
          <meta property="og:image" content="https://example.com/og.png">
          <meta name="robots" content="index,follow">
          <script type="application/ld+json">
            {"@type":"Article","headline":"hello"}
          </script>
        </head>
        <body>
          <h1>Main heading</h1>
          <p>Some content with several words here for the word counter to find.</p>
        </body>
      </html>
      """

      result = SEO.parse_html(html, "https://example.com/page")
      assert result.title == "Example Page"
      assert result.meta_description == "A short description of the page."
      assert result.h1 == "Main heading"
      assert result.h1_count == 1
      assert result.canonical == "https://example.com/page"
      assert result.og_title == "OG Example"
      assert result.og_image == "https://example.com/og.png"
      assert "Article" in result.schema_types
      assert result.meta_robots == "index,follow"
    end

    test "counts internal vs external links by host" do
      html = """
      <html><body>
        <a href="/about">About</a>
        <a href="https://example.com/contact">Contact</a>
        <a href="https://other.com/page">External</a>
        <a href="#section">Anchor</a>
      </body></html>
      """

      result = SEO.parse_html(html, "https://example.com/")
      # /about + example.com/contact = 2 internal; anchor skipped; other.com = 1 external
      assert result.internal_link_count == 2
      assert result.external_link_count == 1
    end

    test "counts images with and without alt text" do
      html = """
      <html><body>
        <img src="/a.png" alt="A">
        <img src="/b.png" alt="">
        <img src="/c.png">
        <img src="/d.png" alt="D">
      </body></html>
      """

      result = SEO.parse_html(html, "https://example.com/")
      assert result.image_count == 4
      assert result.image_alt_count == 2
    end

    test "counts multiple H1 tags" do
      html = "<html><body><h1>One</h1><h1>Two</h1></body></html>"
      result = SEO.parse_html(html, "https://example.com/")
      assert result.h1_count == 2
    end

    test "extracts schema types from @graph wrapper (Yoast/RankMath/most CMS sites)" do
      # The canonical "modern WordPress" JSON-LD pattern. Pre-v6.10.52
      # parser only checked top-level @type and missed everything inside
      # the @graph array. Real example shape from puppies.com listings.
      html = """
      <html><head>
        <script type="application/ld+json">
        {
          "@context": "https://schema.org",
          "@graph": [
            {"@type": "Product", "name": "Spruce", "offers": {"@type": "Offer", "price": "1500"}},
            {"@type": "BreadcrumbList", "itemListElement": []},
            {"@type": "WebPage", "url": "https://example.com/listings/spruce"}
          ]
        }
        </script>
      </head><body></body></html>
      """

      result = SEO.parse_html(html, "https://example.com/listings/spruce")
      assert "Product" in result.schema_types
      assert "BreadcrumbList" in result.schema_types
      assert "WebPage" in result.schema_types
      assert "Offer" in result.schema_types
    end

    test "extracts schema types from a top-level array" do
      html = """
      <html><head>
        <script type="application/ld+json">
        [{"@type": "Article"}, {"@type": "Organization"}]
        </script>
      </head><body></body></html>
      """

      result = SEO.parse_html(html, "https://example.com/")
      assert "Article" in result.schema_types
      assert "Organization" in result.schema_types
    end

    test "extracts schema types from multiple <script> blocks" do
      html = """
      <html><head>
        <script type="application/ld+json">{"@type": "Article"}</script>
        <script type="application/ld+json">{"@type": "Organization"}</script>
      </head><body></body></html>
      """

      result = SEO.parse_html(html, "https://example.com/")
      assert "Article" in result.schema_types
      assert "Organization" in result.schema_types
    end

    test "handles missing fields gracefully" do
      html = "<html><body><p>just a paragraph</p></body></html>"
      result = SEO.parse_html(html, "https://example.com/")
      assert result.title == nil
      assert result.meta_description == nil
      assert result.h1 == nil
      assert result.h1_count == 0
      assert result.canonical == nil
      assert result.og_image == nil
      assert result.schema_types == []
    end
  end

  describe "parse_and_score/3" do
    test "perfect-ish page scores high with no critical issues" do
      html = """
      <html lang="en">
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>A well-optimized page about SEO best practices and audits</title>
          <meta name="description" content="This is a meta description that is between 70 and 160 characters long for proper SEO formatting and search engine display.">
          <link rel="canonical" href="https://example.com/seo">
          <meta property="og:image" content="https://example.com/og.png">
          <script type="application/ld+json">{"@type":"Article"}</script>
        </head>
        <body>
          <h1>SEO Best Practices Guide for 2026</h1>
          <p>#{String.duplicate("word ", 200)}</p>
          <img src="/a.png" alt="A descriptive alt">
          <a href="/internal">Internal link</a>
        </body>
      </html>
      """

      attrs =
        SEO.parse_and_score(1, "https://example.com/seo", %{
          html: html,
          status_code: 200,
          response_time_ms: 800,
          final_url: "https://example.com/seo"
        })

      assert attrs.score >= 90
      items = attrs.issues["items"] || []
      refute Enum.any?(items, &(&1["severity"] == "critical"))
    end

    test "missing viewport meta is critical" do
      html = """
      <html lang="en">
        <head>
          <title>A page without a viewport tag for some reason</title>
          <meta name="description" content="A description that fits the recommended range fine for the search results display purposes.">
          <link rel="canonical" href="https://example.com/no-viewport">
        </head>
        <body><h1>Heading</h1><p>#{String.duplicate("word ", 200)}</p></body>
      </html>
      """

      attrs =
        SEO.parse_and_score(1, "https://example.com/no-viewport", %{
          html: html,
          status_code: 200,
          response_time_ms: 500,
          final_url: "https://example.com/no-viewport"
        })

      items = attrs.issues["items"]
      assert Enum.any?(items, &(&1["code"] == "missing_viewport"))
    end

    test "non-HTTPS page is critical" do
      html = """
      <html lang="en">
        <head>
          <meta name="viewport" content="width=device-width">
          <title>A page being served over HTTP for some weird reason</title>
          <meta name="description" content="A description that fits the recommended range fine for the search results display purposes.">
          <link rel="canonical" href="http://example.com/insecure">
        </head>
        <body><h1>Heading</h1><p>#{String.duplicate("word ", 200)}</p></body>
      </html>
      """

      attrs =
        SEO.parse_and_score(1, "http://example.com/insecure", %{
          html: html,
          status_code: 200,
          response_time_ms: 500,
          final_url: "http://example.com/insecure"
        })

      items = attrs.issues["items"]
      assert Enum.any?(items, &(&1["code"] == "no_https"))
    end

    test "LCP > 4s is major, between 2.5s and 4s is minor" do
      html = """
      <html lang="en">
        <head>
          <meta name="viewport" content="width=device-width">
          <title>Slow page with a properly-sized title and meta description</title>
          <meta name="description" content="A description that fits the recommended range fine for the search results display purposes today.">
          <link rel="canonical" href="https://example.com/slow-lcp">
        </head>
        <body><h1>Slow</h1><p>#{String.duplicate("word ", 200)}</p></body>
      </html>
      """

      slow = %{
        html: html,
        status_code: 200,
        response_time_ms: 500,
        final_url: "https://example.com/slow-lcp",
        performance: %{"lcp_ms" => 5200, "nav" => %{}, "paint" => %{}, "resources" => []}
      }

      attrs = SEO.parse_and_score(1, "https://example.com/slow-lcp", slow)
      items = attrs.issues["items"]
      assert Enum.any?(items, &(&1["code"] == "poor_lcp"))

      ok = put_in(slow, [:performance, "lcp_ms"], 3200)
      attrs2 = SEO.parse_and_score(1, "https://example.com/slow-lcp", ok)
      items2 = attrs2.issues["items"]
      assert Enum.any?(items2, &(&1["code"] == "needs_improvement_lcp"))
    end

    test "missing title is critical, missing meta is major" do
      html = """
      <html>
        <head><link rel="canonical" href="https://example.com/"></head>
        <body><h1>Heading</h1><p>#{String.duplicate("word ", 200)}</p></body>
      </html>
      """

      attrs =
        SEO.parse_and_score(1, "https://example.com/", %{
          html: html,
          status_code: 200,
          response_time_ms: 500,
          final_url: "https://example.com/"
        })

      items = attrs.issues["items"]
      assert Enum.any?(items, &(&1["code"] == "missing_title"))
      assert Enum.any?(items, &(&1["code"] == "missing_meta_description"))

      assert Enum.find(items, &(&1["code"] == "missing_title"))["severity"] == "critical"
      assert Enum.find(items, &(&1["code"] == "missing_meta_description"))["severity"] == "major"
    end

    test "fetch failure produces a critical issue and score 0" do
      attrs =
        SEO.parse_and_score(1, "https://example.com/", %{
          error: "Headless fetch failed: timeout",
          response_time_ms: 35_000,
          status_code: nil
        })

      assert attrs.score == 0
      items = attrs.issues["items"]
      assert Enum.any?(items, &(&1["code"] == "fetch_failed"))
    end

    test "noindex meta is critical" do
      html = """
      <html>
        <head>
          <title>A page that's been blocked</title>
          <meta name="description" content="A description that fits the recommended range fine for the search results display.">
          <meta name="robots" content="noindex,nofollow">
          <link rel="canonical" href="https://example.com/blocked">
        </head>
        <body><h1>Blocked</h1></body>
      </html>
      """

      attrs =
        SEO.parse_and_score(1, "https://example.com/blocked", %{
          html: html,
          status_code: 200,
          response_time_ms: 500
        })

      items = attrs.issues["items"]
      assert Enum.any?(items, &(&1["code"] == "noindex"))
    end

    test "slow response time triggers major issue" do
      html = """
      <html>
        <head>
          <title>A regular page that happens to be slow to respond</title>
          <meta name="description" content="A description that fits the recommended range fine for the search results display purposes.">
          <link rel="canonical" href="https://example.com/slow">
        </head>
        <body><h1>Slow page</h1></body>
      </html>
      """

      attrs =
        SEO.parse_and_score(1, "https://example.com/slow", %{
          html: html,
          status_code: 200,
          response_time_ms: 4500
        })

      items = attrs.issues["items"]
      assert Enum.any?(items, &(&1["code"] == "slow_response"))
    end
  end
end
