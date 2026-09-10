defmodule Platform.Branding do
  @moduledoc """
  The SINGLE read path for this install's PWA identity — app name, manifest
  colours, and icon URLs (task 01a0879a stage 1).

  ## No cache. On purpose.

  `get/0` hits the database on EVERY call and there is deliberately no ETS
  table and no `:persistent_term` behind it. The entire point of this value
  is that it changes without a restart: upload an icon, refresh, Add to Home
  Screen, see it. A cache is a second place for the value to be stale, which
  is precisely the requirement that would then be failing. One primary-key
  read per render is cheaper than several things `root.html.heex` already
  does on the same render.

  ## A fresh install is a no-op

  With no upload (`source_storage_key` NULL), `icon_url/1` returns the repo's
  existing static paths — today's behaviour byte for byte. The feature only
  starts doing anything once an admin uploads.

  ## Colours

  No raw hex lives in this module. The default colours are seeded by the
  `create_install_branding` migration, which is the one place the literal
  appears; the regex here validates the SHAPE of an admin-supplied value.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Branding.IconSet
  alias Platform.Branding.IconStorage
  alias Platform.Branding.InstallBranding
  alias Platform.Repo
  alias Platform.Tenancy

  @pubsub_topic "install_branding"

  @typedoc """
  The icon variants the app serves. Every one of them has a repo default, so
  every one of them is answerable before any upload exists.
  """
  @type variant ::
          :icon_192
          | :icon_512
          | :icon_512_maskable
          | :apple_touch
          | :favicon_32
          | :favicon_16
          | :favicon_ico

  @variants [
    :icon_192,
    :icon_512,
    :icon_512_maskable,
    :apple_touch,
    :favicon_32,
    :favicon_16,
    :favicon_ico
  ]

  # The paths that ship in `priv/static/images`. The `.ico` lives there too
  # since stage 6 moved it: `/favicon.ico` at the document root is a ROUTE
  # (`BrandingIconController.favicon/2`) that 302s to whatever this returns,
  # so the root probe every client makes follows the upload like the other
  # six. `icon-512-maskable.png` is a build-time artifact: it was
  # produced ONCE by running `IconSet.derive/2` over `icon-source.png` with
  # the seeded background colour and committing the output (stage 5), so the
  # repo default set exercises the same 80% padding rule an upload does and
  # the maskable entry is never the same bytes as the `any` entry.
  @repo_defaults %{
    icon_192: "/images/icon-192.png",
    icon_512: "/images/icon-512.png",
    icon_512_maskable: "/images/icon-512-maskable.png",
    apple_touch: "/images/apple-touch-icon.png",
    favicon_32: "/images/favicon-32.png",
    favicon_16: "/images/favicon-16.png",
    favicon_ico: "/images/favicon.ico"
  }

  @doc "Every variant `icon_url/1` accepts, in a stable order."
  @spec variants() :: [variant()]
  def variants, do: @variants

  @doc "The PubSub topic `update_identity/2` broadcasts on."
  @spec pubsub_topic() :: String.t()
  def pubsub_topic, do: @pubsub_topic

  @doc """
  The singleton branding row. Read fresh every call — see the module note.
  """
  @spec get() :: InstallBranding.t()
  def get do
    Repo.one!(from(b in InstallBranding, limit: 1))
  end

  @spec app_name() :: String.t()
  def app_name, do: get().app_name

  @spec theme_color() :: String.t()
  def theme_color, do: get().theme_color

  @spec background_color() :: String.t()
  def background_color, do: get().background_color

  @doc """
  Absolute path for one icon variant.

  With no upload, this is the repo's own static asset. With an upload, it is
  the versioned public path.

  The versioned path is `/branding/<version>/<variant>`, served by
  `PlatformWeb.BrandingIconController` (stage 3). `versioned_path/2` below is
  the ONLY place in the codebase that knows this shape; do not add a second
  URL scheme elsewhere.
  """
  @spec icon_url(variant()) :: String.t()
  def icon_url(variant) when variant in @variants, do: icon_url(get(), variant)

  @doc """
  `icon_url/1` resolved against an already-loaded row.

  The root layout reads the row ONCE per render and resolves all four of
  its `<link>` hrefs from it (stage 7), so a page render costs one
  primary-key read rather than one per tag.
  """
  @spec icon_url(InstallBranding.t(), variant()) :: String.t()
  def icon_url(%InstallBranding{source_storage_key: nil}, variant) when variant in @variants,
    do: Map.fetch!(@repo_defaults, variant)

  def icon_url(%InstallBranding{} = branding, variant) when variant in @variants,
    do: versioned_path(branding, variant)

  @doc """
  The repo default path for a variant, ignoring any upload. Exposed so
  callers that must reference the shipped asset (and tests that pin it) do
  not re-spell the path.
  """
  @spec default_icon_url(variant()) :: String.t()
  def default_icon_url(variant) when variant in @variants, do: Map.fetch!(@repo_defaults, variant)

  @doc """
  Update the admin-editable identity fields. Fabrikam-admin only.

  The route that hosts the form is gated by
  `PlatformWeb.LiveAuth.on_mount(:ensure_admin, ...)`, but a route gate is
  not an authorization boundary for a context function — anything holding a
  reference to this module can call it. So the check is re-run here, mirroring
  `Platform.Tenancy.Lifecycle`'s `with_fabrikam_admin_authz/2`.

  Broadcasts `{:install_branding_updated, branding}` on `"install_branding"`
  so a form open in a second window re-reads.
  """
  @spec update_identity(any(), map()) ::
          {:ok, InstallBranding.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_identity(actor, attrs) do
    with_fabrikam_admin_authz(actor, fn ->
      get()
      |> InstallBranding.identity_changeset(attrs)
      |> Repo.update()
      |> case do
        {:ok, %InstallBranding{} = branding} ->
          broadcast(branding)
          {:ok, branding}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}
      end
    end)
  end

  @doc """
  Accept an uploaded square, derive the seven variants, and make them the
  install's icons (task 01a0879a stage 2). Fabrikam-admin only, re-checked here
  for the reason `update_identity/2` documents.

  `source` is `{:path, path}` (a `live_file_upload` temp file) or
  `{:binary, bytes}`. Options are passed through to
  `IconStorage.put_source/3` (`:content_type`, `:filename`).

  ## Ordering, which is the whole design

  1. Hash the source. `version` is the first 12 hex chars of the SHA-256 of
     the bytes, so different bytes always get a different version and the
     same bytes are idempotent. Stage 3 puts that token in the URL, so a
     version that failed to change would cache-poison the new icons behind
     the old ones — the same reasoning `AvatarStorage`'s uuid segment
     carries, made content-addressed because we want the idempotence too.
  2. Derive. A failure here has written nothing and touched no row, so the
     PREVIOUS branding is still committed and still serving.
  3. Persist the source and all seven derivatives under the NEW version's
     key prefix. Still no row change; the old version's blobs are untouched
     because the prefix differs.
  4. Write `source_storage_key`, `derived` and `version` in ONE transaction.
     If it fails we delete the blobs we just wrote and the old branding is
     intact.
  5. ONLY THEN delete the previous version's blobs. Deleting before the
     commit would mean a rolled-back update leaves the row pointing at
     bytes that no longer exist — a broken icon on every page, recoverable
     only by re-uploading.
  """
  @spec put_source(any(), {:path, Path.t()} | {:binary, binary()}, keyword()) ::
          {:ok, InstallBranding.t()} | {:error, term()}
  def put_source(actor, source, opts \\ []) do
    with_fabrikam_admin_authz(actor, fn ->
      branding = get()

      with {:ok, bytes} <- read_source(source),
           version = version_for(bytes),
           {:ok, derived_bytes} <- IconSet.derive({:binary, bytes}, branding.background_color),
           {:ok, source_key} <- put_source_blob(version, source, opts),
           {:ok, derived_keys} <- put_derived_blobs(version, derived_bytes) do
        commit(branding, version, source_key, derived_keys)
      end
    end)
  end

  defp commit(branding, version, source_key, derived_keys) do
    result =
      branding
      |> Ecto.Changeset.change(%{
        source_storage_key: source_key,
        derived: derived_keys,
        version: version
      })
      |> Repo.update()

    case result do
      {:ok, %InstallBranding{} = updated} ->
        delete_keys(previous_keys(branding, version))
        broadcast(updated)
        {:ok, updated}

      {:error, %Ecto.Changeset{}} = err ->
        # The row did not move, so the OLD blobs are still the live ones.
        # Roll back the ones we just wrote instead of orphaning them.
        delete_keys([source_key | Map.values(derived_keys)])
        err
    end
  end

  # Everything the old row referenced that the new row does not. The guard
  # matters when the same bytes are re-uploaded: the version is identical,
  # the keys are identical, and deleting "the previous version" would delete
  # the blobs the committed row now points at.
  defp previous_keys(%InstallBranding{version: version}, version), do: []

  defp previous_keys(%InstallBranding{} = branding, _new_version) do
    keys = Map.values(branding.derived || %{})
    if branding.source_storage_key, do: [branding.source_storage_key | keys], else: keys
  end

  defp delete_keys(keys), do: Enum.each(keys, &IconStorage.delete/1)

  defp put_source_blob(version, source, opts) do
    case IconStorage.put_source(version, source, opts) do
      {:ok, %{storage_key: key}} -> {:ok, key}
      {:error, _} = err -> err
    end
  end

  defp put_derived_blobs(version, derived_bytes) do
    Enum.reduce_while(derived_bytes, {:ok, %{}}, fn {variant, bytes}, {:ok, acc} ->
      case IconStorage.put_derived(version, variant, bytes) do
        {:ok, key} -> {:cont, {:ok, Map.put(acc, Atom.to_string(variant), key)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp read_source({:binary, bytes}) when is_binary(bytes), do: {:ok, bytes}

  defp read_source({:path, path}) when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:unreadable_source, reason}}
    end
  end

  defp read_source(_), do: {:error, :unreadable_image}

  # Content-addressed, truncated to 12 hex chars. Long enough that a
  # collision is not a practical concern for a value one admin sets by hand,
  # short enough to read in a URL.
  defp version_for(bytes) do
    :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  end

  defp with_fabrikam_admin_authz(actor, fun) do
    if Tenancy.fabrikam_admin?(actor), do: fun.(), else: {:error, :unauthorized}
  end

  defp broadcast(%InstallBranding{} = branding) do
    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      @pubsub_topic,
      {:install_branding_updated, branding}
    )
  end

  # The one site that knows the served URL shape. It must stay in lockstep
  # with the `/branding/:version/:variant` route and with
  # `BrandingIconController`'s immutable cache header: the version segment is
  # the content hash of the uploaded source, and dropping it would make that
  # header cache the old icon for a year.
  #
  # A row with an upload but no version cannot occur (`commit/4` writes both
  # in one changeset), and a `nil` here would build a URL the controller
  # 404s; falling back to the repo default is the honest answer instead.
  defp versioned_path(%InstallBranding{version: version}, variant)
       when is_binary(version) do
    "/branding/#{version}/#{variant}"
  end

  defp versioned_path(%InstallBranding{}, variant), do: Map.fetch!(@repo_defaults, variant)
end
