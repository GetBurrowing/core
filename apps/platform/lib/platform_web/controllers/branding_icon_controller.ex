defmodule PlatformWeb.BrandingIconController do
  @moduledoc """
  Serves the derived PWA icon bytes for this install (task `01a0879a`
  stage 3).

  Structurally this is `PlatformWeb.AgentAvatarController`: same
  `AttachmentStorage.path_for/1` + `send_download/3` body, same
  `x-content-type-options: nosniff`, same allowlist-gated content type read
  back off the storage key. It diverges from it in EXACTLY TWO places, and
  both divergences are the reason the route exists.

  ## Divergence 1 — no authentication at all

  A PWA icon is fetched by the OPERATING SYSTEM at install time, and by the
  browser for a tab favicon: no session, no cookie, no bearer. Every
  byte-serving route we already have refuses that fetcher:

    * `/chat/attachments/:id` → `:attachment_auth` → `Plugs.AttachmentAuth`,
      then `Chat.get_visible_attachment_for_principal/2` — gates on SPACE
      MEMBERSHIP.
    * `/agents/:id/avatar` → `:agent_avatar` → `fetch_session` +
      `Plugs.RequireAuth` — gates on a session.
    * `/files/blob/:id` → the fenced `:require_auth` browser pipeline —
      gates on project org membership.

  The failure mode of reusing one of those is the expensive part: the
  installer gets a 401/redirect, silently substitutes a blank glyph on the
  user's home screen, and nothing is logged as a failure. So this route is
  genuinely public. That is safe because the bytes are a logo an anonymous
  visitor already sees in their browser tab and on the login page; it
  carries no information a viewer did not already have.

  ## Divergence 2 — `cache-control: public, max-age=31536000, immutable`

  `AgentAvatarController` sets `private, no-cache` BECAUSE it sits behind a
  session and a shared proxy must not hand one viewer's response to the
  next. Neither half applies here, so we cache aggressively instead.

  **THIS HEADER DEPENDS ENTIRELY ON THE URL BEING CONTENT-VERSIONED.**
  `:version` is the content hash of the uploaded source
  (`Platform.Branding.put_source/3`), so new bytes always mint a new URL and
  no cache negotiation ever happens — which is what makes "upload, refresh,
  Add to Home Screen" work first try. If someone later drops the version
  segment from the path, this header becomes a bug that takes a YEAR to
  expire from every visitor's browser and every proxy in between, with no
  server-side remedy. Change the header in the same commit, or do not drop
  the segment.

  For the same reason a request whose `:version` does not match the CURRENT
  branding row 404s rather than falling back to the current bytes: an
  immutable-cached URL must never change meaning.

  ## Param handling

  Both segments arrive straight off the URL and are treated as hostile.
  `:variant` is resolved against a FIXED allowlist of the seven names and
  is never interpolated into a storage key — the key comes out of the
  branding row's `derived` map, which only `put_source/3` writes. `:version`
  is only ever COMPARED to the stored token, never used to build a path.
  Unguarded URL input is how `/agents/x/avatar` would have been a 500
  instead of a 404 (see that controller's `fetch_avatar_key/1`).

  `disposition: :inline` is not optional: a download-dispositioned icon is
  not an icon.
  """

  use PlatformWeb, :controller

  alias Platform.Branding
  alias Platform.Branding.IconStorage
  alias Platform.Branding.InstallBranding
  alias Platform.Chat.AttachmentStorage

  # The seven variant names, as the strings that key the `derived` map
  # (`Platform.Branding.put_source/3` stores `Atom.to_string(variant)`).
  # Built from `Branding.variants/0` so a new variant cannot be servable
  # without being declared there first.
  @variant_names Enum.map(Branding.variants(), &Atom.to_string/1)

  def show(conn, %{"version" => version, "variant" => variant})
      when is_binary(version) and is_binary(variant) do
    # Allowlist FIRST, before any row is trusted and before the filesystem
    # is touched: an unrecognized segment must not be able to reach a key
    # lookup at all.
    if variant in @variant_names do
      send_icon(conn, version, variant)
    else
      send_resp(conn, :not_found, "Not found")
    end
  end

  @doc """
  `/favicon.ico` at the document root (stage 6).

  Browsers and crawlers probe this path no matter what the `<head>` links,
  so the shipped static `.ico` used to be the seventh file that did NOT
  follow an upload. It is a 302 to `Branding.icon_url(:favicon_ico)` — the
  moved repo default under `/images/` before any upload, the versioned
  `/branding/<version>/favicon_ico` after — with `cache-control: no-cache`
  because the redirect's TARGET changes on every upload; a cached redirect
  would pin the old icon for exactly as long as the cache lived.
  """
  def favicon(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-cache")
    |> redirect(to: Branding.icon_url(:favicon_ico))
  end

  defp send_icon(conn, version, variant) do
    case fetch_storage_key(version, variant) do
      nil -> send_resp(conn, :not_found, "Not found")
      storage_key -> send_bytes(conn, storage_key)
    end
  end

  defp fetch_storage_key(version, variant) do
    case Branding.get() do
      %InstallBranding{version: stored} = branding
      when is_binary(stored) and stored == version ->
        case Map.get(branding.derived || %{}, variant) do
          key when is_binary(key) and key != "" -> key
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp send_bytes(conn, storage_key) do
    path = AttachmentStorage.path_for(storage_key)

    if File.exists?(path) do
      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> send_download({:file, path},
        filename: Path.basename(storage_key),
        content_type: IconStorage.content_type_for_key(storage_key),
        disposition: :inline
      )
    else
      send_resp(conn, :not_found, "Not found")
    end
  end
end
