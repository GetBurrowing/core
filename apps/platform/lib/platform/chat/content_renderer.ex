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
  def render_message(content), do: render_message(content, [])

  @doc """
  `render_message/1` with options (redesign rung 13, stage 1).

    * `:cards` - URLs (or `Platform.Chat.LinkTargets.key/2` keys) that got a
      card or a player. A line holding only one of those links is removed:
      the card replaces it (rule 1 of the rung 13 direction canvas). A link
      inside a sentence keeps the sender's words.
  """
  @spec render_message(String.t() | nil, keyword()) :: Phoenix.HTML.safe()
  def render_message(nil, _opts), do: raw("")
  def render_message("", _opts), do: raw("")

  def render_message(content, opts) when is_binary(content) do
    content
    |> sanitized_html()
    |> Platform.Chat.LinkTargets.strip_bare_lines(Keyword.get(opts, :cards, []), [])
    |> decorate_mentions()
    |> wrap_code_blocks()
    |> raw()
  end

  @doc """
  Markdown -> sanitized html, before mentions and code wrapping. This is the
  html `Platform.Chat.LinkTargets` classifies, so a dangerous href is already
  `#blocked:` by the time any link is looked at.
  """
  @spec sanitized_html(String.t() | nil) :: String.t()
  def sanitized_html(content) when is_binary(content) and content != "" do
    content
    |> parse_markdown()
    |> sanitize_html()
  end

  def sanitized_html(_content), do: ""

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
    |> mark_raw_urls()
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

  # Rung 13 stage 1: a link to a canvas or prototype on this install is an
  # in-app link: no target, and `data-in-app-link` so a click is intercepted
  # and opened inside the app. Every other link (external, other paths, and
  # the `#blocked:` hrefs `neutralize_dangerous_urls/1` left) keeps
  # target="_blank" rel="noopener noreferrer" exactly as before.
  defp add_link_attributes(html) do
    Regex.replace(
      ~r/<a\s+href=("[^"]*"|'[^']*'|[^\s>]*)/i,
      html,
      fn _whole, quoted ->
        href = quoted |> String.trim("\"") |> String.trim("'")

        case Platform.Chat.LinkTargets.classify(href) do
          {kind, _id, _version} when kind in [:canvas, :prototype] ->
            ~s(<a data-in-app-link="#{kind}" href=#{quoted})

          _ ->
            ~s(<a target="_blank" rel="noopener noreferrer" href=#{quoted})
        end
      end
    )
  end

  # Rung 13 stage 1: a raw URL that stays as text (the anchor's text IS its
  # href, the Earmark autolink shape) is set in the mono face. A link whose
  # text is the sender's own words keeps the body face.
  defp mark_raw_urls(html) do
    Regex.replace(~r/<a ([^>]*)>([^<]*)<\/a>/, html, fn whole, attrs, text ->
      href =
        case Regex.run(~r/\bhref="([^"]*)"/, attrs) do
          [_, href] -> href
          _ -> nil
        end

      if (href && not String.contains?(attrs, "class=")) and
           unescape(text) == unescape(href) and String.starts_with?(href, "http") do
        ~s(<a class="font-mono" #{attrs}>#{text}</a>)
      else
        whole
      end
    end)
  end

  defp unescape(s), do: s |> String.replace("&amp;", "&") |> String.trim()

  # ── @-mention decoration ───────────────────────────────────────────
  #
  # Primary format (ADR 0037): `@[Display Name]` — bracketed, multi-word safe.
  # Legacy format: `@word` — still highlighted so pre-migration messages render
  # the same. Run in that order so a bracketed mention inside a line isn't
  # double-wrapped by the legacy pass.

  @mention_span ~s(<span class="rounded bg-primary/20 text-primary px-1 font-medium">)
  @broadcast_mention_span ~s(<span class="rounded bg-warning/30 text-warning px-1 font-semibold">)
  @mention_span_close "</span>"

  defp decorate_mentions(html) do
    # Split on HTML tags to avoid decorating mentions inside tag attributes
    html
    |> String.split(~r/(<[^>]+>)/, include_captures: true)
    |> Enum.map(fn part ->
      if String.starts_with?(part, "<") do
        part
      else
        # Order matters: legacy first (its `\w+` won't match `@[`, so it
        # leaves bracketed mentions alone). Bracketed second — the legacy
        # pass has already wrapped any bare `@word`, so the bracketed
        # regex only sees un-wrapped `@[...]` tokens.
        part
        |> decorate_legacy_mentions()
        |> decorate_bracketed_mentions()
      end
    end)
    |> Enum.join()
  end

  # `text` arrives post-Earmark, which has already HTML-escaped content and
  # (together with `sanitize_html/1`) stripped anything dangerous — so the
  # captured name/word is already safe to inline. Re-escaping double-encodes
  # entities (e.g. `&lt;` → `&amp;lt;`).
  defp decorate_bracketed_mentions(text) do
    Regex.replace(~r/@\[([^\[\]]+)\]/, text, fn _full, name ->
      mention_span(name) <> "@" <> name <> @mention_span_close
    end)
  end

  defp decorate_legacy_mentions(text) do
    String.replace(text, ~r/@(\w+)/, fn mention ->
      @mention_span <> mention <> @mention_span_close
    end)
  end

  # Broadcast pings (`@[here]`) get a warning-tone wrapper so recipients can
  # tell at a glance they were swept up in a channel-wide ping vs called
  # out individually. Bracket-exact + case-sensitive to mirror the parser
  # (see `Platform.Chat.AttentionRouter.here_mention?/1` — only `@[here]`
  # actually fans out, so only `@[here]` should look like it does).
  defp mention_span("here"), do: @broadcast_mention_span
  defp mention_span(_name), do: @mention_span

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
