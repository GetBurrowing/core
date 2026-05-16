defmodule PlatformWeb.ChatLive.Embedded do
  @moduledoc """
  Thin embedding wrapper around `PlatformWeb.ChatLive`.

  Stage 5 of task 019e2d1a swapped the original `MeetingChatPanelLive`
  stub for the canonical chat surface inside the meeting chat pane.
  We can't `live_render` `ChatLive` itself as a child LiveView: Phoenix
  forbids any module that defines `handle_params/3` from being mounted
  as a nested LV (raised in `Phoenix.LiveView.Static.disconnected_nested_render/6`
  when `Lifecycle.stage_info(socket, view, :handle_params, 3).any?`). The
  standalone surface needs `handle_params/3` to make channel-to-channel
  patches work without a full remount.

  So this module exists as a sibling LiveView that:

    * does NOT define `handle_params/3` — safe to nest;
    * delegates `mount/3` to `PlatformWeb.ChatLive.embedded_mount/3`,
      which seeds the active space from `session["chat_space_slug"]`
      (URL params don't flow to child LVs) and attaches the same hook
      chain (Presence / Messages / Pin / Search / Mentions / Upload /
      Canvas / ActiveAgent) as the standalone surface, minus the
      MeetingHooks attach (the parent MeetingLive already owns the
      LiveKit lifecycle);
    * delegates `render/1` to `PlatformWeb.ChatLive.render/1` so the
      embed renders the exact same template as the URL-routed surface,
      with the `:embedded` assign gating off the sidebar, mobile pills,
      mobile browser overlay, desktop chat header, settings/new-channel/
      new-conversation modals, the meeting mini-bar, and the duplicate
      JS-hook anchors;
    * delegates `handle_event/3`, `handle_info/2`, and `terminate/2` to
      `ChatLive` so the embed answers events the same way (mentions,
      uploads, message-actions sheet, edits, reactions, threads, …)
      with no duplicated code.

  See `PlatformWeb.MeetingLive` `@moduledoc` for the embedding contract.
  """
  use PlatformWeb, :live_view

  @impl true
  def mount(params, session, socket),
    do: PlatformWeb.ChatLive.embedded_mount(params, session, socket)

  @impl true
  def render(assigns), do: PlatformWeb.ChatLive.render(assigns)

  @impl true
  def handle_event(event, params, socket),
    do: PlatformWeb.ChatLive.handle_event(event, params, socket)

  @impl true
  def handle_info(msg, socket),
    do: PlatformWeb.ChatLive.handle_info(msg, socket)

  @impl true
  def terminate(reason, socket),
    do: PlatformWeb.ChatLive.terminate(reason, socket)
end
