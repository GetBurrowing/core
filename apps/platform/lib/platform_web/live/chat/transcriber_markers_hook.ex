defmodule PlatformWeb.ChatLive.TranscriberMarkersHook do
  @moduledoc """
  Keeps `@transcriber_markers_json` current on every LiveView that renders
  `#meeting-client` (task 01a0d4fe stage 5).

  `#meeting-client[data-transcriber-markers]` tells `MeetingClient` which
  LiveKit identities are the meeting transcriber, so the JS skips its tile.
  Stage 3 rendered it as
  `Jason.encode!(Platform.Meetings.transcriber_identity_markers())`, an
  expression that references no assign. LiveView change tracking treats such
  an expression as static: it is rendered once and never re-sent, so a runtime
  config change never reached a connected client until it remounted. The
  task-level review measured exactly that (a `put_env` then a mic toggle left
  the attribute at the old list).

  The attribute now reads `@transcriber_markers_json`. This module seeds it
  and attaches a `:handle_event` and a `:handle_info` hook that recompute it
  before every event and message the LiveView handles. `assign/3` records a
  change only when the value differs, so in the steady state the recompute
  sends nothing to the client; after a config change the next event carries
  the new list in its diff.

  `Platform.Meetings.transcriber_identity_markers/0` stays the only source of
  the list. Nothing here keeps a copy.

  ## Where it is attached

  From `PlatformWeb.ChatLive.MeetingHooks.attach/2` and `attach_guest/1`,
  the two functions that also seed `:mic_enabled` / `:camera_enabled`, which
  every `#meeting-client` render already reads. That covers `ChatLive`
  (non-embedded; the embedded surface does not render `#meeting-client`),
  the member `/meetings` surface and the guest surface. It must be attached
  BEFORE the `:meeting_events` / `:meeting_info` hooks: hooks run in attach
  order and those two `:halt` the events they own (the mic toggle among
  them), so a hook attached after them would never see those events.

  An event halted by a hook attached earlier still (for example an upload
  hook in `ChatLive`) skips the recompute; the next event that reaches this
  hook picks the change up.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, detach_hook: 3]

  alias Platform.Meetings

  @hook_id :transcriber_markers

  @doc """
  Seed `@transcriber_markers_json` and (re)attach the recompute hooks.

  Idempotent: `attach_guest/1` runs twice on the guest surface, and
  `attach_hook/4` raises on a duplicate id, so both hooks are detached first.
  """
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> refresh()
    |> detach_hook(@hook_id, :handle_event)
    |> detach_hook(@hook_id, :handle_info)
    |> attach_hook(@hook_id, :handle_event, fn _event, _params, socket ->
      {:cont, refresh(socket)}
    end)
    |> attach_hook(@hook_id, :handle_info, fn _message, socket ->
      {:cont, refresh(socket)}
    end)
  end

  @doc "Assign the current marker list, JSON-encoded, as `:transcriber_markers_json`."
  @spec refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh(socket) do
    assign(socket, :transcriber_markers_json, markers_json())
  end

  @doc "The JSON the `data-transcriber-markers` attribute carries."
  @spec markers_json() :: String.t()
  def markers_json, do: Jason.encode!(Meetings.transcriber_identity_markers())
end
