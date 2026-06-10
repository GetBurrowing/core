defmodule PlatformWeb.OrgMemoryLive.MarkdownRenderer do
  @moduledoc """
  Markdown + wikilink rendering for the Org Memory wiki (ADR-0041 T7
  stage 4).

  Pipeline (design lock §3):

    1. `Wiki.parse_frontmatter/1` splits frontmatter from the body —
       only the body is rendered.
    2. `Earmark.as_html/2` renders the body with the same options the
       previous Org Context viewer used (`code_class_prefix:
       "language-"`, `smartypants: false`, `breaks: true`).
    3. `Wiki.parse_wikilinks/1` produces the descriptor list of links
       that actually count (it already strips fenced/inline code
       regions, so tokens inside code never appear here).
    4. The rendered HTML is post-processed: each literal `[[target]]` /
       `[[target|display]]` token found OUTSIDE `<pre>`/`<code>`
       regions is swapped for an `<a class="wikilink">` (resolved) or
       `<span class="wikilink-dangling">` (unresolved).

  Code-region discipline: the post-processor never runs a global regex
  over the whole HTML. It first splits the HTML on `<pre>…</pre>` /
  `<code>…</code>` boundaries and only swaps tokens in the non-code
  segments, mirroring `Wiki.parse_wikilinks/1`'s strip step. As a
  second belt-and-braces guard, a token is only swapped when its
  parsed `{target, display}` pair appears in the descriptor list from
  step 3 — so even an HTML-shape surprise cannot rewrite code spans.

  This module is pure: no DB calls. Target resolution happens through
  the `lookup` map the caller passes in — built once per render by the
  LiveView from `Wiki.list_pages/1` (with `Wiki.resolve_alias/2`
  fallback for misses), keeping the renderer unit-testable.
  """

  alias Platform.Org.Wiki

  @earmark_options %Earmark.Options{
    code_class_prefix: "language-",
    smartypants: false,
    breaks: true
  }

  @typedoc """
  Wikilink lookup table: `target token => resolved file_key`. Targets
  absent from the map (or mapped to `nil`) render as dangling.
  """
  @type lookup :: %{optional(String.t()) => String.t() | nil}

  @doc """
  Render markdown `content` to HTML with wikilinks swapped.

  `lookup` maps wikilink targets to resolved `file_key`s (see
  `t:lookup/0`). Frontmatter is stripped before rendering.
  """
  @spec render(String.t() | nil, lookup()) :: String.t()
  def render(content, lookup \\ %{})
  def render(nil, _lookup), do: ""
  def render("", _lookup), do: ""

  def render(content, lookup) when is_binary(content) and is_map(lookup) do
    {_frontmatter, body} = Wiki.parse_frontmatter(content)
    links = Wiki.parse_wikilinks(body)

    body
    |> to_html()
    |> swap_wikilinks(links, lookup)
  end

  # ── Earmark ───────────────────────────────────────────────────────────

  defp to_html(body) do
    case Earmark.as_html(body, @earmark_options) do
      {:ok, html, _warnings} ->
        html

      {:error, _html, _errors} ->
        body |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
    end
  end

  # ── Wikilink post-processing ──────────────────────────────────────────

  # Swap `[[...]]` tokens in the rendered HTML, skipping `<pre>`/`<code>`
  # regions. `links` is the descriptor allowlist from
  # `Wiki.parse_wikilinks/1` — tokens whose parsed pair is not in it
  # (e.g. tokens that only existed inside code regions of the source)
  # are left untouched.
  defp swap_wikilinks(html, links, lookup) do
    allowed = MapSet.new(links, fn link -> {link.target_path, link.display_text} end)

    html
    |> split_on_code_boundaries()
    |> Enum.map_join(fn
      {:code, segment} -> segment
      {:text, segment} -> swap_tokens(segment, allowed, lookup)
    end)
  end

  # Split HTML into `{:code, _}` / `{:text, _}` segments. `<pre>` is
  # listed first in the alternation so a fenced block's `<pre><code>`
  # pair is captured as one region.
  defp split_on_code_boundaries(html) do
    ~r/<pre\b.*?<\/pre>|<code\b.*?<\/code>/s
    |> Regex.split(html, include_captures: true)
    |> Enum.map(fn segment ->
      if String.starts_with?(segment, "<pre") or String.starts_with?(segment, "<code") do
        {:code, segment}
      else
        {:text, segment}
      end
    end)
  end

  defp swap_tokens(segment, allowed, lookup) do
    Regex.replace(~r/\[\[([^\]\n]*)\]\]/, segment, fn token, inner ->
      case parse_token(inner) do
        :skip ->
          token

        {target, display} ->
          if MapSet.member?(allowed, {target, display}) do
            build_link(target, display, lookup)
          else
            token
          end
      end
    end)
  end

  # Mirrors `Wiki.parse_wikilinks/1`'s token discipline: split on the
  # first `|`, trim both sides, skip empty targets, nil-out empty
  # display text.
  defp parse_token(inner) do
    case :binary.split(inner, "|") do
      [target] ->
        case String.trim(target) do
          "" -> :skip
          clean -> {clean, nil}
        end

      [target, display] ->
        case String.trim(target) do
          "" ->
            :skip

          clean ->
            trimmed = String.trim(display)
            {clean, if(trimmed == "", do: nil, else: trimmed)}
        end
    end
  end

  defp build_link(target, display, lookup) do
    text = display || target

    case Map.get(lookup, target) do
      nil ->
        ~s(<span class="wikilink-dangling" title="Dangling — page does not exist">#{text}</span>)

      resolved ->
        ~s(<a href="/org_memory/#{attr_escape(resolved)}" class="wikilink">#{text}</a>)
    end
  end

  # `text` already comes from Earmark-rendered (escaped) HTML; only the
  # injected href value needs attribute escaping.
  defp attr_escape(value) do
    value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end
end
