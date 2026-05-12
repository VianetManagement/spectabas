defmodule Spectabas.AI.MarkdownEmail do
  @moduledoc """
  Renders the markdown produced by AI weekly insights into email-safe HTML
  with inline styles. Email clients vary wildly in their CSS support, so
  every visible element ships its own style attribute.

  Markdown subset supported:
  - Headers: `#` through `######`
  - Bold: `**text**`, `__text__`
  - Italic: `*text*`, `_text_`
  - Strikethrough: `~~text~~`
  - Inline code: `` `code` ``
  - Fenced code blocks: triple backticks
  - Links: `[label](https://… or mailto:…)` (other schemes render verbatim)
  - Blockquotes: lines beginning with `> `
  - Bullet lists: lines beginning with `- ` or `* `
  - Numbered lists: lines beginning with `N. `
  - Horizontal rules: `---`, `***`, `___`
  - Blank lines: passed through
  """

  @doc """
  Render markdown text to HTML for embedding in an email body.
  """
  def render(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> render_lines([], false)
    |> Enum.join("\n")
  end

  def render(_), do: ""

  # Walk the list of lines once, tracking whether we're inside a fenced code
  # block. Inside a code block we render verbatim (escaped but no inline
  # transforms). Outside, each line is dispatched by its leading marker.
  defp render_lines([], acc, _in_code), do: Enum.reverse(acc)

  defp render_lines([line | rest], acc, true) do
    if String.trim(line) == "```" do
      render_lines(rest, ["</pre>" | acc], false)
    else
      render_lines(rest, [esc(line) | acc], true)
    end
  end

  defp render_lines([line | rest], acc, false) do
    line = String.trim_trailing(line)

    cond do
      String.trim(line) == "```" ->
        render_lines(
          rest,
          [
            ~s(<pre style="background:#f3f4f6;color:#111827;font-family:Menlo,Monaco,Consolas,monospace;font-size:13px;padding:12px;border-radius:6px;overflow-x:auto;margin:8px 0;">)
            | acc
          ],
          true
        )

      String.starts_with?(line, "###### ") ->
        render_lines(rest, [header(line, "######", 6) | acc], false)

      String.starts_with?(line, "##### ") ->
        render_lines(rest, [header(line, "#####", 5) | acc], false)

      String.starts_with?(line, "#### ") ->
        render_lines(rest, [header(line, "####", 4) | acc], false)

      String.starts_with?(line, "### ") ->
        render_lines(rest, [header(line, "###", 3) | acc], false)

      String.starts_with?(line, "## ") ->
        render_lines(rest, [header(line, "##", 2) | acc], false)

      String.starts_with?(line, "# ") ->
        render_lines(rest, [header(line, "#", 1) | acc], false)

      line in ["---", "***", "___"] ->
        render_lines(
          rest,
          [~s(<hr style="border:0;border-top:1px solid #e5e7eb;margin:16px 0;" />) | acc],
          false
        )

      String.starts_with?(line, "> ") ->
        body = inline(String.trim_leading(line, "> "))

        html =
          ~s(<blockquote style="margin:8px 0;padding:8px 12px;border-left:3px solid #c7d2fe;color:#4b5563;font-size:14px;background:#f5f3ff;">) <>
            body <> "</blockquote>"

        render_lines(rest, [html | acc], false)

      String.match?(line, ~r/^\d+\.\s/) ->
        [num, body] = Regex.run(~r/^(\d+)\.\s+(.*)$/, line, capture: :all_but_first)

        html =
          ~s(<p style="color:#374151;font-size:14px;margin:4px 0 4px 16px;"><strong>) <>
            esc(num) <> ".</strong> " <> inline(body) <> "</p>"

        render_lines(rest, [html | acc], false)

      String.starts_with?(line, "- ") or String.starts_with?(line, "* ") ->
        body = String.replace(line, ~r/^[-*]\s+/, "")

        html =
          ~s(<p style="color:#374151;font-size:14px;margin:4px 0 4px 16px;">&bull; ) <>
            inline(body) <> "</p>"

        render_lines(rest, [html | acc], false)

      line == "" ->
        render_lines(rest, ["" | acc], false)

      true ->
        html =
          ~s(<p style="color:#374151;font-size:14px;margin:6px 0;">) <>
            inline(line) <> "</p>"

        render_lines(rest, [html | acc], false)
    end
  end

  defp header(line, prefix, level) do
    text = String.trim_leading(line, prefix <> " ")

    {font_size, margin, border} =
      case level do
        1 -> {"22px", "16px 0 8px", ""}
        2 -> {"18px", "20px 0 8px", "border-bottom:1px solid #e5e7eb;padding-bottom:6px;"}
        3 -> {"16px", "16px 0 6px", ""}
        4 -> {"15px", "14px 0 4px", ""}
        5 -> {"14px", "12px 0 4px", ""}
        _ -> {"13px", "12px 0 4px", ""}
      end

    ~s(<h#{level} style="color:#1f2937;font-size:#{font_size};margin:#{margin};#{border}">) <>
      inline(text) <> "</h#{level}>"
  end

  # Extract code spans first so `*` / `**` inside them aren't rewritten as
  # italic/bold, then run other inline transforms, then restore the code.
  defp inline(text) do
    {text, codes} = extract_code_spans(esc(text), [], 0)

    text
    |> apply_links()
    |> apply_bold()
    |> apply_italic()
    |> apply_strikethrough()
    |> restore_code_spans(codes)
  end

  defp extract_code_spans(text, codes, idx) do
    case Regex.run(~r/`([^`]+?)`/, text, return: :index) do
      nil ->
        {text, Enum.reverse(codes)}

      [{whole_start, whole_len}, {ct_start, ct_len}] ->
        content = String.slice(text, ct_start, ct_len)
        placeholder = "\x01CODE#{idx}\x01"

        new_text =
          String.slice(text, 0, whole_start) <>
            placeholder <>
            String.slice(text, (whole_start + whole_len)..-1//1)

        extract_code_spans(new_text, [content | codes], idx + 1)
    end
  end

  defp restore_code_spans(text, codes) do
    codes
    |> Enum.with_index()
    |> Enum.reduce(text, fn {content, idx}, acc ->
      code_html =
        ~s(<code style="background:#f3f4f6;color:#111827;font-family:Menlo,Monaco,Consolas,monospace;font-size:13px;padding:1px 4px;border-radius:3px;">) <>
          content <> "</code>"

      String.replace(acc, "\x01CODE#{idx}\x01", code_html)
    end)
  end

  defp apply_links(text) do
    Regex.replace(~r/\[([^\]]+?)\]\(([^)]+?)\)/, text, fn _, label, url ->
      if Regex.match?(~r/^(https?:|mailto:)/i, url) do
        ~s(<a href="#{url}" style="color:#4f46e5;text-decoration:underline;">) <> label <> "</a>"
      else
        "[" <> label <> "](" <> url <> ")"
      end
    end)
  end

  defp apply_bold(text) do
    text
    |> String.replace(~r/\*\*(.+?)\*\*/, "<strong>\\1</strong>")
    |> String.replace(~r/__(.+?)__/, "<strong>\\1</strong>")
  end

  defp apply_italic(text) do
    text
    |> String.replace(~r/(?<!\*)\*(?!\*)([^*\n]+?)\*(?!\*)/, "<em>\\1</em>")
    |> String.replace(~r/(?<!_)_(?!_)([^_\n]+?)_(?!_)/, "<em>\\1</em>")
  end

  defp apply_strikethrough(text) do
    String.replace(text, ~r/~~(.+?)~~/, "<del>\\1</del>")
  end

  defp esc(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
