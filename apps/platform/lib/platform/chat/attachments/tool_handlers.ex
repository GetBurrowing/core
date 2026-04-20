defmodule Platform.Chat.Attachments.ToolHandlers do
  @moduledoc """
  MCP tool handlers for agent-uploaded attachments (ADR 0039 phase 4+5).

    * `upload_inline/2` — base64 body; capped at `:inline_upload_max_bytes`.
    * `upload_start/2` — reserves a pending row and returns a presigned URL
      the agent POSTs raw bytes to within `:pending_ttl_seconds`.

  Both paths dedup on `(space_id, content_hash)` at finalize and return a
  `/chat/attachments/<id>` URL the agent can reference as a canvas image
  `src` (phase 6) or hand back to a user.
  """

  require Logger

  alias Platform.Chat
  alias Platform.Chat.Attachment
  alias Platform.Chat.AttachmentPresigner
  alias Platform.Chat.AttachmentStorage
  alias Platform.Chat.AttachmentStorage.Adapter
  alias Platform.Repo

  import Ecto.Query, only: [from: 2]

  @storage_prefix "chat"

  @spec upload_inline(map(), map()) :: {:ok, map()} | {:error, map()}
  def upload_inline(args, context) do
    with {:ok, space_id} <- require_space_id(args, context),
         :ok <- require_member(space_id, context),
         {:ok, filename} <- require_string(args, "filename"),
         {:ok, content_type} <- require_string(args, "content_type"),
         {:ok, data_base64} <- require_string(args, "data_base64"),
         {:ok, bytes} <- decode_base64(data_base64),
         :ok <- check_inline_size(byte_size(bytes)) do
      canvas_id = Map.get(args, "canvas_id")
      storage_key = fresh_storage_key(filename)

      case adapter().persist(storage_key, {:binary, bytes}) do
        {:ok, %{byte_size: size, content_hash: hash}} ->
          finalize_or_dedup(
            space_id: space_id,
            content_hash: hash,
            content_type: content_type,
            filename: filename,
            byte_size: size,
            storage_key: storage_key,
            canvas_id: canvas_id,
            uploaded_by_agent_id: Map.get(context, :agent_id),
            state: "ready"
          )

        {:error, reason} ->
          {:error,
           %{
             error: "attachment.upload_inline: persist failed: #{inspect(reason)}",
             recoverable: true
           }}
      end
    end
  end

  @spec upload_start(map(), map()) :: {:ok, map()} | {:error, map()}
  def upload_start(args, context) do
    with {:ok, space_id} <- require_space_id(args, context),
         :ok <- require_member(space_id, context),
         {:ok, filename} <- require_string(args, "filename"),
         {:ok, content_type} <- require_string(args, "content_type"),
         {:ok, byte_size} <- require_positive_integer(args, "byte_size"),
         :ok <- check_upload_size(byte_size) do
      canvas_id = Map.get(args, "canvas_id")
      storage_key = fresh_storage_key(filename)
      ttl_s = pending_ttl_seconds()
      expires_at = DateTime.utc_now() |> DateTime.add(ttl_s, :second)

      case Chat.create_attachment(%{
             space_id: space_id,
             canvas_id: canvas_id,
             uploaded_by_agent_id: Map.get(context, :agent_id),
             filename: filename,
             content_type: content_type,
             byte_size: byte_size,
             storage_key: storage_key,
             state: "pending",
             upload_expires_at: expires_at
           }) do
        {:ok, attachment} ->
          case adapter().presign_upload(storage_key, upload_max_bytes(), ttl_s) do
            {:ok, %{url: url, expires_at: url_expires_at}} ->
              {:ok,
               %{
                 id: attachment.id,
                 upload_url: url,
                 expires_at: url_expires_at,
                 max_bytes: upload_max_bytes(),
                 url: "/chat/attachments/#{attachment.id}"
               }}

            {:error, reason} ->
              Repo.delete!(attachment)

              {:error,
               %{
                 error: "attachment.upload_start: presign failed: #{inspect(reason)}",
                 recoverable: true
               }}
          end

        {:error, %Ecto.Changeset{} = cs} ->
          {:error, %{error: "attachment.upload_start: #{inspect(cs.errors)}", recoverable: true}}
      end
    end
  end

  @doc """
  Finalize a pending attachment from the upload controller. Called after
  the bytes hit disk; performs the dedup check and either marks the row
  `:ready` or returns the canonical (duplicate) attachment id.
  """
  @spec finalize_pending(binary(), %{byte_size: non_neg_integer(), content_hash: String.t()}) ::
          {:ok, map()} | {:error, term()}
  def finalize_pending(attachment_id, %{byte_size: size, content_hash: hash}) do
    case Repo.get(Attachment, attachment_id) do
      nil ->
        {:error, :not_found}

      %Attachment{state: "pending"} = attachment ->
        finalize_or_dedup(
          space_id: attachment.space_id,
          content_hash: hash,
          content_type: attachment.content_type,
          filename: attachment.filename,
          byte_size: size,
          storage_key: attachment.storage_key,
          canvas_id: attachment.canvas_id,
          uploaded_by_agent_id: attachment.uploaded_by_agent_id,
          existing_id: attachment.id,
          state: "ready"
        )

      %Attachment{} ->
        {:error, :already_finalized}
    end
  end

  # ── Internals ─────────────────────────────────────────────────────────

  # Takes write-side attrs, checks for a ready twin with the same
  # (space_id, content_hash). Returns the canonical result either way.
  defp finalize_or_dedup(opts) do
    space_id = Keyword.fetch!(opts, :space_id)
    hash = Keyword.fetch!(opts, :content_hash)
    new_key = Keyword.fetch!(opts, :storage_key)
    existing_id = Keyword.get(opts, :existing_id)

    case Repo.one(
           from(a in Attachment,
             where:
               a.space_id == ^space_id and
                 a.content_hash == ^hash and
                 a.state == "ready" and
                 a.id != ^(existing_id || Ecto.UUID.generate()),
             limit: 1,
             select: %{id: a.id, storage_key: a.storage_key}
           )
         ) do
      %{id: canonical_id, storage_key: canonical_key} ->
        adapter().delete(new_key)

        if existing_id, do: Repo.delete(Repo.get(Attachment, existing_id))

        {:ok,
         %{
           id: canonical_id,
           url: "/chat/attachments/#{canonical_id}",
           byte_size: Keyword.fetch!(opts, :byte_size),
           content_hash: hash,
           content_type: Keyword.fetch!(opts, :content_type),
           deduplicated: true,
           canonical_storage_key: canonical_key
         }}

      nil ->
        case ensure_row(opts) do
          {:ok, attachment} ->
            {:ok,
             %{
               id: attachment.id,
               url: "/chat/attachments/#{attachment.id}",
               byte_size: attachment.byte_size,
               content_hash: attachment.content_hash,
               content_type: attachment.content_type,
               deduplicated: false
             }}

          {:error, reason} ->
            {:error,
             %{error: "attachment: finalize failed: #{inspect(reason)}", recoverable: true}}
        end
    end
  end

  defp ensure_row(opts) do
    case Keyword.get(opts, :existing_id) do
      nil ->
        Chat.create_attachment(%{
          space_id: Keyword.fetch!(opts, :space_id),
          canvas_id: Keyword.get(opts, :canvas_id),
          uploaded_by_agent_id: Keyword.get(opts, :uploaded_by_agent_id),
          filename: Keyword.fetch!(opts, :filename),
          content_type: Keyword.fetch!(opts, :content_type),
          byte_size: Keyword.fetch!(opts, :byte_size),
          storage_key: Keyword.fetch!(opts, :storage_key),
          content_hash: Keyword.fetch!(opts, :content_hash),
          state: Keyword.fetch!(opts, :state)
        })

      id ->
        Repo.get(Attachment, id)
        |> Attachment.changeset(%{
          byte_size: Keyword.fetch!(opts, :byte_size),
          content_hash: Keyword.fetch!(opts, :content_hash),
          state: Keyword.fetch!(opts, :state),
          upload_expires_at: nil
        })
        |> Repo.update()
    end
  end

  defp require_space_id(args, context) do
    case Map.get(args, "space_id") || Map.get(context, :space_id) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, %{error: "attachment: space_id required", recoverable: true}}
    end
  end

  defp require_member(space_id, context) do
    participant_id =
      Map.get(context, :agent_participant_id) || Map.get(context, :participant_id)

    if is_binary(participant_id) do
      :ok
    else
      {:error,
       %{
         error:
           "attachment: agent #{inspect(Map.get(context, :agent_id))} is not a participant in space #{inspect(space_id)} — join the space first.",
         recoverable: false
       }}
    end
  end

  defp require_string(args, key) do
    case Map.get(args, key) do
      v when is_binary(v) and v != "" ->
        {:ok, v}

      _ ->
        {:error,
         %{error: "attachment: missing or invalid \"#{key}\" (string)", recoverable: true}}
    end
  end

  defp require_positive_integer(args, key) do
    case Map.get(args, key) do
      v when is_integer(v) and v > 0 ->
        {:ok, v}

      _ ->
        {:error,
         %{
           error: "attachment: missing or invalid \"#{key}\" (positive integer)",
           recoverable: true
         }}
    end
  end

  defp decode_base64(s) do
    case Base.decode64(s, padding: false) do
      {:ok, bytes} ->
        {:ok, bytes}

      :error ->
        case Base.decode64(s) do
          {:ok, bytes} ->
            {:ok, bytes}

          :error ->
            {:error, %{error: "attachment: data_base64 is not valid base64", recoverable: true}}
        end
    end
  end

  defp check_inline_size(size) do
    limit = inline_upload_max_bytes()

    if size <= limit do
      :ok
    else
      {:error,
       %{
         error: "attachment: inline payload exceeds limit (#{size} > #{limit} bytes)",
         recoverable: true,
         limit: limit,
         use: "attachment.upload_start"
       }}
    end
  end

  defp check_upload_size(size) do
    limit = upload_max_bytes()

    if size <= limit do
      :ok
    else
      {:error,
       %{
         error: "attachment: byte_size exceeds max (#{size} > #{limit} bytes)",
         recoverable: true,
         limit: limit
       }}
    end
  end

  defp fresh_storage_key(client_name) do
    filename = sanitize_filename(client_name)
    bucket = Date.utc_today() |> Date.to_iso8601() |> String.replace("-", "/")
    stored_name = "#{Ecto.UUID.generate()}-#{filename}"
    Path.join([@storage_prefix, bucket, stored_name])
  end

  defp sanitize_filename(filename) do
    filename
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "attachment"
      sanitized -> sanitized
    end
  end

  defp adapter,
    do:
      Application.get_env(
        :platform,
        :attachment_storage_adapter,
        AttachmentStorage.Adapter.LocalDisk
      )

  defp inline_upload_max_bytes,
    do: Application.get_env(:platform, :inline_upload_max_bytes, 25 * 1024 * 1024)

  defp upload_max_bytes,
    do: Application.get_env(:platform, :upload_max_bytes, 500 * 1024 * 1024)

  defp pending_ttl_seconds,
    do: Application.get_env(:platform, :pending_ttl_seconds, 15 * 60)

  # Suppress unused-alias / -import warnings — Presigner is referenced from
  # the controller, not here; AttachmentStorage is referenced via adapter().
  _ = AttachmentPresigner
  _ = AttachmentStorage
  _ = Adapter
end
