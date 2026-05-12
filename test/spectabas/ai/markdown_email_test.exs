defmodule Spectabas.AI.MarkdownEmailTest do
  use ExUnit.Case, async: true

  alias Spectabas.AI.MarkdownEmail

  defp render(md), do: MarkdownEmail.render(md)
  defp contains?(html, snippet), do: String.contains?(html, snippet)

  describe "headers" do
    test "h1 through h6" do
      for n <- 1..6 do
        prefix = String.duplicate("#", n)
        html = render("#{prefix} Heading #{n}")
        assert contains?(html, "<h#{n}")
        assert contains?(html, "Heading #{n}</h#{n}>")
      end
    end

    test "h2 gets the divider border" do
      html = render("## Subhead")
      assert contains?(html, "border-bottom:1px solid #e5e7eb")
    end

    test "inline formatting works inside headers" do
      html = render("## Bold **here**")
      assert contains?(html, "Bold <strong>here</strong>")
    end
  end

  describe "bold" do
    test "double-star renders as <strong>" do
      assert contains?(render("**hi**"), "<strong>hi</strong>")
    end

    test "double-underscore renders as <strong>" do
      assert contains?(render("__hi__"), "<strong>hi</strong>")
    end

    test "preserves surrounding text" do
      assert contains?(render("the **fox** runs"), "the <strong>fox</strong> runs")
    end
  end

  describe "italic" do
    test "single-star renders as <em>" do
      assert contains?(render("*hi*"), "<em>hi</em>")
    end

    test "single-underscore renders as <em>" do
      assert contains?(render("_hi_"), "<em>hi</em>")
    end

    test "doesn't grab bold markers" do
      html = render("**bold** and *italic*")
      assert contains?(html, "<strong>bold</strong>")
      assert contains?(html, "<em>italic</em>")
    end
  end

  describe "strikethrough" do
    test "tilde-tilde renders as <del>" do
      assert contains?(render("~~old~~"), "<del>old</del>")
    end
  end

  describe "inline code" do
    test "backtick spans render as <code>" do
      html = render("the `foo` var")
      assert contains?(html, "<code")
      assert contains?(html, ">foo</code>")
    end

    test "asterisks inside code aren't transformed" do
      html = render("`*not italic*`")
      # Code content stays literal — not wrapped in <em>
      assert contains?(html, ">*not italic*</code>")
      refute contains?(html, "<em>not italic</em>")
    end

    test "double asterisks inside code aren't bolded" do
      html = render("`**not bold**`")
      assert contains?(html, ">**not bold**</code>")
      refute contains?(html, "<strong>not bold</strong>")
    end
  end

  describe "fenced code blocks" do
    test "triple backticks wrap content in <pre>" do
      md = """
      ```
      foo()
      bar()
      ```
      """

      html = render(md)
      assert contains?(html, "<pre")
      assert contains?(html, "foo()")
      assert contains?(html, "bar()")
      assert contains?(html, "</pre>")
    end

    test "html chars inside code blocks are escaped" do
      md = "```\n<script>alert(1)</script>\n```"
      html = render(md)
      assert contains?(html, "&lt;script&gt;")
      refute contains?(html, "<script>alert(1)</script>")
    end
  end

  describe "links" do
    test "https link renders as <a>" do
      html = render("see [docs](https://example.com)")
      assert contains?(html, ~s(<a href="https://example.com"))
      assert contains?(html, ">docs</a>")
    end

    test "http link works" do
      html = render("[x](http://example.com)")
      assert contains?(html, ~s(<a href="http://example.com"))
    end

    test "mailto link works" do
      html = render("[email me](mailto:foo@example.com)")
      assert contains?(html, ~s(<a href="mailto:foo@example.com"))
    end

    test "non-http schemes render verbatim (no js: smuggling)" do
      html = render("[click](javascript:alert(1))")
      refute contains?(html, "<a href=")
      assert contains?(html, "[click](javascript:alert(1))")
    end

    test "bold inside link label works" do
      html = render("[**bold link**](https://example.com)")
      assert contains?(html, ~s(<a href="https://example.com"))
      assert contains?(html, "<strong>bold link</strong>")
    end
  end

  describe "bullet lists" do
    test "hyphen prefix renders as bullet" do
      html = render("- first\n- second")
      assert contains?(html, "&bull; first")
      assert contains?(html, "&bull; second")
    end

    test "asterisk prefix also renders as bullet" do
      html = render("* item")
      assert contains?(html, "&bull; item")
    end

    test "inline formatting works in bullets" do
      html = render("- **important** thing")
      assert contains?(html, "&bull; <strong>important</strong> thing")
    end
  end

  describe "numbered lists" do
    test "renders with bolded N. prefix" do
      html = render("1. first item")
      assert contains?(html, "<strong>1.</strong>")
      assert contains?(html, "first item")
    end

    test "multi-digit numbers work" do
      html = render("12. twelfth")
      assert contains?(html, "<strong>12.</strong>")
    end
  end

  describe "blockquotes" do
    test "> prefix renders as <blockquote>" do
      html = render("> quoted text")
      assert contains?(html, "<blockquote")
      assert contains?(html, "quoted text</blockquote>")
    end

    test "inline formatting works in blockquotes" do
      html = render("> **strong** note")
      assert contains?(html, "<strong>strong</strong>")
    end
  end

  describe "horizontal rules" do
    test "--- renders as <hr>" do
      assert contains?(render("---"), "<hr")
    end

    test "*** renders as <hr>" do
      assert contains?(render("***"), "<hr")
    end

    test "___ renders as <hr>" do
      assert contains?(render("___"), "<hr")
    end
  end

  describe "html safety" do
    test "raw < > & are escaped in normal text" do
      html = render("a < b & c > d")
      assert contains?(html, "a &lt; b &amp; c &gt; d")
    end

    test "raw html tags in input cannot break out" do
      html = render("text <script>alert(1)</script>")
      refute contains?(html, "<script>alert(1)</script>")
      assert contains?(html, "&lt;script&gt;alert(1)&lt;/script&gt;")
    end
  end

  describe "integration: realistic AI insights output" do
    test "full document round-trip" do
      md = """
      ## Executive Summary
      Traffic was **up 23%** week-over-week with notable growth from organic search.

      ## Priority Actions
      1. Investigate the *spike* in bounce rate on `/pricing`
      2. Double down on the [paid campaign](https://ads.example.com/campaign/42)
      3. Fix ~~broken~~ outdated FAQ section

      ## SEO Insights
      - Keyword "puppy adoption" climbed to position 3
      - New backlinks from `puppypals.com` and `pet-news.org`

      > Quick win: the page at /breeds is converting at 8.3% — promote it.

      ---

      End of report.
      """

      html = render(md)

      # Headers
      assert contains?(html, "<h2")
      assert contains?(html, "Executive Summary</h2>")

      # Bold + italic + code + strikethrough
      assert contains?(html, "<strong>up 23%</strong>")
      assert contains?(html, "<em>spike</em>")
      assert contains?(html, ">/pricing</code>")
      assert contains?(html, "<del>broken</del>")

      # Link
      assert contains?(html, ~s(<a href="https://ads.example.com/campaign/42"))
      assert contains?(html, ">paid campaign</a>")

      # Lists
      assert contains?(html, "<strong>1.</strong>")
      assert contains?(html, "&bull; Keyword")

      # Blockquote
      assert contains?(html, "<blockquote")
      assert contains?(html, "Quick win:")

      # HR
      assert contains?(html, "<hr")
    end
  end
end
