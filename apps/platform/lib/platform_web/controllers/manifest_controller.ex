defmodule PlatformWeb.ManifestController do
  @moduledoc """
  Renders the PWA web app manifest from the install's branding record
  (task `01a0879a` stage 5).

  This replaces the static `priv/static/manifest.json`. Everything that
  identifies the install — `name`, `short_name`, the two colours and the
  three icon `src`s — is read from `Platform.Branding` on EVERY request,
  because the manifest is the document that names the content-versioned
  icon URLs: an upload mints a new version, and the manifest must say so
  on the very next fetch. Hence `cache-control: no-cache` on the response.
  A cached manifest is how an upload appears to have done nothing.

  ## The maskable contract

  The `purpose: "maskable"` entry resolves through its OWN variant
  (`:icon_512_maskable`), so it can never be the same bytes as the `any`
  entry. The static file listed `/images/icon-512.png` twice, and one file
  cannot do both jobs — see `Platform.Branding.IconSet`'s moduledoc.

  ## Ordering caveat for anyone touching `static_paths/0`

  `Plug.Static` runs BEFORE the router. While `manifest.json` is listed in
  `PlatformWeb.static_paths/0` and the file exists, the static file shadows
  this action over HTTP; the cutover (removing both) is stage 6. Until then
  the controller tests call `show/2` directly, on purpose.
  """

  use PlatformWeb, :controller

  alias Platform.Branding

  @content_type "application/manifest+json"

  @doc "The manifest media type, exposed so the tests do not re-spell it."
  @spec content_type() :: String.t()
  def content_type, do: @content_type

  def show(conn, _params) do
    conn
    |> put_resp_content_type(@content_type)
    |> put_resp_header("cache-control", "no-cache")
    |> json(manifest())
  end

  @doc """
  The manifest as a map, built entirely from `Platform.Branding`.

  Field order is kept stable so a diff against the retired static file
  reads field for field.
  """
  @spec manifest() :: map()
  def manifest do
    branding = Branding.get()

    %{
      name: branding.app_name,
      short_name: branding.app_name,
      start_url: "/chat",
      display: "standalone",
      background_color: branding.background_color,
      theme_color: branding.theme_color,
      orientation: "portrait",
      icons: [
        %{src: Branding.icon_url(:icon_192), sizes: "192x192", type: "image/png"},
        %{src: Branding.icon_url(:icon_512), sizes: "512x512", type: "image/png"},
        %{
          src: Branding.icon_url(:icon_512_maskable),
          sizes: "512x512",
          type: "image/png",
          purpose: "maskable"
        }
      ]
    }
  end
end
