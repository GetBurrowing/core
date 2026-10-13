defmodule PlatformWeb.PrototypeController do
  @moduledoc """
  Serves prototype bundles sealed, on this install's own host (ADR 0057
  Decision 1; task 01a1316b-4e46 stage 1).

  ## Routes

    * `GET /proto/:id/latest/*path` — session-authenticated. 302 to the
      numbered version, so the version is always visible in the URL.
    * `GET /proto/:id/:version/*path` — the ENTRY. Session-authenticated: it
      is a navigation the Suite page starts (an iframe `src` or the Open
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
      `PlatformWeb.FileBlobController` does, so only Suite pages can frame a
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
      grant never leaks through `Referer`), and `Cache-Control: private` (a
      version's bytes never change, but a grant does expire).

  ## Honest limits

    * The guarantee is no Suite cookies, no Suite DOM and no Suite API
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
  alias Platform.Tenancy
  alias PlatformWeb.PrototypeGrant

  @bundle_source "'self'"
  @bundle_csp "sandbox allow-scripts; default-src 'none'; " <>
                "script-src #{@bundle_source} 'unsafe-inline'; " <>
                "style-src #{@bundle_source} 'unsafe-inline'; " <>
                "img-src #{@bundle_source} data: blob:; " <>
                "media-src #{@bundle_source} data: blob:; " <>
                "font-src #{@bundle_source} data:; " <>
                "connect-src 'none'; form-action 'none'"

  @cache_control "private, max-age=#{PrototypeGrant.max_age()}"

  @doc false
  def bundle_csp, do: @bundle_csp

  def latest(conn, %{"id" => id} = params) do
    with %Prototype{} = prototype <- Prototypes.get_prototype(id),
         true <- session_member?(conn, prototype),
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
         true <- session_member?(conn, prototype),
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
         true <- Tenancy.member_of?(user, prototype.org_id),
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

  defp with_charset("text/" <> _ = ct), do: ct <> "; charset=utf-8"
  defp with_charset("application/javascript" = ct), do: ct <> "; charset=utf-8"
  defp with_charset("application/json" = ct), do: ct <> "; charset=utf-8"
  defp with_charset(ct), do: ct

  defp session_member?(conn, %Prototype{org_id: org_id}) do
    case get_session(conn, :current_user_id) do
      user_id when is_binary(user_id) ->
        case Accounts.get_user(user_id) do
          %{} = user -> Tenancy.member_of?(user, org_id)
          nil -> false
        end

      _ ->
        false
    end
  end

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
