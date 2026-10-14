defmodule PlatformWeb.ChatAttachmentUploadController do
  @moduledoc """
  Accepts raw bytes for a presigned upload (ADR 0039 phase 4+5).

  The HMAC-signed `<token>` in the URL is the only auth — the agent's
  bearer does not need to ride this request. The token carries
  `{key, max_bytes, expires_at}`; we verify signature + expiry, enforce
  size, stream bytes to the storage adapter, and then finalize the
  reservation that owns `key`.

  ## Two reservation tables

  A key is reserved in one of two places (task 01a091b7):

    * `chat_attachments` — `attachment.upload_start`; finalized through
      `Platform.Chat.Attachments.ToolHandlers.finalize_pending/2` (dedup
      included), response `%{id, url, byte_size, content_hash, deduplicated}`.
    * `platform_files` — `file_add`'s presigned branch; finalized through
      `Platform.Files.finalize_presigned_upload/2` (async ingest — the
      response goes out before extraction, matching the inline branch's
      `state: "ready"` contract), response `%{id, project_id, state,
      deduplicated, byte_size, content_hash, content_type}`.

  Lookup order: the chat row wins whenever one exists for the key, in
  ANY state — Stage 6 backfill (`Files.Storage.passthrough_key/1`) can
  alias a chat key onto a platform_files row, and a `ready` chat row must
  keep its 409. Only a `nil` chat lookup falls through to `platform_files`
  (live rows only; soft-deleted reservations read as absent -> 404). A
  platform_files row that already carries a content_hash (finalized,
  ingested or not — ingest is async, so `ingest_status` alone cannot
  tell), or a finalize race between two POSTs on one token, is 409 `attachment already finalized` — the message is shared
  with the chat branch on purpose so clients need one 409 handler.

  ## Resumable chunked uploads (task 01a120be)

  Large files (up to `Platform.Chat.UploadLimits.max_bytes/0`, 1 GB by
  default) ride the SAME token URL with two tus-style verbs instead of one
  big POST:

    * `HEAD` (routed as GET because `Plug.Head` rewrites HEAD) answers 200
      with `Upload-Offset` (the CONTIGUOUS prefix from 0 received so far) and
      `Upload-Length` (the reserved `byte_size`). A client resumes from
      `Upload-Offset` after a drop, never from zero.
    * `PATCH` with an `Upload-Offset` request header stores its body at that
      offset. It is accepted when either:
        * the offset IS the contiguous offset (sequential): any body up to
          `UploadLimits.chunk_bytes/0` that stays within the reserved length,
          else 413; or
        * the offset is a multiple of `chunk_bytes` and the request declares
          `Content-Length` of exactly `min(chunk_bytes, total - offset)`
          (an aligned chunk, possibly out of order, ahead of a gap).
      Bytes are written at their offset; an aligned chunk already received
      is 204 without being rewritten. Any other offset is 409 carrying the
      contiguous `Upload-Offset`.
    * Every 204 carries `Upload-Offset` (contiguous) and `Upload-Length`.
      Exactly ONE PATCH, the one whose bookkeeping completes coverage of
      `[0, total)`, finalizes: it completes the upload (stream-hash then
      rename, see `LocalDisk.complete_upload/1`), finalizes the row exactly as
      `create/2` does (posting the reserved message once, for an app/browser
      reservation), and answers 200 with the same JSON plus
      `Upload-Offset: total`. Every other PATCH, concurrent ones included,
      answers 204.

  Concurrency: request bodies stream to disk with no lock held. The
  bookkeeping that follows (record the received range, slide the expiry,
  claim the finalize) runs in one transaction holding `SELECT ... FOR
  UPDATE` on the `chat_attachments` row (`settle_chunk/3`); the received
  ranges live in a sidecar beside the `.part`, so they survive a restart.

  Chunked uploads exist for `chat_attachments` rows only; a `platform_files`
  key is 404 on these verbs. Liveness is the row's `upload_expires_at`, not
  the token's minted expiry: each accepted chunk slides it forward by
  `:pending_ttl_seconds`, and an expired row is 410. `create/2` is unchanged.

  ## Adapter scope

  Only `LocalDisk` exists on main
  (`apps/platform/lib/platform/chat/attachment_storage/adapter/`); the
  token format is adapter-owned. A future S3/R2 adapter with a native
  presigned POST would bypass this controller entirely and needs its own
  finalize hook for both tables.
  """

  use PlatformWeb, :controller

  require Logger

  alias Platform.Chat.Attachment
  alias Platform.Chat.AttachmentPresigner
  alias Platform.Chat.AttachmentStorage
  alias Platform.Chat.Attachments.ToolHandlers
  alias Platform.Chat.UploadLimits
  alias Platform.Files
  alias Platform.Files.File, as: PFile
  alias Platform.Repo

  import Ecto.Query, only: [from: 2]

  @read_chunk_bytes 64 * 1024

  # Which conn a response goes out on (task 01a0fdf9).
  #
  # Every response sent AFTER the first `read_body` goes out on the conn
  # RETURNED by the latest read, never on the conn `create/2` was called
  # with. Bandit drains any unread request body from the adapter state of
  # the conn the plug returns (`Bandit.Pipeline` -> `ensure_completed`). A
  # pre-read conn still reports the whole Content-Length as unread, so
  # Bandit would read that many more bytes off the wire, and on a keep-alive
  # connection those bytes are the NEXT request. Same rule as
  # `PlatformWeb.Plugs.VerifyPeerEnvelope.verify/1`.
  #
  # Refusals made before anything is read (token, reservation, content-type)
  # correctly use the input conn: nothing was consumed, and Bandit drains
  # the full Content-Length itself.
  def create(conn, %{"token" => token}) do
    with {:ok, %{key: key, max_bytes: max_bytes}} <- AttachmentPresigner.verify(token),
         {:ok, %{storage_key: ^key} = reservation} <- pending_reservation(key),
         :ok <- validate_content_type(conn, reservation) do
      receive_upload(conn, reservation, max_bytes)
    else
      {:error, reason} -> send_refusal(conn, reason)
    end
  end

  # Post-read half: `conn` is rebound from the stream result, so every
  # response below goes out on the conn the last `read_body` returned.
  defp receive_upload(conn, reservation, max_bytes) do
    case stream_body_to_tmp(conn, max_bytes) do
      {:ok, conn, tmp_path, byte_size} ->
        store_and_finalize(conn, reservation, tmp_path, byte_size)

      {:error, reason, conn} ->
        send_refusal(conn, reason)
    end
  end

  defp store_and_finalize(conn, reservation, tmp_path, byte_size) do
    with {:ok, %{byte_size: ^byte_size, content_hash: _} = stat} <-
           persist_bytes(reservation, tmp_path) do
      File.rm(tmp_path)

      case finalize(reservation, stat) do
        {:ok, payload} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(payload))

        {:error, :not_pending} ->
          send_error(conn, 409, "attachment already finalized")

        {:error, reason} ->
          send_error(conn, 500, "finalize failed: #{inspect(reason)}")
      end
    else
      {:error, reason} -> send_refusal(conn, reason)
    end
  end

  # ── Resumable chunked verbs (task 01a120be; see moduledoc) ─────────────

  @doc "HEAD (arrives as GET via `Plug.Head`): report the contiguous received offset."
  def head(conn, %{"token" => token}) do
    with {:ok, reservation} <- chunked_reservation(token),
         {:ok, offset} <- adapter().upload_offset(reservation.storage_key) do
      conn
      |> put_upload_headers(offset, reservation.byte_size)
      |> send_resp(200, "")
    else
      {:error, reason} -> send_refusal(conn, reason)
    end
  end

  @doc "PATCH: store one chunk at `Upload-Offset` (sequential or aligned; see moduledoc)."
  def append(conn, %{"token" => token}) do
    with {:ok, reservation} <- chunked_reservation(token),
         {:ok, client_offset} <- request_offset(conn),
         {:ok, contiguous} <- adapter().upload_offset(reservation.storage_key),
         {:ok, plan} <- plan_chunk(conn, reservation, client_offset, contiguous) do
      case plan do
        :duplicate ->
          # Already received: nothing to read or write. Bandit drains the
          # unread body from this (pre-read) conn.
          slide_expiry(reservation)

          conn
          |> put_upload_headers(contiguous, reservation.byte_size)
          |> send_resp(204, "")

        {kind, limit} ->
          receive_chunk(conn, reservation, kind, client_offset, limit)
      end
    else
      {:error, {:offset_mismatch, actual}} -> send_offset_mismatch(conn, actual)
      {:error, reason} -> send_refusal(conn, reason)
    end
  end

  # What one PATCH may do, decided before any byte is read:
  #
  #   * `{:sequential, limit}` — `Upload-Offset` is the contiguous offset
  #     (the pre-out-of-order protocol, unchanged): up to `limit` bytes, and
  #     whatever reaches disk is recorded even if the body is cut off.
  #   * `{:aligned, len}` — ahead of the contiguous offset, on a
  #     `chunk_bytes` boundary, declaring exactly `len` =
  #     `min(chunk_bytes, total - offset)` bytes; recorded only when all
  #     `len` arrive.
  #   * `:duplicate` — an aligned, exact-length chunk whose range is already
  #     received (behind the contiguous offset or a recorded ahead chunk).
  #
  # Anything else is `{:offset_mismatch, contiguous}` (409).
  defp plan_chunk(conn, reservation, offset, contiguous) do
    total = reservation.byte_size

    if offset == contiguous do
      with :ok <- declared_length_fits(conn, offset, total),
           do: {:ok, {:sequential, min(UploadLimits.chunk_bytes(), total - offset)}}
    else
      plan_aligned(conn, reservation, offset, contiguous)
    end
  end

  defp plan_aligned(conn, reservation, offset, contiguous) do
    total = reservation.byte_size
    chunk = UploadLimits.chunk_bytes()
    len = min(chunk, total - offset)

    with true <- offset < total and rem(offset, chunk) == 0,
         {:ok, ^len} <- declared_length(conn),
         {:ok, ranges} <- adapter().upload_ranges(reservation.storage_key) do
      cond do
        received?([{0, contiguous} | ranges], offset, offset + len) -> {:ok, :duplicate}
        offset > contiguous -> {:ok, {:aligned, len}}
        # Behind the contiguous offset but only partly received (a cut-off
        # sequential chunk): resume from the contiguous offset instead.
        true -> {:error, {:offset_mismatch, contiguous}}
      end
    else
      {:error, reason} when reason != :no_length -> {:error, reason}
      _ -> {:error, {:offset_mismatch, contiguous}}
    end
  end

  defp received?(ranges, from, to), do: Enum.any?(ranges, fn {s, e} -> s <= from and to <= e end)

  defp declared_length(conn) do
    with [raw | _] <- get_req_header(conn, "content-length"),
         {len, ""} <- Integer.parse(String.trim(raw)) do
      {:ok, len}
    else
      _ -> {:error, :no_length}
    end
  end

  defp send_offset_mismatch(conn, actual) do
    conn
    |> put_resp_header("upload-offset", Integer.to_string(actual))
    |> send_error(409, "upload-offset mismatch")
  end

  # Token signature (not its minted expiry), a pending chat row, a live
  # sliding expiry, and a reserved size within the per-install limit, all
  # checked before any byte is read.
  defp chunked_reservation(token) do
    with {:ok, %{key: key, max_bytes: max_bytes}} <-
           AttachmentPresigner.verify(token, check_expires_at: false),
         {:ok, %Attachment{storage_key: ^key} = attachment} <- pending_reservation(key),
         :ok <- unexpired(attachment),
         :ok <- reserved_size_allowed(attachment, max_bytes) do
      {:ok, attachment}
    else
      {:ok, %PFile{}} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp unexpired(%Attachment{upload_expires_at: nil}), do: :ok

  defp unexpired(%Attachment{upload_expires_at: at}) do
    if DateTime.compare(at, DateTime.utc_now()) == :gt, do: :ok, else: {:error, :expired}
  end

  defp reserved_size_allowed(%Attachment{byte_size: size}, max_bytes)
       when is_integer(size) and size >= 0 and size <= max_bytes do
    UploadLimits.check_size(size)
  end

  defp reserved_size_allowed(_attachment, _max_bytes), do: {:error, :too_large}

  defp request_offset(conn) do
    with [raw | _] <- get_req_header(conn, "upload-offset"),
         {offset, ""} when offset >= 0 <- Integer.parse(String.trim(raw)) do
      {:ok, offset}
    else
      _ -> {:error, :bad_offset}
    end
  end

  # A declared Content-Length is refused up front; a body without one is
  # bounded while streaming (`stream_chunk/5`).
  defp declared_length_fits(conn, offset, total) do
    case get_req_header(conn, "content-length") do
      [raw | _] ->
        case Integer.parse(raw) do
          {len, ""} -> chunk_fits(len, offset, total)
          _ -> :ok
        end

      [] ->
        :ok
    end
  end

  defp chunk_fits(len, offset, total) do
    if len > UploadLimits.chunk_bytes() or offset + len > total,
      do: {:error, :chunk_too_large},
      else: :ok
  end

  # Post-read half (same rule as `receive_upload/3`): every response below
  # goes out on the conn the last `read_body` returned.
  #
  # Streaming happens OUTSIDE any lock; only the bookkeeping that follows is
  # serialized (`settle_chunk/3`).
  defp receive_chunk(conn, reservation, kind, start, limit) do
    key = reservation.storage_key
    {result, conn, written_to} = stream_chunk(conn, key, start, start, limit)

    range =
      case {kind, result} do
        # A cut-off sequential chunk keeps what reached disk (resume).
        {:sequential, _} -> {start, written_to}
        # An aligned chunk counts only whole.
        {:aligned, :ok} when written_to - start == limit -> {start, written_to}
        {:aligned, _} -> nil
      end

    case {result, range} do
      {:ok, nil} ->
        # Short aligned body: nothing counted.
        case adapter().upload_offset(key) do
          {:ok, contiguous} -> send_offset_mismatch(conn, contiguous)
          {:error, reason} -> send_refusal(conn, reason)
        end

      {:ok, range} ->
        reply_settled(conn, reservation, settle_chunk(reservation, range, true))

      {{:error, reason}, range} ->
        if range, do: settle_chunk(reservation, range, false)
        send_refusal(conn, reason)
    end
  end

  # Returns `{:ok | {:error, reason}, conn, written_to}`.
  defp stream_chunk(conn, key, start, offset, limit) do
    case Plug.Conn.read_body(conn, length: @read_chunk_bytes, read_length: @read_chunk_bytes) do
      {status, chunk, conn} when status in [:ok, :more] ->
        if offset + byte_size(chunk) - start > limit do
          {{:error, :chunk_too_large}, conn, offset}
        else
          case adapter().write_at(key, offset, {:binary, chunk}) do
            :ok when status == :ok -> {:ok, conn, offset + byte_size(chunk)}
            :ok -> stream_chunk(conn, key, start, offset + byte_size(chunk), limit)
            {:error, reason} -> {{:error, reason}, conn, offset}
          end
        end

      {:error, reason} ->
        {{:error, {:read_body_failed, reason}}, conn, offset}
    end
  end

  # ── Serialized bookkeeping and the once-only finalize ──────────────────
  #
  # One transaction holding `SELECT ... FOR UPDATE` on the reservation row:
  # record the range, slide the expiry, and, when the contiguous offset
  # reaches the reserved length, CLAIM the finalize by stamping
  # `metadata[@finalize_claim]`. Exactly one PATCH sees "complete, pending,
  # unclaimed"; it finalizes after the commit (so the message is broadcast
  # after its row is visible), and every other PATCH answers 204. A claim
  # older than @finalize_claim_stale_s (a finalizer that crashed) can be
  # re-taken, so a client's zero-length final PATCH recovers it.
  @finalize_claim "chunked_finalize_claimed_at"
  @finalize_claim_stale_s 300

  defp settle_chunk(%Attachment{id: id} = reservation, {lo, hi}, finalize?) do
    key = reservation.storage_key

    Repo.transaction(fn ->
      row = Repo.one(from(a in Attachment, where: a.id == ^id, lock: "FOR UPDATE"))

      cond do
        is_nil(row) ->
          {:error, :not_found}

        row.state != "pending" ->
          :finalized

        true ->
          with {:ok, contiguous} <- record(key, lo, hi) do
            claim? = finalize? and contiguous == row.byte_size and claimable?(row)
            touch_row(row, claim?)

            cond do
              claim? -> {:finalize, row}
              contiguous == row.byte_size -> :claimed
              true -> {:progress, contiguous}
            end
          end
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp record(key, lo, lo), do: adapter().upload_offset(key)
  defp record(key, lo, hi), do: adapter().record_range(key, lo, hi)

  defp claimable?(%Attachment{metadata: metadata}) do
    with %{@finalize_claim => at} <- metadata || %{},
         {:ok, at, _} <- DateTime.from_iso8601(at) do
      DateTime.diff(DateTime.utc_now(), at, :second) > @finalize_claim_stale_s
    else
      _ -> true
    end
  end

  # Sliding expiry: each accepted chunk keeps the reservation alive for
  # another `:pending_ttl_seconds`, so the reaper never sweeps a slow upload
  # that is still moving.
  defp touch_row(row, claim?) do
    metadata =
      if claim?,
        do:
          Map.put(row.metadata || %{}, @finalize_claim, DateTime.to_iso8601(DateTime.utc_now())),
        else: row.metadata

    row
    |> Ecto.Changeset.change(upload_expires_at: next_expiry(), metadata: metadata)
    |> Repo.update!()
  end

  defp release_claim(%Attachment{id: id}) do
    Repo.transaction(fn ->
      case Repo.one(from(a in Attachment, where: a.id == ^id, lock: "FOR UPDATE")) do
        %Attachment{state: "pending"} = row ->
          row
          |> Ecto.Changeset.change(metadata: Map.delete(row.metadata || %{}, @finalize_claim))
          |> Repo.update!()

        _ ->
          :ok
      end
    end)
  end

  defp reply_settled(conn, reservation, settled) do
    total = reservation.byte_size

    case settled do
      {:progress, contiguous} ->
        conn
        |> put_upload_headers(contiguous, total)
        |> send_resp(204, "")

      # Complete, and another PATCH holds (or already ran) the finalize.
      outcome when outcome in [:claimed, :finalized] ->
        # A late duplicate write can recreate a .part after the rename.
        if outcome == :finalized, do: adapter().discard_part(reservation.storage_key)

        conn
        |> put_upload_headers(total, total)
        |> send_resp(204, "")

      {:finalize, row} ->
        finalize_chunked(conn, row)

      {:error, reason} ->
        send_refusal(conn, reason)
    end
  end

  defp finalize_chunked(conn, %Attachment{byte_size: total, storage_key: key} = row) do
    with {:ok, %{byte_size: ^total} = stat} <- adapter().complete_upload(key),
         {:ok, payload} <- finalize(row, stat) do
      adapter().discard_part(key)

      conn
      |> put_upload_headers(total, total)
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(payload))
    else
      failure ->
        release_claim(row)

        case failure do
          {:ok, %{byte_size: _}} -> send_error(conn, 500, "stored size differs from reservation")
          # A chat row finalizes through ToolHandlers, whose "already done"
          # is :already_finalized (the :not_pending refusal is the lookup's).
          {:error, :already_finalized} -> send_error(conn, 409, "attachment already finalized")
          {:error, reason} -> send_error(conn, 500, "finalize failed: #{inspect(reason)}")
        end
    end
  end

  # For a chunk that wrote nothing (a duplicate): slide the expiry of a
  # still-pending row without taking the lock.
  defp slide_expiry(%Attachment{id: id}) do
    Repo.update_all(from(a in Attachment, where: a.id == ^id and a.state == "pending"),
      set: [upload_expires_at: next_expiry()]
    )
  end

  defp next_expiry do
    ttl = Application.get_env(:platform, :pending_ttl_seconds, 15 * 60)
    DateTime.utc_now() |> DateTime.add(ttl, :second)
  end

  defp put_upload_headers(conn, offset, total) do
    conn
    |> put_resp_header("upload-offset", Integer.to_string(offset))
    |> put_resp_header("upload-length", Integer.to_string(total))
    |> put_resp_header("cache-control", "no-store")
  end

  defp send_refusal(conn, reason) do
    case reason do
      :invalid ->
        send_error(conn, 401, "invalid upload token")

      :expired ->
        send_error(conn, 410, "upload token expired")

      :too_large ->
        send_error(conn, 413, "body exceeds max_bytes")

      :content_type_mismatch ->
        send_error(conn, 400, "content-type does not match reserved row")

      :not_found ->
        send_error(conn, 404, "no pending reservation for key")

      :not_pending ->
        send_error(conn, 409, "attachment already finalized")

      :bad_offset ->
        send_error(conn, 400, "missing or invalid Upload-Offset header")

      :chunk_too_large ->
        send_error(conn, 413, "chunk exceeds chunk_bytes or the reserved length")

      reason ->
        send_error(conn, 500, "upload failed: #{inspect(reason)}")
    end
  end

  # The chat row is authoritative for its key in every state; only a nil
  # chat lookup consults platform_files (see moduledoc, "Two reservation
  # tables").
  defp lookup_pending(key) do
    case Repo.get_by(Attachment, storage_key: key) do
      nil -> Files.get_by_storage_key(key)
      attachment -> attachment
    end
  end

  defp pending_reservation(key) do
    case lookup_pending(key) do
      nil -> {:error, :not_found}
      %Attachment{state: "pending"} = attachment -> {:ok, attachment}
      %Attachment{} -> {:error, :not_pending}
      # `ingest_status: "pending"` alone is NOT "awaiting bytes": ingest
      # is async, so a just-finalized row is still "pending" until the
      # Ingester runs. The reservation marker is a nil content_hash.
      %PFile{ingest_status: "pending", content_hash: nil} = file -> {:ok, file}
      %PFile{} -> {:error, :not_pending}
    end
  end

  defp finalize(%Attachment{id: id}, stat), do: ToolHandlers.finalize_pending(id, stat)

  defp finalize(%PFile{} = file, stat) do
    with {:ok, %{file: done, deduplicated: dedup?}} <- Files.finalize_presigned_upload(file, stat) do
      # Same shape as `file_add_result_ready/2` in Platform.Federation.ToolSurface.
      {:ok,
       %{
         id: done.id,
         project_id: done.project_id,
         state: "ready",
         deduplicated: dedup?,
         byte_size: done.byte_size,
         content_hash: done.content_hash,
         content_type: done.content_type
       }}
    end
  end

  defp validate_content_type(conn, %{content_type: declared}) do
    case get_req_header(conn, "content-type") do
      [] ->
        :ok

      [^declared | _] ->
        :ok

      [sent | _] ->
        if strip_params(sent) == strip_params(declared) do
          :ok
        else
          {:error, :content_type_mismatch}
        end
    end
  end

  defp strip_params(ct) when is_binary(ct) do
    ct |> String.split(";", parts: 2) |> List.first() |> String.trim() |> String.downcase()
  end

  defp stream_body_to_tmp(conn, max_bytes) do
    tmp_path =
      Path.join(
        System.tmp_dir!(),
        "att-upload-#{System.unique_integer([:positive])}-#{Ecto.UUID.generate()}"
      )

    case File.open(tmp_path, [:write, :binary, :raw]) do
      {:ok, io} ->
        try do
          do_stream(conn, io, max_bytes, 0, tmp_path)
        after
          File.close(io)
        end

      # Nothing has been read yet, so the input conn is the current one.
      {:error, reason} ->
        {:error, {:open_failed, reason}, conn}
    end
  end

  # Returns `{:ok, conn, tmp_path, size}` or `{:error, reason, conn}`, where
  # `conn` is always the latest one a `read_body` returned (see the comment
  # above `create/2`).
  defp do_stream(conn, io, max_bytes, acc, tmp_path) do
    case Plug.Conn.read_body(conn, length: @read_chunk_bytes, read_length: @read_chunk_bytes) do
      {:ok, chunk, conn} ->
        new_size = acc + byte_size(chunk)

        if new_size > max_bytes do
          File.rm(tmp_path)
          {:error, :too_large, conn}
        else
          :ok = IO.binwrite(io, chunk)
          {:ok, conn, tmp_path, new_size}
        end

      {:more, chunk, conn} ->
        new_size = acc + byte_size(chunk)

        if new_size > max_bytes do
          File.rm(tmp_path)
          {:error, :too_large, conn}
        else
          :ok = IO.binwrite(io, chunk)
          do_stream(conn, io, max_bytes, new_size, tmp_path)
        end

      # Plug's `{:error, reason}` carries no conn; the one passed into this
      # failing read is the latest the controller holds.
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, {:read_body_failed, reason}, conn}
    end
  end

  defp persist_bytes(%{storage_key: key}, tmp_path) do
    adapter().persist(key, {:path, tmp_path})
  end

  defp send_error(conn, status, message) do
    body = Jason.encode!(%{error: message})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  defp adapter,
    do:
      Application.get_env(
        :platform,
        :attachment_storage_adapter,
        AttachmentStorage.Adapter.LocalDisk
      )
end
