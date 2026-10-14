defmodule Platform.Accounts.UserAvatarCache do
  @moduledoc """
  The member avatar the Burrow apps draw on a push notification, served from
  this install at `GET /api/app/users/:id/avatar`
  (`PlatformWeb.UserAvatarController.app_show/2`).

  ## Why the install proxies it

  Both Burrow apps drop an avatar body over 256 KB and draw the letter disc
  instead (`MAX_BYTES` in the Android `AvatarFetcher.kt`, `maxBytes` in the
  iOS `AvatarFetcher.swift`). A member's picture is `users.avatar_url`, an
  absolute url on the identity provider, and the push used to carry it
  verbatim, so a picture over 256 KB silently became a letter. The push now
  carries `push_url/1`, a route on this install, and this module serves the
  picture the way `Platform.Agents.AvatarStorage.app_variant/1` serves agent
  avatars: a source of at most 128 KB unchanged, anything larger as a PNG
  thumbnail of at most 192 px a side, through the same libvips path.

  ## Server-side request forgery

  This module makes the install fetch a url, so it is an SSRF surface. The
  url is ONLY ever `users.avatar_url`, read from the row by the controller;
  nothing in a request chooses it. On top of that every fetch:

    * requires `https` with a host and no userinfo;
    * resolves the host and refuses it if ANY address is one federation
      refuses (`Platform.Federation.Peers.Client.forbidden_address?/1`:
      loopback, RFC 1918, CGNAT, link-local and cloud metadata, unique-local,
      multicast, reserved), then PINS the connection to the checked address
      through `Platform.Federation.Peers.PinnedAdapter`, so a second DNS
      answer is never consulted;
    * follows no redirect (a 3xx is a failure), so a public host cannot
      bounce the fetch inward;
    * is bounded: connect 3 s, the whole response 5 s, at most 5 MB of
      body, never decompressed;
    * accepts only the avatar image types
      (`Platform.Agents.AvatarStorage.allowed_content_types/0`), and only
      bytes libvips reads as an image of at most 50 megapixels.

  Any failure is `{:error, reason}` (the route answers 404 and the app draws
  the letter) and is remembered for ten minutes, so a dead or hostile host
  costs one bounded fetch, not one per notification. While it is remembered,
  `push_url/1` returns nil and the push carries no avatar at all.

  ## Cache

      user-avatars/<user_id>/<sha256(avatar_url)>.orig.<ext>    small source, as fetched
      user-avatars/<user_id>/<sha256(avatar_url)>.thumb192.png  thumbnail of a large one
      user-avatars/<user_id>/<sha256(avatar_url)>.failed        failure marker (mtime)

  Keyed on the hash of the SOURCE url, so a changed `users.avatar_url` misses
  the cache and is fetched afresh; writing a new entry removes the user's
  older ones. `push_url/1` carries the same hash (16 hex) as `?v=`, so the
  apps' url-keyed caches turn over at the same moment. Files are written to a
  temp name and renamed, so a concurrent request never sees a partial file.
  Local-disk-specific, like `AvatarStorage.app_variant/1`.

  ## Tests

  `config :platform, :user_avatar_req_options` is merged into every request
  (`config/test.exs` routes them to the `Req.Test` stub named after this
  module), and `config :platform, :user_avatar_resolver` replaces DNS: a map
  from host to `:inet` address tuples, or a 1-arity function returning
  `{:ok, [ip]}`.
  """

  alias Platform.Accounts.User
  alias Platform.Agents.AvatarStorage
  alias Platform.Chat.AttachmentStorage
  alias Platform.Federation.Peers.Client
  alias Platform.Federation.Peers.PinnedAdapter
  alias Vix.Vips.Image, as: VImage
  alias Vix.Vips.Operation

  require Logger

  @namespace "user-avatars"

  # Same numbers as `AvatarStorage`: 192 is what both apps decode to, and a
  # source at or under half their 256 KB cap is served unchanged.
  @thumbnail_px 192
  @passthrough_bytes 128 * 1024

  @max_source_bytes 5 * 1024 * 1024
  @max_source_pixels 50_000_000
  @connect_timeout 3_000
  @receive_timeout 5_000
  @failure_ttl_seconds 10 * 60

  @doc """
  The url a push carries for `user`'s avatar:
  `https://<install_host>/api/app/users/<id>/avatar?v=<16 hex of sha256(avatar_url)>`.

  nil when the user has no absolute https `avatar_url`, when the install has
  no host, or while a fetch of the current `avatar_url` is remembered as
  failed (the push then omits the avatar and the app draws the letter).
  """
  @spec push_url(User.t() | nil) :: String.t() | nil
  def push_url(%User{id: id} = user) when is_binary(id) do
    with source when is_binary(source) <- source_url(user),
         host when is_binary(host) and host != "" <- Platform.Push.Notification.install_host(),
         false <- recently_failed?(id, digest(source)) do
      "https://#{host}/api/app/users/#{id}/avatar?v=#{binary_part(digest(source), 0, 16)}"
    else
      _ -> nil
    end
  end

  def push_url(_), do: nil

  @doc """
  The user's absolute https `avatar_url` (trimmed), or nil. The only url this
  module ever fetches.
  """
  @spec source_url(User.t() | nil) :: String.t() | nil
  def source_url(%User{avatar_url: url}) when is_binary(url) do
    url = String.trim(url)

    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil}}
      when is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  def source_url(_), do: nil

  @doc """
  The file the app route serves for `user`, as `{:ok, path, content_type}`,
  from the cache or a fresh bounded fetch of `users.avatar_url`; or
  `{:error, reason}`. Never raises.
  """
  @spec app_variant(User.t()) :: {:ok, Path.t(), String.t()} | {:error, term()}
  def app_variant(%User{id: id} = user) when is_binary(id) do
    case source_url(user) do
      nil -> {:error, :no_avatar}
      source -> cached_or_fetch(id, source)
    end
  rescue
    error ->
      Logger.warning("[accounts.user_avatar_cache] failed: #{inspect(error.__struct__)}")
      {:error, :exception}
  end

  def app_variant(_), do: {:error, :no_avatar}

  # ── cache ──────────────────────────────────────────────────────────────

  defp cached_or_fetch(user_id, source) do
    hash = digest(source)

    case cached(user_id, hash) do
      {:ok, _path, _type} = hit ->
        hit

      :miss ->
        if recently_failed?(user_id, hash) do
          {:error, :recently_failed}
        else
          case fetch_and_store(user_id, hash, source) do
            {:ok, _path, _type} = ok ->
              ok

            {:error, reason} = error ->
              # A reason is an atom or a small tuple; never the url.
              Logger.info("[accounts.user_avatar_cache] not served: #{inspect(reason)}")
              mark_failed(user_id, hash)
              error
          end
        end
    end
  end

  defp cached(user_id, hash) do
    thumb = path(user_id, "#{hash}.thumb#{@thumbnail_px}.png")

    if File.regular?(thumb) do
      {:ok, thumb, "image/png"}
    else
      case Path.wildcard(path(user_id, "#{hash}.orig.*")) do
        [orig | _] -> {:ok, orig, AvatarStorage.content_type_for_key(orig)}
        [] -> :miss
      end
    end
  end

  defp fetch_and_store(user_id, hash, source) do
    with {:ok, bytes, content_type} <- fetch(source),
         :ok <- read_image(bytes) do
      if byte_size(bytes) <= @passthrough_bytes do
        store(user_id, hash, "#{hash}.orig#{extension(content_type)}", bytes, content_type)
      else
        with {:ok, png} <- thumbnail(bytes) do
          store(user_id, hash, "#{hash}.thumb#{@thumbnail_px}.png", png, "image/png")
        end
      end
    end
  end

  defp read_image(bytes) do
    case VImage.new_from_buffer(bytes) do
      {:ok, image} ->
        if VImage.width(image) * VImage.height(image) <= @max_source_pixels,
          do: :ok,
          else: {:error, :too_many_pixels}

      {:error, _} ->
        {:error, :not_an_image}
    end
  end

  # `thumbnail_buffer` shrinks on load (a large JPEG never decodes at full
  # size) and reads only the first frame of an animated image;
  # `:VIPS_SIZE_DOWN` never upscales.
  defp thumbnail(bytes) do
    with {:ok, thumb} <-
           Operation.thumbnail_buffer(bytes, @thumbnail_px,
             height: @thumbnail_px,
             size: :VIPS_SIZE_DOWN
           ),
         {:ok, png} <- VImage.write_to_buffer(thumb, ".png") do
      {:ok, png}
    else
      _ -> {:error, :thumbnail_failed}
    end
  end

  defp store(user_id, hash, name, bytes, content_type) do
    final = path(user_id, name)
    dir = Path.dirname(final)
    # A dotfile, so the cache's wildcard lookup never matches a partial write.
    tmp = Path.join(dir, ".#{System.unique_integer([:positive])}.tmp")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, bytes),
         :ok <- File.rename(tmp, final) do
      prune(dir, hash)
      {:ok, final, content_type}
    else
      error ->
        _ = File.rm(tmp)
        {:error, {:cache_write, error}}
    end
  end

  # Entries for an earlier `avatar_url`, and this url's failure marker.
  defp prune(dir, hash) do
    for file <- File.ls!(dir),
        not String.starts_with?(file, "."),
        not String.starts_with?(file, hash) or String.ends_with?(file, ".failed") do
      File.rm(Path.join(dir, file))
    end

    :ok
  end

  defp recently_failed?(user_id, hash) do
    case File.stat(path(user_id, "#{hash}.failed"), time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> System.os_time(:second) - mtime < @failure_ttl_seconds
      _ -> false
    end
  end

  defp mark_failed(user_id, hash) do
    marker = path(user_id, "#{hash}.failed")
    _ = File.mkdir_p(Path.dirname(marker))
    _ = File.write(marker, "")
    :ok
  end

  defp path(user_id, name), do: AttachmentStorage.path_for(Path.join([@namespace, user_id, name]))

  defp digest(source), do: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

  defp extension(content_type) do
    case MIME.extensions(content_type) do
      [ext | _] -> "." <> ext
      [] -> ""
    end
  end

  # ── fetch ──────────────────────────────────────────────────────────────

  defp fetch(source) do
    with {:ok, %{url: target, hostname: hostname}} <- pin(source),
         {:ok, %Req.Response{} = resp} <- request(target, hostname),
         :ok <- check_status(resp),
         {:ok, content_type} <- check_content_type(resp) do
      {:ok, resp.body, content_type}
    end
  end

  defp request(target, hostname) do
    opts =
      [
        method: :get,
        url: target,
        headers: [{"accept", "image/*"}],
        redirect: false,
        retry: false,
        # Never inflated: the byte cap counts the bytes actually kept.
        raw: true,
        compressed: false,
        decode_body: false,
        adapter:
          PinnedAdapter.adapter(hostname,
            connect_timeout: @connect_timeout,
            receive_timeout: @receive_timeout,
            max_body: @max_source_bytes
          ),
        # Only the `Req.Test` plug path streams through `:into`; PinnedAdapter
        # applies the same cap itself.
        into: &collect_capped/2
      ]
      |> Keyword.merge(Application.get_env(:platform, :user_avatar_req_options, []))

    case Req.request(opts) do
      {:ok, %Req.Response{} = resp} ->
        if Req.Response.get_private(resp, :peer_too_large),
          do: {:error, :too_large},
          else: {:ok, resp}

      {:error, _} ->
        {:error, :transport}
    end
  rescue
    _ -> {:error, :transport}
  catch
    _, _ -> {:error, :transport}
  end

  defp collect_capped({:data, data}, {req, resp}) do
    body = if is_binary(resp.body), do: resp.body <> data, else: data

    if byte_size(body) > @max_source_bytes do
      {:halt,
       {req, resp |> Req.Response.put_private(:peer_too_large, true) |> Map.put(:body, "")}}
    else
      {:cont, {req, %{resp | body: body}}}
    end
  end

  defp check_status(%Req.Response{status: 200, body: body}) when is_binary(body) and body != "",
    do: :ok

  defp check_status(%Req.Response{status: status}), do: {:error, {:status, status}}

  defp check_content_type(resp) do
    reported =
      resp
      |> Req.Response.get_header("content-type")
      |> List.first("")
      |> String.split(";")
      |> List.first()
      |> String.trim()
      |> String.downcase()

    if reported in AvatarStorage.allowed_content_types(),
      do: {:ok, reported},
      else: {:error, :not_an_image_type}
  end

  # https, a host, no userinfo; every resolved address public; the request
  # pinned to the address that was checked, with the name kept for Host, SNI
  # and certificate verification.
  defp pin(source) do
    with {:ok, %URI{scheme: "https", host: host, userinfo: nil} = uri}
         when is_binary(host) and host != "" <- URI.new(source),
         {:ok, [ip | _] = addresses} <- resolve(host) do
      case Enum.find(addresses, &Client.forbidden_address?/1) do
        nil ->
          {:ok,
           %{
             url: URI.to_string(%URI{uri | host: ip |> :inet.ntoa() |> to_string()}),
             hostname: host
           }}

        _bad ->
          {:error, :forbidden_address}
      end
    else
      # URI.new's own error carries part of the url; never pass that on.
      {:error, :unresolvable} = error -> error
      _ -> {:error, :malformed_url}
    end
  end

  defp resolve(host) do
    literal =
      host
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> String.to_charlist()
      |> :inet.parse_strict_address()

    result =
      case {literal, Application.get_env(:platform, :user_avatar_resolver, &dns_resolve/1)} do
        {{:ok, ip}, _} -> {:ok, [ip]}
        {_, fun} when is_function(fun, 1) -> fun.(host)
        {_, %{} = static} -> {:ok, Map.get(static, host, [])}
      end

    case result do
      {:ok, [_ | _] = ips} -> {:ok, ips}
      _ -> {:error, :unresolvable}
    end
  end

  defp dns_resolve(host) do
    name = String.to_charlist(host)

    ips =
      Enum.flat_map([:inet, :inet6], fn family ->
        case :inet.getaddrs(name, family) do
          {:ok, list} -> list
          {:error, _} -> []
        end
      end)

    {:ok, ips}
  end
end
