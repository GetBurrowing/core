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

  @namespace "agent-avatars"

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
  def delete(storage_key) when is_binary(storage_key), do: adapter().delete(storage_key)

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
