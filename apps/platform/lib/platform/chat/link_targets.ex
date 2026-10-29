defmodule Platform.Chat.LinkTargets do
  @moduledoc """
  The one parser for links in chat messages (redesign rung 13, stage 1).

  Everything that decides what a link in a message points at lives here:
  same-install host matching, the URL kinds, the bare-line rule and the card
  cap. `Platform.Chat.ContentRenderer` asks it which anchors are in-app,
  `Platform.Chat.AttachmentLinks` asks it which attachment ids a message links,
  and `Platform.Chat.LinkCards` resolves its targets per viewer. Nothing else
  parses message URLs.

  It is pure: no database, no network. It reads the SANITIZED html the
  renderer produced (`ContentRenderer.sanitized_html/1`), so a `javascript:`
  or `data:` href has already been rewritten to `#blocked:` and is never
  classified.

  ## Kinds

    * `:canvas` - this install, path `/canvases/<uuid>` (optional `/`).
    * `:prototype` - this install, path `/proto/<uuid>/<n | latest>/...`.
    * `:attachment` - this install, path `/chat/attachments/<uuid>`.
    * `:image` / `:video` - any http(s) URL whose path ends in an image or
      video extension.
    * `:link` - any other http(s) URL.

  "This install" means the URL's host and port equal
  `PlatformWeb.Endpoint`'s configured URL exactly (case-insensitive host), or
  its host is one of the configured aliases (`config :platform,
  :own_host_aliases`, from `OWN_HOST_ALIASES`) - an install served on more
  than one hostname - exactly and case-insensitively, with the endpoint's
  port or the scheme's default port. There is no suffix or prefix matching, a URL carrying userinfo
  (`https://host@evil.example/`) is never this install, and the authority must
  be a plain `host[:port]` because `URI.parse/1` is lenient
  (`host:4002.evil.example` parses as host + port 4002). A path-relative href
  (`/canvases/<uuid>`, never `//...`) is same-origin by construction and counts
  for the three in-app kinds only.
  """

  @uuid "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"

  @canvas_path Regex.compile!("\\A/canvases/(#{@uuid})/?\\z")
  @prototype_path Regex.compile!("\\A/proto/(#{@uuid})/([1-9][0-9]*|latest)(?:/.*)?\\z")
  @attachment_path Regex.compile!("\\A/chat/attachments/(#{@uuid})\\z")

  # A path-relative attachment path written as plain text (what the upload
  # tools return). Earmark does not autolink it, so text nodes are scanned
  # for it too.
  @attachment_text Regex.compile!(
                     "(?<![^\\s(\\[\"'>])/chat/attachments/(#{@uuid})(?![0-9A-Za-z_-])"
                   )

  @plain_authority ~r/\A[A-Za-z0-9.-]+(:[0-9]{1,5})?\z/

  @image_exts ~w(.png .jpg .jpeg .gif .webp .avif)
  @video_exts ~w(.mp4 .webm .mov .m4v)

  # Rule 2 of the rung 13 direction canvas: at most 3 cards per message.
  @card_cap 3
  @card_kinds [:canvas, :prototype, :image, :video, :link]

  @type kind :: :canvas | :prototype | :attachment | :image | :video | :link
  @type target :: %{
          kind: kind(),
          url: String.t(),
          id: binary() | nil,
          version: pos_integer() | :latest | nil,
          bare_line?: boolean()
        }

  @doc "The card cap per message."
  def card_cap, do: @card_cap

  @doc """
  Ordered, de-duplicated targets in sanitized message html.

  Card kinds (`:canvas`, `:prototype`, `:image`, `:video`, `:link`) are capped
  at `card_cap/0` per message; links past the cap are not returned and stay
  text links. `:attachment` targets are not capped (each readable linked clip
  gets its player, as before rung 13).

  Options: `:base_url` overrides the install URL (tests).
  """
  @spec extract(String.t() | nil, keyword()) :: [target()]
  def extract(html, opts \\ [])

  def extract(html, opts) when is_binary(html) do
    bare = bare_keys(html, opts)

    html
    |> occurrences(opts)
    |> Enum.uniq_by(& &1.key)
    |> Enum.map(fn t -> t |> Map.put(:bare_line?, MapSet.member?(bare, t.key)) end)
    |> cap()
    |> Enum.map(&Map.delete(&1, :key))
  end

  def extract(_html, _opts), do: []

  @doc "`extract/2` over raw message content (markdown)."
  @spec from_content(String.t() | nil, keyword()) :: [target()]
  def from_content(content, opts \\ [])

  def from_content(content, opts) when is_binary(content) and content != "" do
    content |> Platform.Chat.ContentRenderer.sanitized_html() |> extract(opts)
  end

  def from_content(_content, _opts), do: []

  @doc """
  Classify one href. Returns `{kind, id, version}` or nil for anything that
  is not an http(s) URL (or an in-app path-relative one).
  """
  @spec classify(String.t() | nil, keyword()) ::
          {kind(), binary() | nil, pos_integer() | :latest | nil} | nil
  def classify(href, opts \\ [])

  def classify(href, opts) when is_binary(href) do
    href = href |> decode_entities() |> String.trim()

    cond do
      String.starts_with?(href, "/") and not String.starts_with?(href, "//") ->
        href |> URI.parse() |> classify_in_app()

      true ->
        classify_absolute(href, opts)
    end
  end

  def classify(_href, _opts), do: nil

  @doc "True when `href` is a same-install canvas or prototype link."
  @spec in_app?(String.t() | nil, keyword()) :: boolean()
  def in_app?(href, opts \\ []) do
    case classify(href, opts) do
      {kind, _, _} when kind in [:canvas, :prototype] -> true
      _ -> false
    end
  end

  @doc """
  True when `href` points at this install: a path-relative href (a single
  leading `/`, never `//`), an absolute http(s) href on the endpoint's exact
  host and port, or one on a configured alias host. Anything else (external
  hosts, `#blocked:`, `mailto:`, fragments) is false.
  """
  @spec same_install?(String.t() | nil, keyword()) :: boolean()
  def same_install?(href, opts \\ [])

  def same_install?(href, opts) when is_binary(href) do
    href = href |> decode_entities() |> String.trim()

    if String.starts_with?(href, "/") do
      not String.starts_with?(href, "//")
    else
      own_host?(URI.parse(href), opts)
    end
  end

  def same_install?(_href, _opts), do: false

  @doc """
  The path-relative form (path, query, fragment) of a same-install absolute
  href, so it opens on the current origin. Returns `href` unchanged when it
  is already path-relative or not same-install.
  """
  @spec relative_href(String.t(), keyword()) :: String.t()
  def relative_href(href, opts \\ []) when is_binary(href) do
    decoded = href |> decode_entities() |> String.trim()

    if same_install?(decoded, opts) and not String.starts_with?(decoded, "/") do
      uri = URI.parse(decoded)
      URI.to_string(%URI{path: uri.path || "/", query: uri.query, fragment: uri.fragment})
    else
      href
    end
  end

  @doc """
  Anchor attributes for a link, as a map to splat into HEEx (`{...}`). A
  same-install link gets `data-in-app-link="path"` and no target; every other
  link gets `target="_blank" rel="noopener noreferrer"`.
  """
  @spec open_attrs(String.t() | nil, keyword()) :: map()
  def open_attrs(href, opts \\ []) do
    if same_install?(href, opts),
      do: %{"data-in-app-link" => "path"},
      else: %{"target" => "_blank", "rel" => "noopener noreferrer"}
  end

  @doc """
  `href` made path-relative when it is a same-install absolute link; for
  use alongside `open_attrs/2`.
  """
  @spec open_href(String.t() | nil, keyword()) :: String.t() | nil
  def open_href(href, opts \\ [])
  def open_href(href, opts) when is_binary(href), do: relative_href(href, opts)
  def open_href(href, _opts), do: href

  @doc """
  True when `uri`'s scheme is http(s), it carries no userinfo, its authority
  is a plain `host[:port]`, and either host and port equal this install's, or
  the host is a configured alias (exact, case-insensitive) on the endpoint's
  port or the scheme's default port.

  Options: `:base_url` overrides the install URL, `:aliases` the alias list
  (tests).
  """
  @spec own_host?(URI.t(), keyword()) :: boolean()
  def own_host?(%URI{} = uri, opts \\ []) do
    plain_authority?(uri) and (base_host?(uri, opts) or alias_host?(uri, opts))
  end

  @doc """
  True when `uri` is this install reached through a configured alias host
  rather than the endpoint's own host. The renderer rewrites such a link to
  a path-relative href so it opens on the current origin.
  """
  @spec alias_host?(URI.t(), keyword()) :: boolean()
  def alias_host?(%URI{} = uri, opts \\ []) do
    base = base_uri(opts)

    plain_authority?(uri) and not base_host?(uri, opts) and
      String.downcase(uri.host) in aliases(opts) and
      uri.port in [base.port, URI.default_port(uri.scheme)]
  end

  @doc "The configured alias hosts, lowercased."
  @spec aliases(keyword()) :: [String.t()]
  def aliases(opts \\ []) do
    opts
    |> Keyword.get_lazy(:aliases, fn -> Application.get_env(:platform, :own_host_aliases, []) end)
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  The de-duplication key of a URL (or target). Two links to the same canvas,
  prototype version or attachment share a key whatever their spelling.
  """
  @spec key(String.t() | map(), keyword()) :: term()
  def key(target_or_url, opts \\ [])
  def key(%{url: url}, opts), do: key(url, opts)

  def key(url, opts) when is_binary(url) do
    case classify(url, opts) do
      {kind, id, version} when kind in [:canvas, :attachment] and is_binary(id) ->
        {kind, id, version}

      {:prototype, id, version} ->
        {:prototype, id, version}

      _ ->
        {:url, normalize_url(url)}
    end
  end

  @doc """
  The attachment ids sanitized html links to, in order, lowercased and unique.
  """
  @spec attachment_ids(String.t() | nil, keyword()) :: [binary()]
  def attachment_ids(html, opts \\ []) do
    html
    |> extract(opts)
    |> Enum.flat_map(fn
      %{kind: :attachment, id: id} -> [id]
      _ -> []
    end)
  end

  @doc """
  Remove every bare-line occurrence of the given URLs (or keys) from
  sanitized html: a paragraph line holding only that link. A paragraph left
  empty is dropped. A mid-sentence occurrence keeps the sender's words.
  """
  @spec strip_bare_lines(String.t(), [String.t() | term()], keyword()) :: String.t()
  def strip_bare_lines(html, [], _opts), do: html

  def strip_bare_lines(html, urls, opts) when is_binary(html) do
    keys = MapSet.new(urls, &to_key(&1, opts))

    Regex.replace(~r/<p>(.*?)<\/p>\n?/s, html, fn whole, inner ->
      lines = split_lines(inner)
      kept = Enum.reject(lines, &(bare_key(&1, opts) in keys))

      cond do
        length(kept) == length(lines) -> whole
        Enum.all?(kept, &(String.trim(&1) == "")) -> ""
        true -> "<p>" <> Enum.join(kept, "<br>\n") <> "</p>\n"
      end
    end)
  end

  # ── internals ────────────────────────────────────────────────────────

  defp plain_authority?(%URI{} = uri) do
    uri.scheme in ["http", "https"] and is_nil(uri.userinfo) and
      is_binary(uri.authority) and Regex.match?(@plain_authority, uri.authority) and
      is_binary(uri.host) and uri.host != ""
  end

  defp base_host?(%URI{} = uri, opts) do
    base = base_uri(opts)

    is_binary(base.host) and String.downcase(uri.host) == String.downcase(base.host) and
      uri.port == base.port
  end

  defp to_key(url, opts) when is_binary(url), do: key(url, opts)
  defp to_key(key, _opts), do: key

  defp classify_absolute(href, opts) do
    uri = URI.parse(href)

    cond do
      uri.scheme not in ["http", "https"] or not is_binary(uri.host) or uri.host == "" ->
        nil

      own_host?(uri, opts) and classify_in_app(uri) != nil ->
        classify_in_app(uri)

      media_ext?(uri.path, @image_exts) ->
        {:image, nil, nil}

      media_ext?(uri.path, @video_exts) ->
        {:video, nil, nil}

      true ->
        {:link, nil, nil}
    end
  end

  defp classify_in_app(%URI{path: path}) when is_binary(path) do
    cond do
      match = Regex.run(@canvas_path, path) ->
        [_, id] = match
        {:canvas, String.downcase(id), nil}

      match = Regex.run(@prototype_path, path) ->
        [_, id, version] = match
        {:prototype, String.downcase(id), parse_version(version)}

      match = Regex.run(@attachment_path, path) ->
        [_, id] = match
        {:attachment, String.downcase(id), nil}

      true ->
        nil
    end
  end

  defp classify_in_app(_uri), do: nil

  defp parse_version("latest"), do: :latest
  defp parse_version(n), do: String.to_integer(n)

  defp media_ext?(path, exts) when is_binary(path) do
    path = String.downcase(path)
    Enum.any?(exts, &String.ends_with?(path, &1))
  end

  defp media_ext?(_path, _exts), do: false

  defp base_uri(opts) do
    case Keyword.get(opts, :base_url) do
      nil -> PlatformWeb.Endpoint.struct_url()
      url -> URI.parse(url)
    end
  end

  # Every link occurrence in document order: anchors, plus bare
  # `/chat/attachments/<uuid>` text outside anchors and code.
  defp occurrences(html, opts) do
    {acc, _state} =
      html
      |> String.split(~r/(<[^>]+>)/, include_captures: true)
      |> Enum.reduce({[], %{in_a: false, in_code: 0}}, fn part, {acc, st} ->
        cond do
          Regex.match?(~r/\A<a\b/i, part) ->
            {anchor_target(part, opts) ++ acc, %{st | in_a: true}}

          Regex.match?(~r/\A<\/a>/i, part) ->
            {acc, %{st | in_a: false}}

          Regex.match?(~r/\A<(code|pre)\b/i, part) ->
            {acc, %{st | in_code: st.in_code + 1}}

          Regex.match?(~r/\A<\/(code|pre)>/i, part) ->
            {acc, %{st | in_code: max(st.in_code - 1, 0)}}

          String.starts_with?(part, "<") or st.in_a or st.in_code > 0 ->
            {acc, st}

          true ->
            {Enum.reverse(text_targets(part)) ++ acc, st}
        end
      end)

    Enum.reverse(acc)
  end

  defp anchor_target(tag, opts) do
    with href when is_binary(href) <- href_of(tag),
         {kind, id, version} <- classify(href, opts) do
      url = decode_entities(href)
      [%{kind: kind, url: url, id: id, version: version, key: key(url, opts)}]
    else
      _ -> []
    end
  end

  defp text_targets(text) do
    @attachment_text
    |> Regex.scan(text, capture: :all)
    |> Enum.map(fn [path, id] ->
      id = String.downcase(id)
      %{kind: :attachment, url: path, id: id, version: nil, key: {:attachment, id, nil}}
    end)
  end

  defp href_of(tag) do
    case Regex.run(~r/\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i, tag) do
      nil -> nil
      captures -> captures |> tl() |> Enum.find(&(&1 != ""))
    end
  end

  defp cap(targets) do
    {kept, _count} =
      Enum.reduce(targets, {[], 0}, fn t, {acc, n} ->
        cond do
          t.kind not in @card_kinds -> {[t | acc], n}
          n < @card_cap -> {[t | acc], n + 1}
          true -> {acc, n}
        end
      end)

    Enum.reverse(kept)
  end

  # Keys of links that sit alone on a paragraph line somewhere in the html.
  defp bare_keys(html, opts) do
    ~r/<p>(.*?)<\/p>/s
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.flat_map(fn [inner] -> split_lines(inner) end)
    |> Enum.map(&bare_key(&1, opts))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  # Earmark (`breaks: true`) separates the lines of one paragraph with
  # `<br>` and a newline.
  defp split_lines(inner), do: String.split(inner, ~r/<br\s*\/?>\n?/i)

  # The key of the single link a line consists of, or nil. A line is bare
  # when it holds exactly one anchor and nothing else (the Earmark autolink
  # shape, `<url>`, or `[label](url)`), or exactly one plain
  # `/chat/attachments/<uuid>` path.
  defp bare_key(line, opts) do
    line = String.trim(line)

    cond do
      match = Regex.run(~r/\A(<a\b[^>]*>)(?:(?!<\/?a\b).)*<\/a>\z/is, line) ->
        [_, open] = match

        case href_of(open) do
          href when is_binary(href) ->
            if classify(href, opts), do: key(decode_entities(href), opts), else: nil

          _ ->
            nil
        end

      match = Regex.run(Regex.compile!("\\A/chat/attachments/(#{@uuid})\\z"), line) ->
        [_, id] = match
        {:attachment, String.downcase(id), nil}

      true ->
        nil
    end
  end

  defp normalize_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        %URI{uri | scheme: String.downcase(scheme), host: String.downcase(host), fragment: nil}
        |> URI.to_string()
        |> String.trim_trailing("/")

      _ ->
        url
    end
  end

  defp decode_entities(s) do
    s
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end
end
