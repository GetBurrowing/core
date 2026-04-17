defmodule PlatformWeb.ChatLive.UploadHooks do
  @moduledoc """
  Lifecycle hook module for the Uploads feature in `PlatformWeb.ChatLive`.

  See ADR 0035. Uploads has distributed UI (inline paperclip button in
  the compose form + the dialog modal) so it lives as a LifecycleHook.
  Owns:

    * Assigns: `:upload_dialog_open`, `:upload_caption`,
      `:upload_tagged_agents`
    * Events:  `"upload_dialog_open"`, `"upload_dialog_close"`,
      `"upload_caption_change"`, `"upload_entry_cancel"`,
      `"upload_toggle_agent"`

  ## Cross-feature note (upload_send)

  `upload_send` creates a message with attachments — that crosses into
  the MessageList feature (stream_insert, attachments_map). It stays on
  the parent LiveView as a coordinator event until MessageList extracts,
  mirroring the `search_open_result` pattern. `UploadHooks.reset/1` is
  the public helper the parent calls after a successful send.

  ## allow_upload stays on parent

  `Phoenix.LiveView.allow_upload/3` binds uploads to the LiveView
  process. It stays configured in `ChatLive.mount/3`. Hooks receive the
  LV's own socket, so `Phoenix.LiveView.cancel_upload/3` works from
  hook callbacks.

  ## Usage

      # In ChatLive.mount/3, after allow_upload calls:
      socket = PlatformWeb.ChatLive.UploadHooks.attach(socket)

      # In parent handle_event("upload_send", …) after successful send:
      socket = PlatformWeb.ChatLive.UploadHooks.reset(socket)
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, cancel_upload: 3]

  @doc "Attach Upload handlers. Call from `ChatLive.mount/3`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:upload_dialog_open, false)
    |> assign(:upload_caption, "")
    |> assign(:upload_tagged_agents, MapSet.new())
    |> attach_hook(:upload_events, :handle_event, &handle_event/3)
  end

  @doc """
  Reset dialog state and clear tagged agents. Called by the parent
  LiveView after `upload_send` successfully posts a message.
  """
  @spec reset(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reset(socket) do
    socket
    |> assign(:upload_dialog_open, false)
    |> assign(:upload_caption, "")
    |> assign(:upload_tagged_agents, MapSet.new())
  end

  # ── Hook callbacks ────────────────────────────────────────────────────

  defp handle_event("upload_dialog_open", _params, socket) do
    {:halt, assign(socket, :upload_dialog_open, true)}
  end

  defp handle_event("upload_dialog_close", _params, socket) do
    socket =
      Enum.reduce(socket.assigns.uploads.attachments.entries, socket, fn entry, acc ->
        cancel_upload(acc, :attachments, entry.ref)
      end)

    {:halt, reset(socket)}
  end

  defp handle_event("upload_caption_change", %{"caption" => text}, socket) do
    {:halt, assign(socket, :upload_caption, text)}
  end

  defp handle_event("upload_entry_cancel", %{"ref" => ref}, socket) do
    {:halt, cancel_upload(socket, :attachments, ref)}
  end

  defp handle_event("upload_toggle_agent", %{"agent" => slug}, socket) do
    tagged = socket.assigns.upload_tagged_agents

    tagged =
      if MapSet.member?(tagged, slug),
        do: MapSet.delete(tagged, slug),
        else: MapSet.put(tagged, slug)

    {:halt, assign(socket, :upload_tagged_agents, tagged)}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}
end
