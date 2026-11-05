defmodule Platform.Chat.LinkUnfurls do
  @moduledoc """
  Rich previews for outside links in chat (task 01a1a944 stage 2): fetched
  server-side, stored per normalised URL in `link_unfurls`
  (`Platform.Chat.LinkUnfurl`), read back by URL key.

  Nothing in chat calls this yet; stage 3 wires `ensure/2` into message
  posts and `get_many/1` into `Platform.Chat.LinkCards`.

  ## Fetch

  `ensure/2` spawns the fetch under `Platform.TaskSupervisor` (core has no
  job runner). The fetch goes through `Platform.Chat.LinkUnfurls.Fetcher`,
  the SSRF-guarded HTTP path (see its moduledoc), first for the page itself
  (`Platform.Chat.LinkUnfurls.Parser`: OpenGraph, Twitter card, then
  `<title>`), then, for a provider in the fixed oEmbed table
  (`Platform.Chat.LinkUnfurls.OEmbed`), for its oEmbed JSON. For those
  providers oEmbed's title, author (the channel, for a video), thumbnail and
  duration win. A page the guard refuses is stored `refused` and nothing
  more is fetched for it, oEmbed included.

  ## Cache

    * `ok` rows expire after 7 days; `failed` and `refused` rows after 1 hour
      (a negative cache, so a dead or hostile URL costs one bounded fetch per
      hour, not one per message); a `pending` row after 2 minutes, so a fetch
      that died is retried.
    * `ensure/2` returns `:cached` for a fresh row of ANY status. Otherwise
      it claims the URL with one `INSERT ... ON CONFLICT (url_key) DO UPDATE
      ... WHERE link_unfurls.expires_at < now()`: only the caller whose
      statement inserted or updated the row spawns the fetch, so two
      messages posting the same URL at once fetch it once.
  """

  import Ecto.Query

  alias Platform.Chat.LinkUnfurl
  alias Platform.Chat.LinkUnfurls.{Fetcher, OEmbed, Parser}
  alias Platform.Repo

  @ok_ttl_s 7 * 24 * 3600
  @negative_ttl_s 3600
  @pending_ttl_s 120

  @json_types ["application/json", "text/json", "text/javascript"]

  @doc """
  The cache key of `url`: lowercased scheme and host, default port dropped,
  fragment dropped, `utm_*` query parameters dropped, the rest of the query
  kept in order (YouTube's `v=` lives there), an empty path as `/`. nil for
  anything that is not an absolute http(s) URL.
  """
  @spec normalize(String.t()) :: String.t() | nil
  def normalize(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        scheme = String.downcase(scheme)

        if scheme in ["http", "https"] and host != "" do
          URI.to_string(%URI{
            uri
            | scheme: scheme,
              host: String.downcase(host),
              port: if(uri.port == URI.default_port(scheme), do: nil, else: uri.port),
              path: if(uri.path in [nil, ""], do: "/", else: uri.path),
              query: drop_utm(uri.query),
              fragment: nil
          })
        end

      _ ->
        nil
    end
  end

  def normalize(_url), do: nil

  defp drop_utm(nil), do: nil

  defp drop_utm(query) do
    kept =
      query
      |> String.split("&")
      |> Enum.reject(fn pair ->
        pair == "" or
          pair
          |> String.split("=", parts: 2)
          |> hd()
          |> String.downcase()
          |> String.starts_with?("utm_")
      end)

    if kept == [], do: nil, else: Enum.join(kept, "&")
  end

  @doc "The fresh row for `url` (any status), or nil."
  @spec get_fresh(String.t()) :: LinkUnfurl.t() | nil
  def get_fresh(url) do
    case normalize(url) do
      nil -> nil
      key -> Repo.one(from(u in LinkUnfurl, where: u.url_key == ^key and u.expires_at > ^now()))
    end
  end

  @doc "Fresh rows (any status) for a list of url keys, as `%{url_key => row}`. One query."
  @spec get_many([String.t()]) :: %{String.t() => LinkUnfurl.t()}
  def get_many([]), do: %{}

  def get_many(url_keys) when is_list(url_keys) do
    from(u in LinkUnfurl, where: u.url_key in ^Enum.uniq(url_keys) and u.expires_at > ^now())
    |> Repo.all()
    |> Map.new(&{&1.url_key, &1})
  end

  @doc """
  Make sure a preview for `url` exists or is being fetched.

    * `:cached`: a fresh row (any status) already exists, or another caller
      just claimed the fetch;
    * `:started`: this call claimed it and spawned the fetch; `on_done` is
      called with the stored row when the fetch finishes;
    * `:skipped`: `url` is not an absolute http(s) URL.

  Never blocks on the network and never raises for a bad URL.
  """
  @spec ensure(String.t(), (LinkUnfurl.t() -> any())) :: :cached | :started | :skipped
  def ensure(url, on_done \\ fn _ -> :ok end) when is_function(on_done, 1) do
    case normalize(url) do
      nil ->
        :skipped

      key ->
        cond do
          fresh?(key) ->
            :cached

          claim(key, url) ->
            spawn_fetch(key, on_done)
            :started

          true ->
            :cached
        end
    end
  end

  defp fresh?(key),
    do: Repo.exists?(from(u in LinkUnfurl, where: u.url_key == ^key and u.expires_at > ^now()))

  # Insert a pending row, or take over an EXPIRED one. A fresh row of any
  # status makes the conflict's WHERE false, so the statement touches
  # nothing and returns no row: this caller lost.
  defp claim(key, url) do
    now = now()
    expires = DateTime.add(now, @pending_ttl_s, :second)

    row = %{
      id: Platform.Types.UUIDv7.generate(),
      url_key: key,
      url: url,
      status: "pending",
      expires_at: expires,
      inserted_at: now,
      updated_at: now
    }

    takeover =
      from(u in LinkUnfurl,
        where: u.expires_at < ^now,
        update: [set: [status: "pending", url: ^url, expires_at: ^expires, updated_at: ^now]]
      )

    {count, _} =
      Repo.insert_all(LinkUnfurl, [row],
        on_conflict: takeover,
        conflict_target: [:url_key],
        returning: [:id]
      )

    count == 1
  end

  defp spawn_fetch(key, on_done) do
    Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
      try do
        key |> fetch() |> store(key) |> notify(on_done)
      rescue
        # Under the DataCase sandbox a fetch that outlives its test has no
        # connection; that is the test ending, not a failure to report.
        DBConnection.OwnershipError -> :ok
      end
    end)
  end

  defp notify({:ok, row}, on_done) do
    on_done.(row)
  rescue
    _ -> :ok
  end

  defp notify(_other, _on_done), do: :ok

  @doc false
  # The outcome of fetching `url`: `{status, attrs}`. Public for tests.
  @spec fetch(String.t()) :: {String.t(), map()}
  def fetch(url) do
    case Fetcher.get(url) do
      {:error, {:refused, _reason}} ->
        {"refused", %{}}

      page_result ->
        page =
          case page_result do
            {:ok, %{url: final_url, body: body}} -> Parser.parse(body, final_url)
            {:error, _} -> nil
          end

        oembed =
          case OEmbed.endpoint(url) do
            {provider, endpoint} -> fetch_oembed(provider, endpoint)
            nil -> nil
          end

        merge(url, page, oembed)
    end
  end

  defp fetch_oembed(provider, endpoint) do
    case Fetcher.get(endpoint, accept: "application/json", types: @json_types) do
      {:ok, %{body: body}} -> OEmbed.parse(body, provider)
      {:error, _} -> nil
    end
  end

  defp merge(_url, nil, nil), do: {"failed", %{}}

  defp merge(url, page, oembed) do
    page = page || Parser.empty()
    o = oembed || %{}

    {image_url, width, height} =
      case o[:thumbnail_url] do
        nil -> {page.image_url, page.image_width, page.image_height}
        thumb -> {thumb, o[:thumbnail_width], o[:thumbnail_height]}
      end

    attrs = %{
      title: o[:title] || page.title,
      description: page.description,
      image_url: image_url,
      image_width: width,
      image_height: height,
      site_name: page.site_name || o[:provider_name] || host(url),
      author: o[:author] || page.author,
      provider: o[:provider],
      media_kind: media_kind(o[:type], page.og_type),
      duration_seconds: o[:duration_seconds] || page.duration_seconds
    }

    if attrs.title || attrs.description || attrs.image_url,
      do: {"ok", attrs},
      else: {"failed", %{}}
  end

  defp media_kind("video", _og), do: "video"
  defp media_kind(_type, "video" <> _), do: "video"
  defp media_kind(_type, "article"), do: "article"
  defp media_kind(_type, _og), do: "other"

  defp host(url), do: URI.parse(url).host

  @blank %{
    title: nil,
    description: nil,
    image_url: nil,
    image_width: nil,
    image_height: nil,
    site_name: nil,
    author: nil,
    provider: nil,
    media_kind: nil,
    duration_seconds: nil
  }

  defp store({status, attrs}, key) do
    now = now()
    ttl = if status == "ok", do: @ok_ttl_s, else: @negative_ttl_s

    set =
      @blank
      |> Map.merge(attrs)
      |> Map.merge(%{
        status: status,
        fetched_at: now,
        expires_at: DateTime.add(now, ttl, :second),
        updated_at: now
      })
      |> Enum.to_list()

    case Repo.update_all(from(u in LinkUnfurl, where: u.url_key == ^key, select: u), set: set) do
      {1, [row]} -> {:ok, row}
      _ -> :gone
    end
  end

  defp now, do: DateTime.utc_now()
end
