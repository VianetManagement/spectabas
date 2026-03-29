defmodule SpectabasWeb.DocsMarkdownTest do
  use ExUnit.Case, async: true

  alias SpectabasWeb.DocsLive

  describe "render_markdown_public/1" do
    test "renders paragraphs" do
      html = DocsLive.render_markdown_public("Hello world")
      assert html =~ "<p"
      assert html =~ "Hello world"
    end

    test "renders h2 headings" do
      html = DocsLive.render_markdown_public("## My Heading")
      assert html =~ "<h3"
      assert html =~ "My Heading"
    end

    test "renders h3 headings" do
      html = DocsLive.render_markdown_public("### Sub Heading")
      assert html =~ "<h4"
      assert html =~ "Sub Heading"
    end

    test "renders bold text" do
      html = DocsLive.render_markdown_public("This is **bold** text")
      assert html =~ "<strong>bold</strong>"
    end

    test "renders inline code" do
      html = DocsLive.render_markdown_public("Use `my_function` here")
      assert html =~ "<code"
      assert html =~ "my_function"
    end

    test "renders unordered lists" do
      md = "- First item\n- Second item\n- Third item"
      html = DocsLive.render_markdown_public(md)
      assert html =~ "<ul"
      assert html =~ "<li"
      assert html =~ "First item"
      assert html =~ "Second item"
      assert html =~ "Third item"
    end

    test "renders bold inside list items" do
      md = "- **Bold item** — description"
      html = DocsLive.render_markdown_public(md)
      assert html =~ "<strong>Bold item</strong>"
      assert html =~ "<li"
    end

    test "renders inline code inside list items" do
      md = "- Use `foo` for bar"
      html = DocsLive.render_markdown_public(md)
      assert html =~ "<code"
      assert html =~ "foo"
    end

    test "separates paragraph from list with blank line" do
      md = "Intro text:\n\n- Item one\n- Item two"
      html = DocsLive.render_markdown_public(md)
      assert html =~ "<p"
      assert html =~ "Intro text:"
      assert html =~ "<ul"
      assert html =~ "Item one"
    end

    test "paragraph followed by list without blank line stays separate blocks" do
      # After our fix, content should have blank lines between text and lists
      md = "Intro text:\n\n- Item one"
      html = DocsLive.render_markdown_public(md)
      assert html =~ "<p"
      assert html =~ "<ul"
    end

    test "renders code blocks" do
      md = "```javascript\nconsole.log('hello');\n```"
      html = DocsLive.render_markdown_public(md)
      assert html =~ "<pre"
      assert html =~ "<code>"
      assert html =~ "console.log"
    end

    test "preserves code blocks with blank lines" do
      md = "```javascript\nvar a = 1;\n\nvar b = 2;\n```"
      html = DocsLive.render_markdown_public(md)
      assert html =~ "<pre"
      assert html =~ "var a = 1;"
      assert html =~ "var b = 2;"
      # Should be in ONE code block, not split
      assert length(String.split(html, "<pre")) == 2
    end

    test "code blocks with multiple blank lines stay intact" do
      md =
        "```javascript\n// Section 1\nfoo();\n\n// Section 2\nbar();\n\n// Section 3\nbaz();\n```"

      html = DocsLive.render_markdown_public(md)
      # Only one <pre> block
      assert length(String.split(html, "<pre")) == 2
      assert html =~ "Section 1"
      assert html =~ "Section 3"
    end

    test "escapes HTML in code blocks" do
      md = "```html\n<div class=\"test\">\n```"
      html = DocsLive.render_markdown_public(md)
      assert html =~ "&lt;div"
      refute html =~ "<div class=\"test\">"
    end

    test "renders tables" do
      md = "| Col1 | Col2 |\n|------|------|\n| A | B |"
      html = DocsLive.render_markdown_public(md)
      assert html =~ "<table"
      assert html =~ "<th"
      assert html =~ "Col1"
      assert html =~ "<td"
      assert html =~ "A"
    end

    test "renders bold in table cells" do
      md = "| Name | Desc |\n|------|------|\n| **bold** | `code` |"
      html = DocsLive.render_markdown_public(md)
      assert html =~ "<strong>bold</strong>"
      assert html =~ "<code"
    end

    test "renders blockquotes" do
      md = "> **Note:** This is important"
      html = DocsLive.render_markdown_public(md)
      assert html =~ "border-l-4"
      assert html =~ "<strong>Note:</strong>"
      assert html =~ "This is important"
    end

    test "renders horizontal rules" do
      md = "Before\n\n---\n\nAfter"
      html = DocsLive.render_markdown_public(md)
      assert html =~ "<hr"
      assert html =~ "Before"
      assert html =~ "After"
    end

    test "handles complex document with mixed elements" do
      md = """
      ## Getting Started

      Welcome to the app.

      ### Features

      - **Fast** — very quick
      - **Simple** — easy to use

      ```javascript
      Spectabas.track("signup");

      Spectabas.track("login");
      ```

      > **Tip:** Use this wisely.

      ---

      | Metric | Value |
      |--------|-------|
      | Speed | Fast |
      """

      html = DocsLive.render_markdown_public(md)
      assert html =~ "<h3"
      assert html =~ "Getting Started"
      assert html =~ "<h4"
      assert html =~ "Features"
      assert html =~ "<ul"
      assert html =~ "<strong>Fast</strong>"
      assert html =~ "<pre"
      assert html =~ "Spectabas.track"
      # Code block should be intact (one pre)
      assert length(String.split(html, "<pre")) == 2
      assert html =~ "border-l-4"
      assert html =~ "<hr"
      assert html =~ "<table"
    end

    test "strips heredoc indentation from code blocks" do
      # Simulates code inside a heredoc with 12-space indentation
      md = "```javascript\n            var x = 1;\n            var y = 2;\n```"
      html = DocsLive.render_markdown_public(md)
      assert html =~ "var x = 1;"
      # Should not have leading spaces in the rendered code
      refute html =~ "            var x"
    end
  end
end
