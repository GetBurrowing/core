defmodule PlatformWeb.ChatLive.LargeUploadHooks do
  @moduledoc """
  Lifecycle hook module for large-file uploads in `PlatformWeb.ChatLive`
  (task 01a120be stage 3, ADR 0035; mirrors `PlatformWeb.ChatLive.UploadHooks`).

  Files over the composer's inline cap (`ChatLive.max_upload_size/0`, 15 MB)
  never ride the LiveView websocket. The browser (`assets/js/hooks/large_upload.js`)
  stages them here, and on Send this module reserves each one through
  `Platform.Chat.reserve_space_upload/3` (which authorizes the writer and then
  calls `reserve_user_upload/2`, the same path the native share sheets use).
  The browser then PATCHes chunks straight to the presigned upload URL, and
  the server posts the message when the last chunk lands. Files at or
  under the inline cap keep the existing `allow_upload(:attachments)` path
  untouched.

  The limit and its label come from `Platform.Chat.UploadLimits` through the
  `:large_upload_limits` assign. The browser never holds the limit as a
  constant: the server decides whether a staged file is too large.

  The pending card is NOT server state. The browser holds the `File`, the
  offset and the status in a module-level registry and draws the card into
  the timeline itself (`LargeUploadTimeline`, a `phx-update="ignore"`
  container after `#message-list`), so the card survives a socket reconnect
  (a new LiveView process, with fresh assigns) and a hook remount alike. The
  `"large_upload:begin"` payload therefore carries everything the card and a
  re-reservation need: file name, type, space, participant and caption.

  Owns:

    * Assigns: `:large_upload_limits`, `:large_upload_staged` (files picked
      but not yet sent)
    * Events: `"large_upload_stage"`, `"large_upload_unstage"`,
      `"large_upload_start"`, `"large_upload_rereserve"` (the reservation
      expired while the browser still holds the File),
      `"large_upload_cancel"`, and a pass-through look at `"upload_send"` /
      `"upload_dialog_close"`.

  Attach it BEFORE `UploadHooks`: `UploadHooks` halts `"upload_dialog_close"`,
  and this module must see it to drop staged large files.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, push_event: 3, put_flash: 3]

  alias Platform.Chat
  alias Platform.Chat.Attachment
  alias Platform.Chat.AttachmentStorage
  alias Platform.Chat.UploadLimits
  alias Platform.Repo
  alias PlatformWeb.ChatLive.UploadHooks

  @doc "Attach large-upload handlers. Call from `ChatLive.mount/3`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:large_upload_limits, limits())
    |> assign(:large_upload_staged, [])
    |> attach_hook(:large_upload_events, :handle_event, &handle_event/3)
  end

  @doc "The server's limits, for the composer hint and the browser's routing."
  @spec limits() :: map()
  def limits do
    %{
      max_bytes: UploadLimits.max_bytes(),
      label: UploadLimits.label(),
      chunk_bytes: UploadLimits.chunk_bytes(),
      inline_max_bytes: PlatformWeb.ChatLive.max_upload_size()
    }
  end

  # ── Hook callbacks ────────────────────────────────────────────────────

  defp handle_event("large_upload_stage", %{"ref" => ref} = params, socket)
       when is_binary(ref) do
    size = to_int(params["size"])

    staged = %{
      ref: ref,
      name: to_string(params["name"] || "file"),
      size: size,
      type: to_string(params["type"] || ""),
      too_large?: size > socket.assigns.large_upload_limits.max_bytes
    }

    staged_list =
      Enum.reject(socket.assigns.large_upload_staged, &(&1.ref == ref)) ++ [staged]

    {:halt,
     socket
     |> assign(:large_upload_staged, staged_list)
     |> assign(:upload_dialog_open, true)}
  end

  defp handle_event("large_upload_unstage", %{"ref" => ref}, socket) do
    {:halt,
     socket
     |> assign(
       :large_upload_staged,
       Enum.reject(socket.assigns.large_upload_staged, &(&1.ref == ref))
     )
     |> push_event("large_upload:forget", %{ref: ref})}
  end

  defp handle_event("upload_dialog_close", _params, socket) do
    {:cont, clear_staged(socket)}
  end

  # Send: reserve every staged large file, hand the reservations to the
  # browser, and let the parent's `upload_send` post any inline files. When
  # nothing inline is staged, the caption rides the first large file's
  # message and the parent (which would flash "No files selected") is
  # skipped.
  defp handle_event("upload_send", _params, socket) do
    case Enum.reject(socket.assigns.large_upload_staged, & &1.too_large?) do
      [] ->
        {:cont, socket}

      sendable ->
        inline? = inline_entries?(socket)
        caption = if inline?, do: "", else: String.trim(socket.assigns[:upload_caption] || "")

        {socket, begun} =
          sendable
          |> Enum.with_index()
          |> Enum.reduce({socket, []}, fn {file, i}, {acc, begun} ->
            content = if i == 0, do: caption, else: ""

            case start(acc, file, content) do
              {:ok, acc, upload} -> {acc, [upload | begun]}
              {:error, acc} -> {acc, begun}
            end
          end)

        socket =
          socket
          |> push_event("large_upload:begin", %{uploads: Enum.reverse(begun)})
          |> clear_staged()

        if inline?, do: {:cont, socket}, else: {:halt, UploadHooks.reset(socket)}
    end
  end

  # Reserve one file directly (the browser path goes through "upload_send";
  # this is the per-file form of the same call).
  defp handle_event("large_upload_start", params, socket) do
    file = %{
      ref: to_string(params["ref"] || Ecto.UUID.generate()),
      name: to_string(params["filename"] || ""),
      size: to_int(params["byte_size"]),
      type: to_string(params["content_type"] || "")
    }

    case start(socket, file, String.trim(to_string(params["text"] || ""))) do
      {:ok, socket, upload} -> {:halt, Map.put(upload, :ok, true), socket}
      {:error, socket} -> {:halt, too_large_reply(socket, file), socket}
    end
  end

  # The reservation expired (or was reaped) while the browser was offline; it
  # still holds the File, so it asks for a new one through the same
  # `Chat.reserve_space_upload/3` path and starts again from 0. The space and
  # participant come from the browser (the user may have moved to another
  # space since), so the context authorizes this user as a writer there and
  # refuses a participant row of someone else, or of another space.
  defp handle_event("large_upload_rereserve", params, socket) do
    file = %{
      ref: to_string(params["ref"] || Ecto.UUID.generate()),
      name: to_string(params["filename"] || ""),
      size: to_int(params["byte_size"]),
      type: to_string(params["content_type"] || "")
    }

    attrs = %{
      space_id: to_string(params["space_id"] || ""),
      participant_id: to_string(params["participant_id"] || ""),
      content: to_string(params["content"] || "")
    }

    case reserve(socket.assigns[:user_id], attrs, file) do
      {:ok, r} ->
        {:halt, Map.put(upload_payload(file, r, attrs), :ok, true), socket}

      {:error, :too_large} ->
        {:halt, too_large_reply(socket, file), socket}

      {:error, reason} ->
        {:halt, %{ok: false, error: rereserve_error(reason)}, socket}
    end
  end

  # Cancel and Remove on the card. The browser has already stopped sending.
  defp handle_event("large_upload_cancel", %{"id" => id}, socket) do
    _ = delete_reservation(id, socket.assigns[:user_id])
    {:halt, %{ok: true}, socket}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # ── Internals ─────────────────────────────────────────────────────────

  defp start(socket, file, content) do
    with %{} = space <- socket.assigns[:active_space],
         %{} = participant <- socket.assigns[:current_participant] do
      attrs = %{space_id: space.id, participant_id: participant.id, content: content}

      case reserve(socket.assigns[:user_id], attrs, file) do
        {:ok, r} ->
          {:ok, socket, upload_payload(file, r, attrs)}

        {:error, :too_large} ->
          {:error,
           put_flash(
             socket,
             :error,
             "#{file.name} is #{UploadLimits.format_bytes(max(file.size, 0))}. " <>
               "This Burrow install accepts files up to #{UploadLimits.label()}."
           )}

        {:error, _reason} ->
          {:error, put_flash(socket, :error, "Could not start the upload of #{file.name}.")}
      end
    else
      _ -> {:error, socket}
    end
  end

  defp too_large_reply(socket, file) do
    limits = socket.assigns.large_upload_limits

    %{
      ok: false,
      error: if(file.size > limits.max_bytes, do: "file_too_large", else: "not_started"),
      max_upload_bytes: limits.max_bytes,
      max_upload_label: limits.label
    }
  end

  # Only the uploader's own still-pending reservation is deleted; a finished
  # row (the message already posted) is left alone.
  defp delete_reservation(id, user_id) do
    with true <- Platform.UUID.valid?(id),
         %Attachment{state: "pending", uploaded_by_user_id: ^user_id} = row <-
           Repo.get(Attachment, id) do
      AttachmentStorage.delete(row.storage_key)
      Repo.delete(row)
    end
  end

  defp inline_entries?(socket) do
    case socket.assigns[:uploads] do
      %{attachments: %{entries: [_ | _]}} -> true
      _ -> false
    end
  end

  defp clear_staged(socket) do
    Enum.reduce(socket.assigns.large_upload_staged, socket, fn s, acc ->
      push_event(acc, "large_upload:forget", %{ref: s.ref})
    end)
    |> assign(:large_upload_staged, [])
  end

  # One entry of the "large_upload:begin" payload (and the rereserve reply):
  # the reservation plus what the browser needs to draw the card and to
  # reserve again if this one expires.
  defp upload_payload(file, r, poster) do
    %{
      ref: file.ref,
      id: r.id,
      upload_url: r.upload_url,
      chunk_bytes: r.chunk_bytes,
      offset: r.offset,
      byte_size: file.size,
      expires_at: r.expires_at,
      filename: file.name,
      content_type: file.type,
      space_id: poster.space_id,
      participant_id: poster.participant_id,
      content: poster.content
    }
  end

  # Every reservation, the session's own space and a re-reservation for the
  # space the browser names alike, goes through `Chat.reserve_space_upload/3`,
  # which composes `SpaceAccess.authorize_writer/2` and refuses a participant
  # id that is not this user's row in that space.
  defp reserve(user_id, attrs, file) when is_binary(user_id) do
    Chat.reserve_space_upload({:user, user_id}, attrs, %{
      filename: file.name,
      content_type: file.type,
      byte_size: file.size
    })
  end

  defp reserve(_user_id, _attrs, _file), do: {:error, :forbidden}

  defp rereserve_error(:forbidden), do: "not_a_participant"
  defp rereserve_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp rereserve_error(_reason), do: "not_started"

  defp to_int(n) when is_integer(n), do: n

  defp to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> 0
    end
  end

  defp to_int(n) when is_float(n), do: trunc(n)
  defp to_int(_), do: 0
end
