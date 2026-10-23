defmodule PlatformWeb.ChatLive.AttachHooks do
  @moduledoc """
  Lifecycle hook module for the composer's staged tray in
  `PlatformWeb.ChatLive` (redesign rung 11, task 01a1557a-9de3).

  See ADR 0035. Pasted, picked and dropped files stage as thumbnails inside
  the composer (`PlatformWeb.ChatLive.Partials.Attach.staged_tray/1`) and
  post with the typed caption as ONE message through the existing
  `"send_message"` path (`MessagesHooks.post_message_with_upload/3`). There
  is no dialog and no tagging step: agents are tagged with @ in the caption.

  Owns:

    * Assigns: `:attach_menu_open` (the ＋ sheet on a phone and the popover
      on desktop, one assign for both) and `:attach_canvas_id` (the one
      canvas staged in the tray; `chat_messages.canvas_id` is one column, so
      picking a second replaces the first).
    * Events: `"attach_menu_open"`, `"attach_menu_close"`, `"attach_canvas"`
      (`id`), `"attach_canvas_remove"`, and `"attach_remove"` (`ref`) drops
      one staged entry. Retry is
      client-side (`assets/js/attach_stage.js` keeps the `File` for each
      entry ref, cancels the failed ref through `"attach_remove"` and
      stages the same file again).
    * Transport failures across a socket drop: `:attach_failed`, a list of
      `%{id, name, size, type}`. A dropped socket takes the LiveView process,
      and every upload entry with it, so an entry that was mid-upload cannot
      fail in LiveView's own state. The composer hook reports those files on
      reconnect (`"attach_transport_failed"`, `files`), they render as failed
      thumbnails with "Retry <name>", and `"attach_failed_remove"` (`id`)
      drops one: on retry (the client stages the same File again) or on ×.
    * A guard on `"send_message"`: while an entry is uploading or has
      failed, or a staged large file is over the install's limit, the send
      is refused here. Send is disabled in the same states
      (`send_state/1`); the guard covers Enter, which submits the form
      without consulting the button.

  ## allow_upload stays on parent

  `Phoenix.LiveView.allow_upload/3` binds uploads to the LiveView
  process. It stays configured in `ChatLive.mount/3`. Hooks receive the
  LV's own socket, so `Phoenix.LiveView.cancel_upload/3` works from
  hook callbacks.

  ## Usage

      # In ChatLive.mount/3, BEFORE MessagesHooks (the send guard must run
      # ahead of the send itself):
      socket = PlatformWeb.ChatLive.AttachHooks.attach(socket)
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, cancel_upload: 3, put_flash: 3]

  # LiveView validation errors: the file itself is refused, so retrying the
  # same file cannot succeed. Any other entry error is a transport failure.
  @validation_errors [:too_large, :too_many_files, :not_accepted]

  # A reconnecting client reports at most this many transport-failed files.
  @max_failed 20

  @doc "Attach the tray handlers. Call from `ChatLive.mount/3`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:attach_menu_open, false)
    |> assign(:attach_canvas_id, nil)
    |> assign(:attach_failed, [])
    |> attach_hook(:attach_events, :handle_event, &handle_event/3)
  end

  @doc """
  Cancel every staged upload entry for the named slot.

  Returns `{count, socket}` so the caller can decide whether to surface
  a flash message. Use when the parent scope (space, panel) goes away
  and staged entries should not carry over — per BACKLOG #10, staging
  an image in one space and navigating to another left the preview
  visible AND send-eligible in the new composer.

  Safe to call when no entries are staged — returns `{0, socket}`
  unchanged. For `:attachments` (the composer's tray) it also drops the
  staged canvas and closes the ＋ menu: both belong to the space being left.
  """
  @spec cancel_all(Phoenix.LiveView.Socket.t(), atom()) ::
          {non_neg_integer(), Phoenix.LiveView.Socket.t()}
  def cancel_all(socket, upload_name) when is_atom(upload_name) do
    socket =
      if upload_name == :attachments,
        do:
          socket
          |> assign(:attach_canvas_id, nil)
          |> assign(:attach_menu_open, false)
          |> assign(:attach_failed, []),
        else: socket

    case Map.get(socket.assigns[:uploads] || %{}, upload_name) do
      %{entries: entries} when is_list(entries) ->
        socket =
          Enum.reduce(entries, socket, fn entry, acc ->
            cancel_upload(acc, upload_name, entry.ref)
          end)

        {length(entries), socket}

      _ ->
        {0, socket}
    end
  end

  @doc """
  What Send can do right now, from the staged inline entries and large
  files: `:uploading` (an entry is below 100%), `:blocked` (an entry failed
  or a large file is over the limit), or `:ready`.
  """
  @spec send_state(map()) :: :uploading | :blocked | :ready
  def send_state(assigns) do
    {entries, upload} = entries(assigns)
    large = assigns[:large_upload_staged] || []

    cond do
      Enum.any?(entries, &failed?(upload, &1)) or upload_errors(upload) != [] or
        Enum.any?(large, & &1.too_large?) or (assigns[:attach_failed] || []) != [] ->
        :blocked

      Enum.any?(entries, &(&1.progress < 100)) ->
        :uploading

      true ->
        :ready
    end
  end

  @doc "True when anything is staged in the tray (files or a canvas)."
  @spec staged?(map()) :: boolean()
  def staged?(assigns) do
    {entries, _upload} = entries(assigns)

    entries != [] or (assigns[:large_upload_staged] || []) != [] or
      (assigns[:attach_failed] || []) != [] or not is_nil(assigns[:attach_canvas])
  end

  @doc """
  The canvas with this id if the sender may attach it to a message in the
  active space: it must be one of the active space's canvases as loaded for
  this viewer (`CanvasHooks.load_for_space/2`, access-scoped). A canvas of
  another space, or one the viewer cannot read, is `nil`.
  """
  @spec attachable_canvas(map(), term()) :: map() | nil
  def attachable_canvas(assigns, id) when is_binary(id) do
    with %{id: space_id} <- assigns[:active_space],
         %{space_id: ^space_id} = canvas <- Map.get(assigns[:canvases_by_id] || %{}, id) do
      canvas
    else
      _ -> nil
    end
  end

  def attachable_canvas(_assigns, _id), do: nil

  @doc "True when the entry failed and its error is not a validation refusal."
  @spec retryable?(map() | nil, map()) :: boolean()
  def retryable?(upload, entry) do
    errors = entry_errors(upload, entry)
    errors != [] and Enum.all?(errors, &(&1 not in @validation_errors))
  end

  @doc """
  True when the entry carries any LiveView upload error, or it is one of the
  entries past `max_entries` while the upload as a whole has
  `:too_many_files`. LiveView files that error on the CONFIG, not the entry,
  and never uploads the excess entry, so without this it sat on an upload
  ring forever.
  """
  @spec failed?(map() | nil, map()) :: boolean()
  def failed?(upload, entry), do: entry_errors(upload, entry) != [] or excess?(upload, entry)

  @doc "True when the entry is past `max_entries` and the upload has `:too_many_files`."
  @spec excess?(map() | nil, map()) :: boolean()
  def excess?(%{entries: entries, max_entries: max} = upload, entry) do
    :too_many_files in upload_errors(upload) and
      case Enum.find_index(entries, &(&1.ref == entry.ref)) do
        nil -> false
        index -> index >= max
      end
  end

  def excess?(_upload, _entry), do: false

  defp entries(assigns) do
    case assigns[:uploads] do
      %{attachments: %{entries: entries} = upload} -> {entries, upload}
      _ -> {[], nil}
    end
  end

  defp entry_errors(nil, _entry), do: []
  defp entry_errors(upload, entry), do: Phoenix.Component.upload_errors(upload, entry)

  defp upload_errors(nil), do: []
  defp upload_errors(upload), do: Phoenix.Component.upload_errors(upload)

  # ── Hook callbacks ────────────────────────────────────────────────────

  defp handle_event("attach_remove", %{"ref" => ref}, socket) do
    {:halt, cancel_upload(socket, :attachments, ref)}
  end

  defp handle_event("attach_transport_failed", %{"files" => files}, socket) when is_list(files) do
    failed =
      files
      |> Enum.flat_map(&failed_file/1)
      |> Enum.take(@max_failed)

    known = MapSet.new(socket.assigns.attach_failed, & &1.id)
    added = Enum.reject(failed, &MapSet.member?(known, &1.id))

    {:halt,
     assign(socket, :attach_failed, Enum.take(socket.assigns.attach_failed ++ added, @max_failed))}
  end

  defp handle_event("attach_failed_remove", %{"id" => id}, socket) do
    {:halt,
     assign(socket, :attach_failed, Enum.reject(socket.assigns.attach_failed, &(&1.id == id)))}
  end

  defp handle_event("attach_menu_open", _params, socket) do
    {:halt, assign(socket, :attach_menu_open, true)}
  end

  defp handle_event("attach_menu_close", _params, socket) do
    {:halt, assign(socket, :attach_menu_open, false)}
  end

  defp handle_event("attach_canvas", %{"id" => id}, socket) do
    case attachable_canvas(socket.assigns, id) do
      %{id: canvas_id} ->
        {:halt,
         socket
         |> assign(:attach_canvas_id, canvas_id)
         |> assign(:attach_menu_open, false)}

      nil ->
        {:halt,
         socket
         |> assign(:attach_menu_open, false)
         |> put_flash(:error, "That canvas can't be attached here.")}
    end
  end

  defp handle_event("attach_canvas_remove", _params, socket) do
    {:halt, assign(socket, :attach_canvas_id, nil)}
  end

  defp handle_event("send_message", _params, socket) do
    # Re-check the staged canvas at send time: it may have been deleted, or
    # the viewer moved, since it was picked. A canvas that no longer passes
    # is dropped, never posted.
    socket =
      case socket.assigns[:attach_canvas_id] do
        nil ->
          socket

        id ->
          if attachable_canvas(socket.assigns, id),
            do: socket,
            else: assign(socket, :attach_canvas_id, nil)
      end

    case send_state(socket.assigns) do
      :ready -> {:cont, socket}
      :uploading -> {:halt, put_flash(socket, :error, "Please wait for uploads to finish.")}
      :blocked -> {:halt, put_flash(socket, :error, "Remove the files that can't be sent first.")}
    end
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # One client-reported file, shape-checked: it is only ever rendered (a
  # name and size on a failed thumbnail), never trusted for anything else.
  defp failed_file(%{"id" => id, "name" => name} = file)
       when is_binary(id) and byte_size(id) in 1..64 and is_binary(name) do
    size = file["size"]
    type = file["type"]

    [
      %{
        id: id,
        name: String.slice(name, 0, 255),
        size: if(is_integer(size) and size >= 0, do: size, else: 0),
        type: if(is_binary(type), do: String.slice(type, 0, 255), else: "")
      }
    ]
  end

  defp failed_file(_file), do: []
end
