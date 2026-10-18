defmodule Platform.Branding.IconStorage do
  @moduledoc """
  Storage for this install's uploaded PWA icon and the seven variants
  derived from it (task `01a0879a` stage 2).

  Modelled on `Platform.Agents.AvatarStorage`, which is modelled on
  `Platform.Files.Storage`, and for the same reason all three give: this is
  a thin re-declaration of the `Platform.Chat.AttachmentStorage` adapter, so
  dev / test (local disk) and prod (R2/S3) behave identically without a
  second wiring path, and operators keep mounting and monitoring ONE volume.

  We re-declare `adapter/0` here rather than calling into
  `AttachmentStorage` because `AttachmentStorage.persist_upload/3` hardcodes
  the `chat/` key prefix (`@storage_prefix`) and keeps its own `adapter/0`
  private.

  ## Bytes go to the mounted volume, never to a column

  The local-disk adapter writes under `:chat_attachments_root`, which
  `config/runtime.exs` resolves to `/data/platform/chat_uploads`. On the
  production host that path is a HOST BIND MOUNT
  (`<host volume>/chat_uploads`), not an
  anonymous volume, so an uploaded icon survives `podman rm` and a redeploy
  — verified on a production host, not assumed from the `VOLUME` line in the Dockerfile,
  which on its own would give an anonymous volume that does NOT survive.

  The database holds only the storage KEY and the derived-key map. A 512px
  PNG in a `bytea` column would be re-read on every page render, because the
  head tags reference every variant.

  ## Key layout

      install-branding/<version>/source.<ext>
      install-branding/<version>/<variant>.png
      install-branding/<version>/favicon_ico.ico

  `<version>` is the content hash of the SOURCE bytes (first 12 hex chars),
  minted by `Platform.Branding.put_source/3`. It plays the role
  `AvatarStorage`'s random uuid segment plays: new bytes MUST land on a new
  key, so the old blob is deleted explicitly rather than overwritten in
  place. Overwriting would make the serving URL cache-poison itself, since
  the URL does not change when the bytes do — and stage 3 puts that version
  token directly in the URL.

  The extension is derived from the RESOLVED content type, never copied from
  the client filename, for the reason `AvatarStorage` documents: no column
  records a blob's content type, so the key IS the content-type record and
  `content_type_for_key/1` reads it back for the serving controller.

  ## Content-type allowlist

  `@allowed_content_types` is `AvatarStorage`'s list unchanged, HEIC/HEIF
  included: the precompiled libvips `vix` resolves (8.18.3) exports
  `heifload`, so the derivation can actually read those sources. SVG stays
  excluded because an SVG can embed `<script>`, and `text/*` stays excluded
  because `text/html` executes as HTML — a "logo" is exactly the file an
  admin would be talked into uploading. Enforcement is here, at consume
  time, NOT in the browser's `accept` attribute, which is a picker hint and
  is trivially bypassed.
  """

  @namespace "install-branding"

  # AvatarStorage's list. See the moduledoc: SVG and text/* are deliberately
  # absent, not forgotten.
  @allowed_content_types ~w(
    image/jpeg
    image/png
    image/gif
    image/webp
    image/heic
    image/heif
  )

  @doc """
  The content types an uploaded branding source may be stored as.

  Exposed so upload surfaces build their `accept` attribute from the same
  list the server enforces, instead of drifting from a second copy.
  """
  @spec allowed_content_types() :: [String.t()]
  def allowed_content_types, do: @allowed_content_types

  @doc "The key namespace, exposed so callers do not re-spell the literal."
  @spec namespace() :: String.t()
  def namespace, do: @namespace

  @doc """
  Persists the ORIGINAL uploaded bytes under `install-branding/<version>/source.<ext>`.

  Keeping the source is what makes a future variant (a new size, a different
  crop rule) re-derivable without asking the admin to upload again.

  ## Options

    * `:content_type` — the client-reported MIME type.
    * `:filename` — the client-reported filename, used to infer the type when
      the reported one is missing or generic.

  Returns `{:ok, %{storage_key: key, content_hash: hex, byte_size: n, content_type: type}}`
  or `{:error, {:unsupported_content_type, reported}}` / `{:error, reason}`.
  """
  @spec put_source(
          version :: String.t(),
          source :: {:path, Path.t()} | {:binary, binary()},
          opts :: keyword()
        ) ::
          {:ok,
           %{
             storage_key: String.t(),
             content_hash: String.t(),
             byte_size: non_neg_integer(),
             content_type: String.t()
           }}
          | {:error, term()}
  def put_source(version, source, opts \\ []) when is_binary(version) do
    filename = Keyword.get(opts, :filename, "source")

    case resolve_content_type(Keyword.get(opts, :content_type), filename) do
      {:ok, content_type} ->
        storage_key = build_key(version, "source" <> extension_for(content_type))

        case adapter().persist(storage_key, source) do
          {:ok, %{byte_size: size, content_hash: hash}} ->
            {:ok,
             %{
               storage_key: storage_key,
               content_hash: hash,
               byte_size: size,
               content_type: content_type
             }}

          {:error, _reason} = err ->
            err
        end

      {:error, _reason} = err ->
        err
    end
  end

  @doc """
  Persists one DERIVED variant.

  The extension comes from the variant, not from anything the client sent:
  six of the seven are PNG because `Platform.Branding.IconSet` writes PNG,
  and `favicon_ico` is `.ico` because it is a real ICO container. Renaming a
  PNG to `.ico` would round-trip through `content_type_for_key/1` as
  `image/x-icon`, which is a second bug wearing the first one's filename.
  """
  @spec put_derived(version :: String.t(), variant :: atom(), bytes :: binary()) ::
          {:ok, String.t()} | {:error, term()}
  def put_derived(version, variant, bytes)
      when is_binary(version) and is_atom(variant) and is_binary(bytes) do
    storage_key = build_key(version, "#{variant}#{variant_extension(variant)}")

    case adapter().persist(storage_key, {:binary, bytes}) do
      {:ok, _} -> {:ok, storage_key}
      {:error, _reason} = err -> err
    end
  end

  @doc "Streams a stored blob back from the adapter."
  @spec get(String.t()) :: {:ok, Enumerable.t()} | {:error, term()}
  def get(storage_key) when is_binary(storage_key), do: adapter().read_stream(storage_key)

  @doc """
  Deletes one blob.

  The caller is responsible for clearing the key from the
  `install_branding` row, and must only call this AFTER that row commits —
  otherwise a rolled-back update leaves the still-referenced bytes gone.
  """
  @spec delete(String.t()) :: :ok
  def delete(storage_key) when is_binary(storage_key), do: adapter().delete(storage_key)

  @doc """
  The canonical key for a blob in one version's directory.

  `install-branding/<version>/<filename>`
  """
  @spec build_key(String.t(), String.t()) :: String.t()
  def build_key(version, filename) when is_binary(version) and is_binary(filename) do
    Path.join([@namespace, sanitize_segment(version), sanitize_segment(filename)])
  end

  @doc """
  Reads the content type back out of a storage key's extension — the inverse
  of the normalization `put_source/3` and `put_derived/3` apply, and the
  reason that normalization exists.

  Allowlist-gated on the way out as well as in: a key written by hand in the
  DB must not be able to talk the serving controller into an arbitrary
  `Content-Type`. `image/x-icon` is allowed OUT (it is what the ICO blob
  genuinely is) but not IN — nobody uploads an ICO as a source. Anything
  unrecognized degrades to `application/octet-stream`, which the
  controller's `nosniff` header keeps inert.
  """
  @spec content_type_for_key(String.t()) :: String.t()
  def content_type_for_key(storage_key) when is_binary(storage_key) do
    case MIME.from_path(storage_key) do
      # The MIME table answers `.ico` with the IANA-registered
      # `image/vnd.microsoft.icon`. We serve `image/x-icon` instead: it is
      # what every browser has accepted since IE, whereas the registered name
      # is not universally recognised. Handled explicitly because the naive
      # allowlist check degraded it to `application/octet-stream`, which
      # `nosniff` then keeps inert — a favicon that never renders.
      type when type in ["image/x-icon", "image/vnd.microsoft.icon"] -> "image/x-icon"
      type when type in @allowed_content_types -> type
      _ -> "application/octet-stream"
    end
  end

  defp variant_extension(:favicon_ico), do: ".ico"
  defp variant_extension(_), do: ".png"

  # Mirrors `AvatarStorage.resolve_content_type/2`, which mirrors
  # `AttachmentStorage.normalize_content_type/2`: iOS Safari labels photos
  # "application/octet-stream" on upload, so a missing or generic label falls
  # back to the filename extension. An out-of-allowlist result is an ERROR,
  # not a downgrade — a chat attachment may be an arbitrary file, an install
  # icon may not.
  defp resolve_content_type(reported, filename)
       when reported in [nil, "", "application/octet-stream"] do
    case MIME.from_path(filename) do
      inferred when inferred in @allowed_content_types -> {:ok, inferred}
      _ -> {:error, {:unsupported_content_type, reported}}
    end
  end

  defp resolve_content_type(reported, _filename) when is_binary(reported) do
    normalized = reported |> String.split(";") |> List.first() |> String.trim()

    if normalized in @allowed_content_types do
      {:ok, normalized}
    else
      {:error, {:unsupported_content_type, reported}}
    end
  end

  defp resolve_content_type(reported, _filename),
    do: {:error, {:unsupported_content_type, reported}}

  defp extension_for(content_type) do
    case MIME.extensions(content_type) do
      [ext | _] -> "." <> ext
      [] -> ""
    end
  end

  # `Path.basename/1` alone is NOT enough: it maps "../../etc" to "etc", but
  # it maps ".." to ".." unchanged, and the dot survives the character class
  # below because legitimate segments carry extensions. A version segment of
  # ".." would then build "install-branding/../source.png", which resolves
  # OUTSIDE the namespace. Today's only caller mints the segment from a
  # content hash, so nothing reaches this — which is exactly why the escape
  # would go unnoticed until a caller passed something else.
  defp sanitize_segment(segment) do
    segment
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "icon"
      dots when dots in [".", ".."] -> "icon"
      sanitized -> sanitized
    end
  end

  # Dispatches through the chat-attachment adapter so dev/prod parity is
  # automatic, exactly as `AvatarStorage` and `Files.Storage` do.
  defp adapter do
    Application.get_env(
      :platform,
      :attachment_storage_adapter,
      Platform.Chat.AttachmentStorage.Adapter.LocalDisk
    )
  end
end
