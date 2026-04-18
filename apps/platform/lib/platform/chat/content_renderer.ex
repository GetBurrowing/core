defmodule Platform.Chat.ContentRenderer do
  @moduledoc """
  Renders chat message content from markdown to sanitized HTML.

  Pipeline: raw markdown -> Earmark parse -> sanitize HTML -> syntax highlight
  code blocks -> decorate @-mentions -> Phoenix.HTML.raw()
  """

  import Phoenix.HTML, only: [raw: 1]

  @dangerous_url_schemes ~w(javascript: vbscript: data:text/html)

  @doc """
  Renders a message content string as sanitized HTML safe for LiveView rendering.

  Returns a `Phoenix.HTML.safe()` tuple via `raw/1`.
  """
  @spec render_message(String.t() | nil) :: Phoenix.HTML.safe()
  def render_message(nil), do: raw("")
  def render_message(""), do: raw("")

  def render_message(content) when is_binary(content) do
    content
    |> parse_markdown()
    |> sanitize_html()
    |> decorate_mentions()
    |> wrap_code_blocks()
    |> raw()
  end

  # ── Markdown Parsing ────────────────────────────────────────────────

  defp parse_markdown(content) do
    options = %Earmark.Options{
      code_class_prefix: "language-",
      smartypants: false,
      breaks: true
    }

    case Earmark.as_html(content, options) do
      {:ok, html, _warnings} ->
        html

      {:error, _html, _errors} ->
        Phoenix.HTML.html_escape(content) |> Phoenix.HTML.safe_to_string()
    end
  end

  # ── HTML Sanitization ──────────────────────────────────────────────

  defp sanitize_html(html) do
    html
    |> downgrade_headings()
    |> strip_dangerous_tags()
    |> strip_dangerous_attributes()
    |> neutralize_dangerous_urls()
    |> add_link_attributes()
  end

  # Cap headings at h3 — no h1/h2 in chat
  defp downgrade_headings(html) do
    html
    |> String.replace(~r/<h1(\s|>)/i, "<h3\\1")
    |> String.replace(~r/<\/h1>/i, "</h3>")
    |> String.replace(~r/<h2(\s|>)/i, "<h3\\1")
    |> String.replace(~r/<\/h2>/i, "</h3>")
  end

  defp strip_dangerous_tags(html) do
    # Remove script, iframe, object, embed, form, style tags and their content
    html
    |> String.replace(~r/<script\b[^>]*>.*?<\/script>/is, "")
    |> String.replace(~r/<iframe\b[^>]*>.*?<\/iframe>/is, "")
    |> String.replace(~r/<object\b[^>]*>.*?<\/object>/is, "")
    |> String.replace(~r/<embed\b[^>]*\/?>/is, "")
    |> String.replace(~r/<form\b[^>]*>.*?<\/form>/is, "")
    |> String.replace(~r/<style\b[^>]*>.*?<\/style>/is, "")
  end

  defp strip_dangerous_attributes(html) do
    # Remove on* event handlers (onclick, onerror, etc.)
    String.replace(html, ~r/\s+on\w+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]*)/i, "")
  end

  defp neutralize_dangerous_urls(html) do
    # Neutralize javascript: and other dangerous URL schemes in href/src
    Enum.reduce(@dangerous_url_schemes, html, fn scheme, acc ->
      String.replace(
        acc,
        ~r/(href|src)\s*=\s*["']?\s*#{Regex.escape(scheme)}/i,
        "\\1=\"#blocked:"
      )
    end)
  end

  defp add_link_attributes(html) do
    # Add target="_blank" rel="noopener noreferrer" to links that don't already have target
    String.replace(html, ~r/<a\s+href=/i, ~s(<a target="_blank" rel="noopener noreferrer" href=))
  end

  # ── @-mention decoration ───────────────────────────────────────────

  defp decorate_mentions(html) do
    # Split on HTML tags to avoid decorating mentions inside tag attributes
    html
    |> String.split(~r/(<[^>]+>)/, include_captures: true)
    |> Enum.map(fn part ->
      if String.starts_with?(part, "<") do
        part
      else
        String.replace(part, ~r/@(\w+)/, fn mention ->
          ~s(<span class="rounded bg-primary/20 text-primary px-1 font-medium">#{Phoenix.HTML.html_escape(mention) |> Phoenix.HTML.safe_to_string()}</span>)
        end)
      end
    end)
    |> Enum.join()
  end

  # ── Code Block Post-Processing ─────────────────────────────────────

  defp wrap_code_blocks(html) do
    # Wrap pre>code blocks with a phx-hook div for the CodeBlock JS hook.
    # Earmark uses class="elixir language-elixir" or class="language-elixir".
    # Each wrapper MUST carry a unique DOM id — Phoenix LiveView hooks log
    # "no DOM ID for hook" otherwise. A process-unique integer suffix is
    # stable within a single render and avoids the hook-attach warning.
    Regex.replace(~r/<pre><code(\s+class="([^"]*)")?>/, html, fn _full, class_attr, classes ->
      lang = extract_language(classes)
      id = "code-block-#{System.unique_integer([:positive])}"

      cond do
        lang != nil ->
          ~s(<div id="#{id}" phx-hook="CodeBlock" data-language="#{lang}" class="code-block-wrapper"><pre><code#{class_attr}>)

        class_attr != "" ->
          ~s(<div id="#{id}" phx-hook="CodeBlock" class="code-block-wrapper"><pre><code#{class_attr}>)

        true ->
          ~s(<div id="#{id}" phx-hook="CodeBlock" class="code-block-wrapper"><pre><code>)
      end
    end)
    |> close_code_block_wrappers()
  end

  defp extract_language(""), do: nil

  defp extract_language(classes) do
    case Regex.run(~r/(?:^|\s)language-(\w+)/, classes) do
      [_, lang] ->
        lang

      _ ->
        # Earmark sometimes puts the language as the first class directly
        classes |> String.split() |> List.first()
    end
  end

  defp close_code_block_wrappers(html) do
    String.replace(html, "</code></pre>", "</code></pre></div>")
  end

  # ── Syntax Highlighting (Makeup) ───────────────────────────────────

  @doc """
  Highlights code using Makeup lexers. Called by the CodeBlock JS hook
  is not used directly — Earmark handles code fences, and Makeup can be
  invoked for server-side highlighting if needed.
  """
  @spec highlight_code(String.t(), String.t()) :: String.t()
  def highlight_code(code, language) do
    case lexer_for(language) do
      nil -> Phoenix.HTML.html_escape(code) |> Phoenix.HTML.safe_to_string()
      lexer -> Makeup.highlight(code, lexer: lexer)
    end
  end

  defp lexer_for("elixir"), do: Makeup.Lexers.ElixirLexer
  defp lexer_for("ex"), do: Makeup.Lexers.ElixirLexer
  defp lexer_for("exs"), do: Makeup.Lexers.ElixirLexer
  defp lexer_for("heex"), do: Makeup.Lexers.ElixirLexer
  defp lexer_for("javascript"), do: Makeup.Lexers.JsLexer
  defp lexer_for("js"), do: Makeup.Lexers.JsLexer
  defp lexer_for("typescript"), do: Makeup.Lexers.JsLexer
  defp lexer_for("ts"), do: Makeup.Lexers.JsLexer
  defp lexer_for(_), do: nil
end
