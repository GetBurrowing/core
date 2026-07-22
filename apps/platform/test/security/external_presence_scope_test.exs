defmodule Platform.Security.ExternalPresenceScopeTest do
  @moduledoc """
  M15 security suite — Stage 5 (S5), presence half: presence/typing scope (M10).

  The external user's presence/typing is scoped to their allowlisted spaces at
  three enforcement points, each proven directly against its shipped seam
  (deliberately NOT via a brittle full ChatLive mount+broadcast — the source
  marks `presence_subscribe_space_ids/2` "Public only so the subscribe-scope
  decision is unit-testable without a LiveView"):

    * SUBSCRIBE FILTER — `ChatLive.presence_subscribe_space_ids/2` (the exact
      function `mount/3` folds every candidate space through before
      subscribing) intersects an EXTERNAL user to their member spaces, so an
      out-of-scope space's `chat:space:<id>` topic is never subscribed; an
      INTERNAL user subscribes to every candidate (regression).
    * CONSUMER GUARDS (defense in depth) — even if an out-of-scope
      presence_diff / `{:agent_typing}` reached an external session,
      `PresenceHooks.external_active_out_of_scope?/1` /
      `typing_in_external_scope?/2` drop it; nil scope (internal) always applies.
    * PRESENCE-WRITE GATE — `PresenceHooks.enter_space/4` never tracks an
      external user into an out-of-scope space (no presence roster write),
      exercised end-to-end against real `Chat.Presence`.

  Binds to M10 shipped: `Chat.list_member_space_ids/2`,
  `Chat.Presence.external_scope_space_ids/1`, `presence_subscribe_space_ids/2`,
  and the PresenceHooks guards.
  """
  use Platform.DataCase, async: false

  alias Phoenix.LiveView.Socket
  alias Platform.Chat
  alias Platform.Chat.Presence, as: ChatPresence
  alias Platform.ExternalUserFixtures, as: World
  alias PlatformWeb.ChatLive
  alias PlatformWeb.ChatLive.PresenceHooks

  setup do
    World.external_world()
  end

  # ── Primitives ─────────────────────────────────────────────────────────

  describe "scope primitives" do
    test "list_member_space_ids returns only the external user's spaces", ctx do
      ids = Chat.list_member_space_ids(ctx.ext.id)
      assert ctx.a.id in ids
      refute ctx.b.id in ids
    end

    test "external_scope_space_ids is a MapSet of member spaces", ctx do
      scope = ChatPresence.external_scope_space_ids(ctx.ext.id)
      assert %MapSet{} = scope
      assert MapSet.member?(scope, ctx.a.id)
      refute MapSet.member?(scope, ctx.b.id)
    end
  end

  # ── Subscribe filter ───────────────────────────────────────────────────

  describe "subscribe filter — presence_subscribe_space_ids/2" do
    test "external user subscribes ONLY to in-scope space A, never B", ctx do
      subscribed = ChatLive.presence_subscribe_space_ids([ctx.a, ctx.b], ctx.ext.id)
      assert subscribed == [ctx.a.id]
      refute ctx.b.id in subscribed
    end

    test "regression: internal user subscribes to BOTH A and B", ctx do
      subscribed = ChatLive.presence_subscribe_space_ids([ctx.a, ctx.b], ctx.int.id)
      assert ctx.a.id in subscribed
      assert ctx.b.id in subscribed
    end
  end

  # ── Consumer guards (defense in depth) ─────────────────────────────────

  describe "consumer guards drop out-of-scope events for external sessions" do
    test "presence_diff dropped when active_space is out of scope", ctx do
      out =
        socket_with(%{
          external_scope_space_ids: MapSet.new([ctx.a.id]),
          active_space: %{id: ctx.b.id}
        })

      assert PresenceHooks.external_active_out_of_scope?(out)

      in_scope =
        socket_with(%{
          external_scope_space_ids: MapSet.new([ctx.a.id]),
          active_space: %{id: ctx.a.id}
        })

      refute PresenceHooks.external_active_out_of_scope?(in_scope)
    end

    test "typing applied only for in-scope space; out-of-scope + unverifiable dropped", ctx do
      socket = socket_with(%{external_scope_space_ids: MapSet.new([ctx.a.id])})
      assert PresenceHooks.typing_in_external_scope?(%{space_id: ctx.a.id}, socket)
      refute PresenceHooks.typing_in_external_scope?(%{space_id: ctx.b.id}, socket)
      # Fail-closed: no :space_id on the payload.
      refute PresenceHooks.typing_in_external_scope?(%{typing: true}, socket)
    end

    test "regression: internal (nil scope) always applies", _ctx do
      socket =
        socket_with(%{external_scope_space_ids: nil, active_space: %{id: Ecto.UUID.generate()}})

      refute PresenceHooks.external_active_out_of_scope?(socket)
      assert PresenceHooks.typing_in_external_scope?(%{typing: true}, socket)
    end
  end

  # ── Presence-write gate (end-to-end against real Presence) ─────────────

  describe "enter_space/4 presence-write gate" do
    test "external user IS tracked entering an in-scope space", ctx do
      socket = connected_socket(ctx.ext.id, MapSet.new([ctx.a.id]))
      PresenceHooks.enter_space(socket, ctx.a, ctx.p_a_ext, [ctx.p_a_ext])
      assert Map.has_key?(ChatPresence.list_space(ctx.a.id), ctx.ext.id)
    end

    test "external user is NOT tracked entering an out-of-scope space (no roster write)", ctx do
      # Scope allowlists only A; entering B must not write presence.
      socket = connected_socket(ctx.ext.id, MapSet.new([ctx.a.id]))
      p_ext_b = World.add_user!(ctx.b.id, ctx.ext.id)

      PresenceHooks.enter_space(socket, ctx.b, p_ext_b, [p_ext_b])

      refute Map.has_key?(ChatPresence.list_space(ctx.b.id), ctx.ext.id)
      assert ChatPresence.online_count(ctx.b.id) == 0
    end

    test "regression: internal user (nil scope) IS tracked in any space", ctx do
      socket = connected_socket(ctx.int.id, nil)
      PresenceHooks.enter_space(socket, ctx.a, ctx.p_a_int, [ctx.p_a_int])
      assert Map.has_key?(ChatPresence.list_space(ctx.a.id), ctx.int.id)
    end
  end

  # ── Socket helpers ─────────────────────────────────────────────────────

  defp socket_with(assigns) do
    %Socket{assigns: Map.put(assigns, :__changed__, %{})}
  end

  defp connected_socket(user_id, scope) do
    %Socket{
      transport_pid: self(),
      assigns: %{__changed__: %{}, user_id: user_id, external_scope_space_ids: scope}
    }
  end
end
