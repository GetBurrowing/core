defmodule PlatformWeb.ChatLive.PresenceHooksScopeTest do
  @moduledoc """
  rbac-external-users M10 stage 3 — the defense-in-depth consumer-side guards.

  Even if a subscribe bug (or a future code path) delivered an out-of-scope
  presence_diff / {:agent_typing} to an external session, PresenceHooks drops
  it; and an external user is never written into the presence roster of a space
  outside their allowlisted scope. Internal sessions (nil scope) keep today's
  behavior exactly — every guard short-circuits to "allow" on nil.

  The three scope predicates are exercised directly (the exact decision each
  handler makes), and `enter_space/4`'s presence-write gate is exercised
  end-to-end against a real connected socket + Presence.
  """
  use Platform.DataCase, async: false

  alias Phoenix.LiveView.Socket
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Presence, as: ChatPresence
  alias Platform.Repo
  alias PlatformWeb.ChatLive.PresenceHooks

  # ── Unit sockets (DB-free) ───────────────────────────────────────────

  defp socket_with(assigns) do
    %Socket{assigns: Map.put(assigns, :__changed__, %{})}
  end

  describe "presence_diff scope guard — external_active_out_of_scope?/1" do
    test "external session with active_space OUT of scope drops the diff" do
      socket =
        socket_with(%{
          external_scope_space_ids: MapSet.new(["a"]),
          active_space: %{id: "b"}
        })

      assert PresenceHooks.external_active_out_of_scope?(socket)
    end

    test "external session with active_space IN scope applies the diff" do
      socket =
        socket_with(%{
          external_scope_space_ids: MapSet.new(["a"]),
          active_space: %{id: "a"}
        })

      refute PresenceHooks.external_active_out_of_scope?(socket)
    end

    test "internal session (nil scope) always applies (no regression)" do
      socket =
        socket_with(%{
          external_scope_space_ids: nil,
          active_space: %{id: "b"}
        })

      refute PresenceHooks.external_active_out_of_scope?(socket)
    end

    test "external session with no active_space does not force a drop" do
      socket = socket_with(%{external_scope_space_ids: MapSet.new(["a"]), active_space: nil})

      refute PresenceHooks.external_active_out_of_scope?(socket)
    end
  end

  describe "typing scope guard — typing_in_external_scope?/2" do
    test "external session applies typing for an in-scope space" do
      socket = socket_with(%{external_scope_space_ids: MapSet.new(["a"])})

      assert PresenceHooks.typing_in_external_scope?(%{space_id: "a"}, socket)
    end

    test "external session drops typing for an out-of-scope space" do
      socket = socket_with(%{external_scope_space_ids: MapSet.new(["a"])})

      refute PresenceHooks.typing_in_external_scope?(%{space_id: "b"}, socket)
    end

    test "external session drops an unverifiable typing payload (no :space_id, fail-closed)" do
      socket = socket_with(%{external_scope_space_ids: MapSet.new(["a"])})

      refute PresenceHooks.typing_in_external_scope?(%{typing: true}, socket)
    end

    test "internal session (nil scope) applies typing for any space (no regression)" do
      socket = socket_with(%{external_scope_space_ids: nil})

      assert PresenceHooks.typing_in_external_scope?(%{space_id: "b"}, socket)
      assert PresenceHooks.typing_in_external_scope?(%{typing: true}, socket)
    end
  end

  # ── enter_space presence-write gate (connected socket + Presence) ────

  defp create_user! do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{email: "u-#{n}@example.com", name: "User #{n}", oidc_sub: "oidc-#{n}"})
    |> Repo.insert!()
  end

  defp channel do
    {:ok, space} =
      Chat.create_space(%{
        name: "Chan",
        slug: "chan-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp add_user(space_id, user_id) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user_id,
        joined_at: DateTime.utc_now()
      })

    p
  end

  # A connected socket (transport_pid set → connected?/1 true) carrying an
  # explicit external scope, so `enter_space/4` actually reaches its
  # `track_in_space` call and the scope gate is the only thing in the way.
  defp connected_socket(user_id, scope) do
    %Socket{
      transport_pid: self(),
      assigns: %{__changed__: %{}, user_id: user_id, external_scope_space_ids: scope}
    }
  end

  describe "enter_space/4 presence-write gate — space_in_external_scope?/2" do
    test "external user IS tracked when entering an in-scope space" do
      user = create_user!()
      a = channel()
      p = add_user(a.id, user.id)
      socket = connected_socket(user.id, MapSet.new([a.id]))

      PresenceHooks.enter_space(socket, a, p, [p])

      assert Map.has_key?(ChatPresence.list_space(a.id), user.id)
    end

    test "external user is NOT tracked when entering an out-of-scope space" do
      user = create_user!()
      b = channel()
      p = add_user(b.id, user.id)
      # Scope allowlists a different space — b is out of scope.
      socket = connected_socket(user.id, MapSet.new([Ecto.UUID.generate()]))

      PresenceHooks.enter_space(socket, b, p, [p])

      refute Map.has_key?(ChatPresence.list_space(b.id), user.id)
      assert ChatPresence.online_count(b.id) == 0
    end

    test "internal user (nil scope) IS tracked in any space (no regression)" do
      user = create_user!()
      b = channel()
      p = add_user(b.id, user.id)
      socket = connected_socket(user.id, nil)

      PresenceHooks.enter_space(socket, b, p, [p])

      assert Map.has_key?(ChatPresence.list_space(b.id), user.id)
    end
  end
end
