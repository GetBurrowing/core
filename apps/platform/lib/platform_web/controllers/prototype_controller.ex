defmodule PlatformWeb.PrototypeController do
  @moduledoc """
  Serves prototype bundles sealed, on this install's own host (ADR 0057
  Decision 1; task 01a1316b-4e46 stage 1).

  ## Routes

    * `GET /proto/:id/latest/*path` — session-authenticated. 302 to the
      numbered version, so the version is always visible in the URL.
    * `GET /proto/:id/:version/*path` — the ENTRY. Session-authenticated: it
      is a navigation the Burrow page starts (an iframe `src` or the Open
      button), so the session cookie is sent. After the membership check it
      302s to the grant URL below. With no path it lands on the version's
      `entry_path`.
    * `GET /proto/:id/:version/g/:grant/*path` — every bundle file. Carries
      no session (see `PlatformWeb.PrototypeGrant` for why and for the
      measurement): the grant is verified, must be bound to THIS prototype
      and version, and the grant's user must still be a member of the
      prototype's org (`Tenancy.member_of?/2`), so removing a member revokes
      their grants on the next request.

  Non-members, unknown ids, unknown versions, removed versions and unknown
  paths all get the same 404: existence is never confirmed. Query strings
  are ignored by the server and carried through every redirect, so a
  `?screen=2` deep link reaches the bundle's own script unchanged. A
  directory path serves its `index.html`.

  ## Response headers on every bundle file

    * The sandbox CSP is APPENDED to what `put_secure_browser_headers` set
      (`base-uri 'self'; frame-ancestors 'self'`), exactly as
      `PlatformWeb.FileBlobController` does, so only Burrow pages can frame a
      bundle. `sandbox allow-scripts` with no `allow-same-origin` gives the
      document an opaque origin; `'self'` admits the bundle's own files as
      script, style, image, media and font sources. The spike measured that
      `'self'` matches them under an opaque origin (CSP3 takes `'self'` from
      the response URL, not the document's origin), with a positive control
      in which a non-matching source blocked every one of them.
    * The SAME sandbox applies to a top-level open (stage 2's Open button
      opens the bundle full-size in a new tab); a top-level sandboxed
      document is still opaque-origin.
    * `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer` (so a
      grant never leaks through `Referer`), and `Cache-Control: private,
      no-cache`. A version's bytes never change, but the grant is revocable:
      the membership check above only runs if the request reaches the
      server. With `max-age` a browser served a re-navigated grant URL from
      its disk cache for up to an hour after the minting user left the org
      (member 2's review). `no-cache` makes every use revalidate, so
      revocation shows on the next navigation.

  ## The room bridge (task 01a1316b-84fa stage 2)

  Every `text/html` response gets `priv/prototype/suite.js` inserted as ONE
  inline `<script data-suite-bridge>` right after the opening `<head>` tag
  (or, with no head, after the doctype, else at the very start), by
  `inject_bridge/1`. That is what makes a bundle multiplayer with no opt-in:
  the entry page, an in-frame navigation to `b.html` and any other HTML file
  served here all carry `window.suite`. Only the response is transformed:
  the stored bytes and the manifest sha256 are untouched, and every
  non-HTML file is sent byte-for-byte. The CSP is unchanged (it already
  admits `'unsafe-inline'` script); the bridge talks to the parent page by
  `postMessage` only, so `connect-src 'none'` still holds.

  ## Honest limits

    * The guarantee is no Burrow cookies, no Burrow DOM and no Burrow API
      reachable from a bundle. It is NOT zero exfiltration: CSP3 has no
      `navigate-to`, so script in the frame can navigate its own frame to an
      outside URL carrying whatever the user typed into the bundle.
    * A grant URL is a bearer capability for one version until it expires or
      its minting user leaves the org. A non-member without a grant always
      gets 404.
    * A bundle path beginning `g/<segment>/` is shadowed at the entry route by
      the grant route; it is still served normally under a grant.
  """

  use PlatformWeb, :controller

  alias Platform.Accounts
  alias Platform.Prototypes
  alias Platform.Prototypes.Prototype
  alias Platform.Prototypes.Storage
  alias Platform.Prototypes.Version
  alias PlatformWeb.PrototypeGrant

  @bundle_source "'self'"
  @bundle_csp "sandbox allow-scripts; default-src 'none'; " <>
                "script-src #{@bundle_source} 'unsafe-inline'; " <>
                "style-src #{@bundle_source} 'unsafe-inline'; " <>
                "img-src #{@bundle_source} data: blob:; " <>
                "media-src #{@bundle_source} data: blob:; " <>
                "font-src #{@bundle_source} data:; " <>
                "connect-src 'none'; form-action 'none'"

  # Revalidate every time: see "Response headers" in the moduledoc.
  @cache_control "private, no-cache"

  @suite_js_path Path.expand("../../../priv/prototype/suite.js", __DIR__)
  @external_resource @suite_js_path
  @suite_js File.read!(@suite_js_path)
  @bridge_tag ~s(<script data-suite-bridge="1">) <> @suite_js <> "</script>"

  @doc false
  def bundle_csp, do: @bundle_csp

  @doc false
  # The exact tag `inject_bridge/1` inserts, for tests.
  def bridge_tag, do: @bridge_tag

  @doc """
  Insert the room bridge (`priv/prototype/suite.js`) into an HTML document:
  right after the first `<head ...>` tag; with no head tag, after a leading
  doctype (so the document never drops into quirks mode); otherwise at the
  very start. Kept as one small function of its own so a rebase against a
  sibling change to `send_file/2` stays a one-line conflict.
  """
  @spec inject_bridge(binary()) :: binary()
  def inject_bridge(html) when is_binary(html) do
    at =
      case Regex.run(~r/<head(?:\s[^>]*)?>/i, html, return: :index) do
        [{start, len}] ->
          start + len

        nil ->
          case Regex.run(~r/\A(?:\xEF\xBB\xBF)?\s*<!doctype[^>]*>/i, html, return: :index) do
            [{start, len}] -> start + len
            nil -> 0
          end
      end

    binary_part(html, 0, at) <> @bridge_tag <> binary_part(html, at, byte_size(html) - at)
  end

  def latest(conn, %{"id" => id} = params) do
    with %Prototype{} = prototype <- Prototypes.get_prototype(id),
         true <- Prototypes.readable_by?(session_user(conn), prototype),
         %Version{} <- Prototypes.get_live_version(prototype.id, prototype.latest_version) do
      redirect_to(
        conn,
        ["proto", prototype.id, Integer.to_string(prototype.latest_version)],
        params
      )
    else
      _ -> not_found(conn)
    end
  end

  def entry(conn, %{"id" => id, "version" => version} = params) do
    with {:ok, version} <- parse_version(version),
         %Prototype{} = prototype <- Prototypes.get_prototype(id),
         true <- Prototypes.readable_by?(session_user(conn), prototype),
         %Version{} = row <- Prototypes.get_live_version(prototype.id, version) do
      user_id = get_session(conn, :current_user_id)
      grant = PrototypeGrant.sign(user_id, prototype.id, version)
      base = ["proto", prototype.id, Integer.to_string(version), "g", grant]

      case Map.get(params, "path", []) do
        [] -> redirect_to(conn, base ++ String.split(row.entry_path, "/"), %{})
        _ -> redirect_to(conn, base, params)
      end
    else
      _ -> not_found(conn)
    end
  end

  def serve(conn, %{"id" => id, "version" => version, "grant" => grant} = params) do
    with {:ok, version} <- parse_version(version),
         %Prototype{} = prototype <- Prototypes.get_prototype(id),
         {:ok, user_id} <- PrototypeGrant.verify(grant, prototype.id, version),
         %{archived_at: nil} = user <- Accounts.get_user(user_id),
         true <- Prototypes.readable_by?(user, prototype),
         %Version{} = row <- Prototypes.get_live_version(prototype.id, version) do
      segments = Map.get(params, "path", [])
      serve_path(conn, row, segments)
    else
      _ -> not_found(conn)
    end
  end

  defp serve_path(conn, row, segments) do
    rel = Enum.join(segments, "/")

    path =
      cond do
        rel == "" -> row.entry_path
        String.ends_with?(conn.request_path, "/") -> rel <> "/index.html"
        true -> rel
      end

    case Version.file(row, path) do
      %{} = file ->
        send_file(conn, file)

      nil ->
        # `dir` with a `dir/index.html` redirects to `dir/`, so relative links
        # inside that index resolve under the directory.
        if rel != "" and not String.ends_with?(conn.request_path, "/") and
             Version.file(row, rel <> "/index.html") do
          conn
          |> put_resp_header("referrer-policy", "no-referrer")
          |> redirect(external: conn.request_path <> "/" <> query_suffix(conn.query_string))
        else
          not_found(conn)
        end
    end
  end

  defp send_file(conn, %{"storage_key" => key, "content_type" => content_type}) do
    case Storage.read(key) do
      {:ok, bytes} ->
        bytes = if html?(content_type), do: inject_bridge(bytes), else: bytes

        conn
        |> put_resp_header("content-type", with_charset(content_type))
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("referrer-policy", "no-referrer")
        |> put_resp_header("cache-control", @cache_control)
        |> append_csp()
        |> send_resp(200, bytes)

      {:error, _} ->
        not_found(conn)
    end
  end

  # APPENDS rather than sets, for the reason FileBlobController documents:
  # replacing the header would drop `frame-ancestors 'self'` and `base-uri`.
  defp append_csp(conn) do
    existing =
      case get_resp_header(conn, "content-security-policy") do
        [value | _] -> String.trim(value)
        [] -> ""
      end

    existing =
      if existing == "" or String.ends_with?(existing, ";"), do: existing, else: existing <> ";"

    put_resp_header(conn, "content-security-policy", String.trim(existing <> " " <> @bundle_csp))
  end

  defp html?(content_type) when is_binary(content_type),
    do: String.starts_with?(content_type, "text/html")

  defp html?(_content_type), do: false

  defp with_charset("text/" <> _ = ct), do: ct <> "; charset=utf-8"
  defp with_charset("application/javascript" = ct), do: ct <> "; charset=utf-8"
  defp with_charset("application/json" = ct), do: ct <> "; charset=utf-8"
  defp with_charset(ct), do: ct

  defp session_user(conn) do
    case get_session(conn, :current_user_id) do
      user_id when is_binary(user_id) -> Accounts.get_user(user_id)
      _ -> nil
    end
  end

  # Membership and RBAC v2 (`canvas.read` on the prototype's canvas,
  # `chat.read` on its space) are `Prototypes.readable_by?/2`, shared with the
  # chat prototype card. `serve/2` runs it on EVERY request, so a grant URL
  # minted before a deny or an org exit is refused on its next use; a refusal
  # is the same 404 as an unknown id.

  defp parse_version(version) when is_binary(version) do
    case Integer.parse(version) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  # `base` segments are ours; the request's `path` segments are re-encoded so
  # a decoded `a b.html` goes back out as `a%20b.html`. A trailing slash and
  # the query string are carried over.
  defp redirect_to(conn, base, params) do
    tail = Map.get(params, "path", [])
    segments = Enum.map(base ++ tail, &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))
    slash = if tail != [] and String.ends_with?(conn.request_path, "/"), do: "/", else: ""
    slash = if tail == [] and base_dir?(base), do: "/", else: slash

    location = "/" <> Enum.join(segments, "/") <> slash <> query_suffix(conn.query_string)

    conn
    |> put_resp_header("referrer-policy", "no-referrer")
    |> redirect(external: location)
  end

  # A redirect to a version root (`/proto/<id>/<n>`) or a bare grant root must
  # end in `/`, or the bundle's relative links resolve one level too high.
  defp base_dir?(["proto", _id, _version]), do: true
  defp base_dir?(["proto", _id, _version, "g", _grant]), do: true
  defp base_dir?(_), do: false

  defp query_suffix(""), do: ""
  defp query_suffix(nil), do: ""
  defp query_suffix(qs), do: "?" <> qs

  defp not_found(conn) do
    conn
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_content_type("text/plain")
    |> send_resp(:not_found, "Not found")
  end
end
