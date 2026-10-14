defmodule Platform.Agents.AvatarStorage do
  @moduledoc """
  Storage for agent avatar images (task `01a00122` stage 1).

  Modelled on `Platform.Files.Storage`, and for the same reason: it is a
  thin wrapper over the `Platform.Chat.AttachmentStorage` adapter, so dev /
  test (local disk) and prod (R2/S3) behave identically without a second
  wiring path, and operators keep mounting and monitoring one volume.

  We re-declare `adapter/0` here rather than calling into
  `AttachmentStorage` because `AttachmentStorage.persist_upload/3` hardcodes
  the `chat/` key prefix (`@storage_prefix`) and its own `adapter/0` is
  private. `Files.Storage` re-declares it for exactly this reason; this
  module follows.

  ## Key layout

      agent-avatars/<agent_id>/<uuid>-<name>.<ext>

  The `agent-avatars/` namespace keeps avatars visually distinct from the
  `chat/` and `files/` namespaces already in the bucket, so an operator
  listing it can tell the three apart at a glance.

  The random `uuid` segment is load-bearing, not decoration: replacing an
  agent's avatar must produce a NEW key so the old blob can be deleted
  explicitly (via the `agents.avatar_storage_key` column) instead of being
  overwritten in place. Overwriting would make the serving URL cache-poison
  itself, since the URL does not change when the bytes do.

  The extension is normalized from the RESOLVED content type rather than
  copied from the client filename. Nothing stores an avatar's content type
  in a column — the schema carries only `avatar_url` and
  `avatar_storage_key` — so the key IS the content-type record, and
  `content_type_for_key/1` reads it back for the serving controller. A key
  whose extension came from attacker-controlled input could not be trusted
  that way.

  ## Content-type allowlist

  `@allowed_content_types` is the `@safe_override_types` list from
  `Platform.Chat.AttachmentStorage` MINUS `application/pdf` (a PDF is not an
  avatar). The exclusions carry over with their original reasoning: SVG is
  excluded because SVG can embed `<script>`, and `text/*` is excluded
  because `text/html` executes as HTML. Enforcement is here, at consume
  time, NOT in the browser's `accept` attribute — that attribute is a file
  picker hint and is trivially bypassed.
  """

  alias Platform.Chat.AttachmentStorage
  alias Vix.Vips.Image, as: VImage
  alias Vix.Vips.Operation

  require Logger

  @namespace "agent-avatars"

  # The native app's avatar route serves a thumbnail of at most this many
  # pixels a side (`app_variant/1`). 192 is the size both Burrow apps decode
  # to (`MAX_PX` on Android, `maxPixels` on iOS).
  @thumbnail_px 192

  # Originals at or under this size are served to the app unchanged: half the
  # apps' 256 KB cap, so anything that passes through is comfortably inside it.
  @thumbnail_passthrough_bytes 128 * 1024

  # The AttachmentStorage safe-override list minus application/pdf. See the
  # moduledoc: SVG and text/* are deliberately absent, not forgotten.
  @allowed_content_types ~w(
    image/jpeg
    image/png
    image/gif
    image/webp
    image/heic
    image/heif
  )

  @doc """
  The content types an avatar may be stored as.

  Exposed so upload surfaces can build their `accept` attribute from the
  same list the server enforces, instead of drifting from a second copy.
  """
  @spec allowed_content_types() :: [String.t()]
  def allowed_content_types, do: @allowed_content_types

  @doc """
  Persists avatar bytes (a temp file path or an in-memory binary) under an
  agent-scoped key.

  ## Options

    * `:content_type` — the client-reported MIME type.
    * `:filename` — the client-reported filename, used to infer the type
      when the reported one is missing or generic, and to keep the stored
      key human-legible.

  ## Returns

      {:ok, %{storage_key: key, content_hash: hex, byte_size: n, content_type: type}}

  …or `{:error, {:unsupported_content_type, reported}}` when the resolved
  type is outside the allowlist, or `{:error, reason}` from the adapter.

  Callers write the returned `:storage_key` to `agents.avatar_storage_key`
  and are responsible for deleting the PREVIOUS key if there was one.
  """
  @spec put(
          source :: {:path, Path.t()} | {:binary, binary()},
          agent_id :: binary(),
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
  def put(source, agent_id, opts \\ []) when is_binary(agent_id) do
    filename = Keyword.get(opts, :filename, "avatar")

    case resolve_content_type(Keyword.get(opts, :content_type), filename) do
      {:ok, content_type} ->
        storage_key = build_key(agent_id, stored_name(filename, content_type))

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
  Streams the avatar bytes back from the adapter.

  Returns `{:ok, stream}` or `{:error, reason}`.
  """
  @spec get(String.t()) :: {:ok, Enumerable.t()} | {:error, term()}
  def get(storage_key) when is_binary(storage_key), do: adapter().read_stream(storage_key)

  @doc """
  Deletes the underlying blob.

  The caller is responsible for clearing `agents.avatar_storage_key` and
  `agents.avatar_url` on the row.
  """
  @spec delete(String.t()) :: :ok
  def delete(storage_key) when is_binary(storage_key) do
    # The app thumbnail is derived from this blob and named after it, so it
    # goes with it. Deleting a thumbnail that was never generated is a no-op.
    _ = adapter().delete(thumbnail_key(storage_key))
    adapter().delete(storage_key)
  end

  @doc """
  The file the native app's avatar route serves for `storage_key`, as
  `{:ok, path, content_type}`, or `{:error, :not_found}` when the blob is
  missing.

  Both Burrow apps drop an avatar body over 256 KB (`MAX_BYTES` in the
  Android `AvatarFetcher.kt`, `maxBytes` in the iOS `AvatarFetcher.swift`)
  and draw the letter disc instead, while uploads allow 5 MB and are stored
  unresized. So:

    * an original of at most 128 KB is served as-is (it
      already fits, and re-encoding it gains nothing);
    * anything larger is served as a PNG thumbnail of at most
      192 px on a side. A 192 x 192 RGBA image is 147,456 bytes raw, so
      the PNG stays well under the 256 KB cap whatever the source.

  The thumbnail is generated on first request and cached next to the
  original under `thumbnail_key/1`. Because the original's key carries a
  random uuid that changes on every replacement, the cached thumbnail can
  never go stale, and avatars that existed before this function did get
  theirs on their first fetch: no backfill, no migration.

  If the original cannot be thumbnailed (a format this libvips build does
  not read), the original is served, which is exactly the behaviour before
  thumbnails existed. The content type always describes the bytes at the
  returned path.

  Local-disk-specific, like the serving controller (`AttachmentStorage.path_for/1`).
  """
  @spec app_variant(String.t()) ::
          {:ok, Path.t(), String.t()} | {:error, :not_found}
  def app_variant(storage_key) when is_binary(storage_key) do
    path = AttachmentStorage.path_for(storage_key)

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @thumbnail_passthrough_bytes ->
        {:ok, path, content_type_for_key(storage_key)}

      {:ok, %File.Stat{type: :regular}} ->
        case ensure_thumbnail(storage_key, path) do
          {:ok, thumb_path} ->
            {:ok, thumb_path, "image/png"}

          {:error, reason} ->
            Logger.warning(
              "[agents.avatar_storage] thumbnail failed, serving original: reason=#{inspect(reason)}"
            )

            {:ok, path, content_type_for_key(storage_key)}
        end

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  The storage key of the app thumbnail derived from `storage_key`:
  `<key without extension>.thumb192.png`, beside the original.
  """
  @spec thumbnail_key(String.t()) :: String.t()
  def thumbnail_key(storage_key) when is_binary(storage_key) do
    Path.rootname(storage_key) <> ".thumb#{@thumbnail_px}.png"
  end

  defp ensure_thumbnail(storage_key, source_path) do
    thumb_path = AttachmentStorage.path_for(thumbnail_key(storage_key))

    if File.regular?(thumb_path) do
      {:ok, thumb_path}
    else
      generate_thumbnail(source_path, thumb_path)
    end
  end

  # `Operation.thumbnail/3` opens the FILE itself, so libvips can shrink on
  # load (a large JPEG never decodes at full size) and reads only the first
  # frame of an animated GIF. `:VIPS_SIZE_DOWN` never upscales.
  #
  # Written to a sibling temp file and renamed into place, so a concurrent
  # request for the same avatar never serves a half-written PNG; two racing
  # generators each rename a complete file, and either one is correct.
  defp generate_thumbnail(source_path, thumb_path) do
    tmp = thumb_path <> ".#{System.unique_integer([:positive])}.tmp"

    with {:ok, image} <-
           Operation.thumbnail(source_path, @thumbnail_px,
             height: @thumbnail_px,
             size: :VIPS_SIZE_DOWN
           ),
         {:ok, bytes} <- VImage.write_to_buffer(image, ".png"),
         :ok <- File.mkdir_p(Path.dirname(thumb_path)),
         :ok <- File.write(tmp, bytes),
         :ok <- File.rename(tmp, thumb_path) do
      {:ok, thumb_path}
    else
      error ->
        _ = File.rm(tmp)
        {:error, error}
    end
  end

  @doc """
  Builds the canonical storage key for an agent avatar.

  ## Layout

      agent-avatars/<agent_id>/<filename>

  `put/3` passes an already-uniquified filename. Callers that need to
  address an existing blob should read `agents.avatar_storage_key` rather
  than recomputing it here — the `uuid` segment `put/3` mints is not
  reproducible by design.
  """
  @spec build_key(binary(), String.t()) :: String.t()
  def build_key(agent_id, filename) when is_binary(agent_id) and is_binary(filename) do
    Path.join([@namespace, agent_id, sanitize_filename(filename)])
  end

  @doc """
  Reads the content type back out of a storage key's extension.

  This is the inverse of the extension normalization `put/3` applies, and
  it is why that normalization exists: no column records an avatar's
  content type, so the serving controller recovers it from the key.

  Allowlist-gated on the way out as well as on the way in — a key written
  before this module existed, or hand-edited in the DB, must not be able to
  talk the controller into serving an arbitrary `Content-Type`. Anything
  unrecognized degrades to `application/octet-stream`, which the
  controller's `nosniff` header keeps inert.
  """
  @spec content_type_for_key(String.t()) :: String.t()
  def content_type_for_key(storage_key) when is_binary(storage_key) do
    inferred = MIME.from_path(storage_key)
    if inferred in @allowed_content_types, do: inferred, else: "application/octet-stream"
  end

  # Mirrors `AttachmentStorage.normalize_content_type/2`: iOS Safari and some
  # mobile browsers label photos "application/octet-stream" on upload, so a
  # missing or generic label falls back to the filename extension. Unlike
  # that function, an out-of-allowlist result is an ERROR rather than a
  # downgrade to octet-stream — a chat attachment may legitimately be an
  # arbitrary file, an avatar may not.
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

  # Uniquifies the blob and forces the extension to match the resolved
  # content type, so `content_type_for_key/1` can trust what it reads.
  defp stored_name(filename, content_type) do
    base =
      filename
      |> Path.basename()
      |> Path.rootname()
      |> sanitize_filename()

    "#{Ecto.UUID.generate()}-#{base}#{extension_for(content_type)}"
  end

  defp extension_for(content_type) do
    case MIME.extensions(content_type) do
      [ext | _] -> "." <> ext
      [] -> ""
    end
  end

  defp sanitize_filename(filename) do
    filename
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "avatar"
      sanitized -> sanitized
    end
  end

  # Dispatches through the chat-attachment adapter so dev/prod parity is
  # automatic. If avatars ever need their own adapter this becomes a
  # `:platform, :agent_avatar_storage_adapter` knob.
  defp adapter do
    Application.get_env(
      :platform,
      :attachment_storage_adapter,
      Platform.Chat.AttachmentStorage.Adapter.LocalDisk
    )
  end
end
