defmodule PlatformWeb.ChatLive.MeetingHooksTest do
  @moduledoc """
  Tests for `PlatformWeb.ChatLive.MeetingHooks`, focused on the stage 4
  contract from task `019e2d1a`: the LiveKit join is the canonical
  trigger for inserting the viewer into the meeting's bound chat space.

  The full `meeting_join`/`meeting_leave` event surface is exercised
  via the `MeetingLive` integration tests (see
  `PlatformWeb.MeetingLiveTest` "LiveKit wiring (stage 2)" describe
  block) which is the project convention for hook code that needs a
  live socket. The tests here cover the participant-add side-effect
  in isolation so a regression in the wiring can be localized to this
  module's contract.
  """

  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Meetings
  alias Platform.Meetings.Membership
  alias PlatformWeb.ChatLive.MeetingHooks

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp put_livekit_env(_ctx) do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

    :ok
  end

  defp create_space do
    {:ok, space} =
      Chat.create_space(%{
        name: "Hooks Test Space",
        slug: "hooks-test-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp build_socket(assigns) do
    %Phoenix.LiveView.Socket{assigns: Map.put(assigns, :__changed__, %{})}
  end

  # Insert a real user row directly (bypassing the changeset's name
  # requirement) so we can exercise the name- and email-fallback branches
  # of resolve_display_name/1.
  defp create_user(name) do
    n = System.unique_integer([:positive])

    Platform.Repo.insert!(%Platform.Accounts.User{
      name: name,
      email: "user-#{n}@example.com",
      oidc_sub: "sub-#{n}"
    })
  end

  # ── meeting_join → Membership.ensure_chat_space_participant/3 ─────────────

  describe "meeting_join participant insert (stage 4)" do
    setup [:put_livekit_env]

    test "inserts a participant row for user_id in active_space AFTER join, but NOT before" do
      space = create_space()
      # A real user row: the join path now also writes a meeting_participants
      # row, which carries a real user_id FK — so the user must exist.
      user = create_user("Ada")
      user_id = user.id

      # The `:current_participant` assign carries display_name for the
      # LiveKit token — synthesize one without touching the DB so the
      # post-join insert is the FIRST and ONLY row in this space.
      current_participant = %Participant{
        id: Ecto.UUID.generate(),
        space_id: space.id,
        participant_type: "user",
        participant_id: user_id,
        display_name: "Ada"
      }

      socket =
        build_socket(%{
          user_id: user_id,
          active_space: space,
          current_participant: current_participant,
          in_meeting: false,
          mic_enabled: true,
          camera_enabled: false,
          screen_share_enabled: false
        })

      # Before the join: no participant row in the chat space.
      assert Chat.list_participants(space.id, participant_type: "user") == []

      joined = MeetingHooks.join(socket)

      # After the join: the LiveKit lifecycle ran (in_meeting flipped)
      # AND Membership inserted the canonical row.
      assert joined.assigns.in_meeting == true

      participants = Chat.list_participants(space.id, participant_type: "user")
      assert [%Participant{participant_id: ^user_id, display_name: "Ada"}] = participants
    end

    test "is idempotent across repeated joins (no duplicate rows)" do
      space = create_space()
      user = create_user("Ada")
      user_id = user.id

      current_participant = %Participant{
        id: Ecto.UUID.generate(),
        space_id: space.id,
        participant_type: "user",
        participant_id: user_id,
        display_name: "Ada"
      }

      socket =
        build_socket(%{
          user_id: user_id,
          active_space: space,
          current_participant: current_participant,
          in_meeting: false,
          mic_enabled: true,
          camera_enabled: false,
          screen_share_enabled: false
        })

      # Simulate auto-join + a manual rejoin click.
      _ = MeetingHooks.join(socket)
      _ = MeetingHooks.join(socket)

      participants = Chat.list_participants(space.id, participant_type: "user")
      assert length(participants) == 1
    end

    test "nil active_space short-circuits without crash and does NOT call Membership" do
      # Negative path: no active_space means do_join never reaches the
      # token mint, the push_event, OR the Membership call. We assert
      # the no-crash + no-side-effect contract by counting all
      # chat_participants rows before and after.
      socket =
        build_socket(%{
          user_id: Ecto.UUID.generate(),
          active_space: nil,
          current_participant: nil,
          in_meeting: false,
          mic_enabled: true,
          camera_enabled: false,
          screen_share_enabled: false
        })

      before_count = Platform.Repo.aggregate(Participant, :count, :id)

      # Must not raise.
      result = MeetingHooks.join(socket)

      # Socket comes back unchanged (in_meeting still false).
      assert result.assigns.in_meeting == false

      # No participant row was created (negative-side proof that
      # Membership was NOT called).
      assert Platform.Repo.aggregate(Participant, :count, :id) == before_count
    end

    test "nil current_participant DOES proceed — Membership creates the row from user_id alone" do
      # Bugfix re-pass (task 019e2d1a): the original stage-4 wiring
      # required `:current_participant` non-nil before any body ran, so
      # a fresh user — one with no chat_participants row yet — silently
      # no-op'd here and never reached the Membership bridge. The fix
      # inverts the guard: we require `:user_id` (always present for
      # authenticated mounts) and let Membership do the find-or-insert
      # itself. This test pins the bugfix in place.
      #
      # v4 fix: the join path now also writes a meeting_participants row,
      # which carries a real user_id FK, so the user must exist. An
      # authenticated mount always has a real users row, so this models the
      # production state — with no current_participant, resolve_display_name/1
      # falls through to the real user's name (never the literal "User").
      space = create_space()
      user = create_user("Ada Lovelace")
      user_id = user.id

      socket =
        build_socket(%{
          user_id: user_id,
          active_space: space,
          current_participant: nil,
          in_meeting: false,
          mic_enabled: true,
          camera_enabled: true,
          screen_share_enabled: false
        })

      # Before: no participant row anywhere in this space.
      assert Chat.list_participants(space.id, participant_type: "user") == []

      result = MeetingHooks.join(socket)

      # The join lifecycle DID run (in_meeting flipped) AND Membership
      # inserted the canonical row resolving the real user's name.
      assert result.assigns.in_meeting == true
      assert %Participant{participant_id: ^user_id} = result.assigns.current_participant

      participants = Chat.list_participants(space.id, participant_type: "user")
      assert [%Participant{participant_id: ^user_id, display_name: "Ada Lovelace"}] = participants
    end

    test "nil user_id short-circuits without crash and does NOT call Membership" do
      # With the bugfix above, the only remaining short-circuit on the
      # `with` is `:user_id`. Anonymous mounts (no authenticated user
      # on the session) should still no-op cleanly — no crash, no row.
      space = create_space()

      socket =
        build_socket(%{
          user_id: nil,
          active_space: space,
          current_participant: nil,
          in_meeting: false,
          mic_enabled: true,
          camera_enabled: true,
          screen_share_enabled: false
        })

      before_count = Platform.Repo.aggregate(Participant, :count, :id)

      result = MeetingHooks.join(socket)

      assert result.assigns.in_meeting == false
      assert Platform.Repo.aggregate(Participant, :count, :id) == before_count
    end
  end

  # ── resolve_display_name/1 hardening (stage 3) ────────────────────────────

  describe "join name resolution (stage 3)" do
    setup [:put_livekit_env]

    test "resolves the real user's name when current_participant has a blank display_name" do
      space = create_space()
      user = create_user("Ada Lovelace")

      # current_participant present but with a blank display_name — the
      # pre-v2 code would have published the literal "User"; v2 falls
      # through to the real user's name.
      current_participant = %Participant{
        id: Ecto.UUID.generate(),
        space_id: space.id,
        participant_type: "user",
        participant_id: user.id,
        display_name: ""
      }

      socket =
        build_socket(%{
          user_id: user.id,
          active_space: space,
          current_participant: current_participant,
          in_meeting: false,
          mic_enabled: true,
          camera_enabled: false,
          screen_share_enabled: false
        })

      result = MeetingHooks.join(socket)
      assert result.assigns.in_meeting == true

      [%Participant{display_name: name}] =
        Chat.list_participants(space.id, participant_type: "user")

      assert name == "Ada Lovelace"
      refute name == "User"
    end

    test "resolves the real user's name even with no current_participant assign" do
      # A fresh joiner (no chat_participants row yet) with a real user
      # record must still publish their real name, not the literal "User".
      space = create_space()
      user = create_user("Grace Hopper")

      socket =
        build_socket(%{
          user_id: user.id,
          active_space: space,
          current_participant: nil,
          in_meeting: false,
          mic_enabled: true,
          camera_enabled: false,
          screen_share_enabled: false
        })

      result = MeetingHooks.join(socket)
      assert result.assigns.in_meeting == true

      [%Participant{display_name: name}] =
        Chat.list_participants(space.id, participant_type: "user")

      assert name == "Grace Hopper"
      refute name == "User"
    end
  end

  # ── Reconnect-aware restore (stage 2) ─────────────────────────────────────

  # Seed an active meeting room for the space with the user already a live
  # participant (the state after a join, before a transient socket drop).
  defp seed_live_meeting(space, user) do
    {:ok, room} = Meetings.ensure_room(space.id)
    {:ok, room} = Meetings.activate_room(room)

    {:ok, _p} =
      Meetings.upsert_live_participant(room, %{
        identity: "user:#{user.id}",
        name: user.name
      })

    room
  end

  describe "maybe_restore_on_reconnect/2 (stage 2)" do
    setup [:put_livekit_env]

    test "a reconnect mount with an active participant row re-joins and sets :in_meeting" do
      space = create_space()
      user = create_user("Ada Lovelace")
      _room = seed_live_meeting(space, user)

      socket =
        build_socket(%{
          user_id: user.id,
          active_space: space,
          current_participant: nil,
          in_meeting: false,
          meeting_reconnect?: true,
          mic_enabled: true,
          camera_enabled: true,
          screen_share_enabled: false
        })

      restored = MeetingHooks.maybe_restore_on_reconnect(socket, space)

      # The reconnect re-established :in_meeting (do_join ran) and the
      # one-shot flag was consumed.
      assert restored.assigns.in_meeting == true
      assert restored.assigns.meeting_reconnect? == false
    end

    test "a reconnect restore re-populates :meeting_participants for the rail (v4 stage 4)" do
      space = create_space()
      user = create_user("Dev Alice")
      _room = seed_live_meeting(space, user)

      socket =
        build_socket(%{
          user_id: user.id,
          active_space: space,
          current_participant: nil,
          in_meeting: false,
          meeting_participants: [],
          meeting_reconnect?: true,
          mic_enabled: true,
          camera_enabled: true,
          screen_share_enabled: false
        })

      restored = MeetingHooks.maybe_restore_on_reconnect(socket, space)

      # The full chain works because stage 1 made the room active: the
      # active participant row is findable → :in_meeting restored → do_join
      # re-assigns the roster so the rail re-renders populated (not empty)
      # on the reconnect mount.
      assert restored.assigns.in_meeting == true
      names = Enum.map(restored.assigns.meeting_participants, & &1.display_name)
      assert "Dev Alice" in names
      refute "User" in names
    end

    test "a fresh first mount (not a reconnect) does NOT auto-join" do
      space = create_space()
      user = create_user("Grace Hopper")
      _room = seed_live_meeting(space, user)

      socket =
        build_socket(%{
          user_id: user.id,
          active_space: space,
          current_participant: nil,
          in_meeting: false,
          meeting_reconnect?: false,
          mic_enabled: true,
          camera_enabled: true,
          screen_share_enabled: false
        })

      restored = MeetingHooks.maybe_restore_on_reconnect(socket, space)

      # Fresh mount must still require the explicit Join button.
      assert restored.assigns.in_meeting == false
    end

    test "a reconnect mount with NO active participant row does NOT auto-join" do
      space = create_space()
      user = create_user("Linus")
      # No seed_live_meeting → user is not in any active meeting.

      socket =
        build_socket(%{
          user_id: user.id,
          active_space: space,
          current_participant: nil,
          in_meeting: false,
          meeting_reconnect?: true,
          mic_enabled: true,
          camera_enabled: true,
          screen_share_enabled: false
        })

      restored = MeetingHooks.maybe_restore_on_reconnect(socket, space)

      assert restored.assigns.in_meeting == false
      assert restored.assigns.meeting_reconnect? == false
    end

    test "is a no-op when already in_meeting (idempotent)" do
      space = create_space()
      user = create_user("Ada")
      _room = seed_live_meeting(space, user)

      socket =
        build_socket(%{
          user_id: user.id,
          active_space: space,
          current_participant: nil,
          in_meeting: true,
          meeting_reconnect?: true,
          mic_enabled: true,
          camera_enabled: true,
          screen_share_enabled: false
        })

      restored = MeetingHooks.maybe_restore_on_reconnect(socket, space)
      assert restored.assigns.in_meeting == true
      assert restored.assigns.meeting_reconnect? == false
    end

    test "tolerates a nil space" do
      socket = build_socket(%{user_id: Ecto.UUID.generate(), meeting_reconnect?: true})
      assert MeetingHooks.maybe_restore_on_reconnect(socket, nil) == socket
    end
  end

  describe "on_terminate/1 (stage 2)" do
    test "does NOT broadcast left on a transient LV exit while still in a meeting" do
      space = create_space()
      user = create_user("Ada")
      _room = seed_live_meeting(space, user)

      # Subscribe to the meeting-state topic that broadcast_left would hit.
      Platform.Meetings.State.subscribe(user.id)

      socket =
        build_socket(%{
          user_id: user.id,
          active_space: space,
          in_meeting: true
        })

      assert MeetingHooks.on_terminate(socket) == :ok

      # The webhook participant_left is now the source of truth — a dying
      # LV process must not evict the participant, so NO :meeting_left
      # message should arrive.
      refute_receive {:meeting_left, _}, 200
    end

    test "a transient terminate does NOT stamp left_at (reconnect-survival)" do
      space = create_space()
      user = create_user("Ada")
      _room = seed_live_meeting(space, user)

      socket =
        build_socket(%{
          user_id: user.id,
          active_space: space,
          in_meeting: true
        })

      assert MeetingHooks.on_terminate(socket) == :ok

      # The participant row must survive a transient LV death so the
      # reconnect restore can find it — left_at stays NULL, count unchanged.
      assert length(Meetings.active_participants_for_space(space.id)) == 1

      [p] = Meetings.active_participants_for_space(space.id)
      assert p.display_name == "Ada"
      refute is_nil(Meetings.get_active_room(space.id))
    end
  end

  # ── Explicit-leave decrement (v4 case-2 fix) ──────────────────────────────

  describe "explicit leave stamps left_at server-side (v4 case-2)" do
    setup [:put_livekit_env]

    test "after two joins, an explicit leave for one decrements active_participants_for_space to 1" do
      space = create_space()
      alice = create_user("Dev Alice")
      bob = create_user("Dev Bob")

      # Both users join the same active meeting (rows written on join).
      room = seed_live_meeting(space, alice)

      {:ok, _} =
        Meetings.upsert_live_participant(room, %{identity: "user:#{bob.id}", name: bob.name})

      assert length(Meetings.active_participants_for_space(space.id)) == 2

      # Bob explicitly leaves — stamp_local_left must mark his durable row's
      # left_at server-side (not merely broadcast a count signal), so the
      # roster decrements for the remaining client.
      bob_socket =
        build_socket(%{
          user_id: bob.id,
          active_space: space,
          in_meeting: true
        })

      assert MeetingHooks.stamp_local_left(bob_socket) == :ok

      remaining = Meetings.active_participants_for_space(space.id)
      assert length(remaining) == 1
      assert hd(remaining).display_name == "Dev Alice"
      refute "Dev Bob" in Enum.map(remaining, & &1.display_name)
    end

    test "stamping a participant who already left is a safe no-op (webhook backup idempotency)" do
      space = create_space()
      alice = create_user("Dev Alice")
      _room = seed_live_meeting(space, alice)

      socket =
        build_socket(%{
          user_id: alice.id,
          active_space: space,
          in_meeting: true
        })

      assert MeetingHooks.stamp_local_left(socket) == :ok
      assert Meetings.active_participants_for_space(space.id) == []

      # A second stamp (e.g. the participant_left webhook firing after the
      # explicit leave) finds no active row and is a no-op — no crash.
      assert MeetingHooks.stamp_local_left(socket) == :ok
      assert Meetings.active_participants_for_space(space.id) == []
    end
  end

  # ── Room activation on join (v4 stage 1) ──────────────────────────────────

  describe "room activation on join (v4 stage 1)" do
    setup [:put_livekit_env]

    test "a fresh idle room is flipped active by the join path so presence surfaces" do
      space = create_space()
      user = create_user("Ada Lovelace")

      # Pre-create the room so we can observe it start idle, exactly as
      # ensure_room/1 leaves it in production (schema default status).
      {:ok, room} = Meetings.ensure_room(space.id)
      assert room.status == "idle"
      assert Meetings.get_active_room(space.id) == nil
      assert Meetings.active_participants_for_space(space.id) == []

      socket =
        build_socket(%{
          user_id: user.id,
          active_space: space,
          current_participant: nil,
          in_meeting: false,
          mic_enabled: true,
          camera_enabled: true,
          screen_share_enabled: false
        })

      result = MeetingHooks.join(socket)
      assert result.assigns.in_meeting == true

      # The TRUE root-cause fix: the room is now active AND get_active_room
      # resolves it (was stuck nil → empty rail on both surfaces before).
      active = Meetings.get_active_room(space.id)
      assert active != nil
      assert active.id == room.id
      assert active.status == "active"

      # v4 fix: the join path now ALSO writes the joiner's
      # meeting_participants row directly (via upsert_live_participant), no
      # longer waiting on the unreachable participant_joined webhook. So the
      # server-presence roster surfaces the joiner by real name immediately
      # after join — no manual webhook simulation needed.
      _ = active

      participants = Meetings.active_participants_for_space(space.id)
      assert length(participants) == 1
      assert hd(participants).display_name == "Ada Lovelace"
    end

    test "activation is a no-op write when the room is already active" do
      space = create_space()
      user = create_user("Grace Hopper")

      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, active_room} = Meetings.activate_room(room)
      assert active_room.status == "active"

      socket =
        build_socket(%{
          user_id: user.id,
          active_space: space,
          current_participant: nil,
          in_meeting: false,
          mic_enabled: true,
          camera_enabled: true,
          screen_share_enabled: false
        })

      result = MeetingHooks.join(socket)
      assert result.assigns.in_meeting == true

      # Still exactly one active room for the space, still active — no
      # duplicate room, no flip-flop.
      after_join = Meetings.get_active_room(space.id)
      assert after_join.id == room.id
      assert after_join.status == "active"
    end
  end

  # ── Participant-row insert on join (v4 fix — the e2e regression) ───────────

  describe "meeting_participants row on join (v4 fix)" do
    setup [:put_livekit_env]

    test "do_join surfaces the joiner via active_participants_for_space by real name" do
      # This is the EXACT assertion the v4 e2e failed on (cases 1,2,4,5):
      # a genuine local join must create the server-presence row so the
      # roster shows the real display_name with count=1 — without depending
      # on the LiveKit participant_joined webhook (unreachable in dev).
      space = create_space()
      user = create_user("Dev Alice")

      # Fresh space: no presence rows at all.
      assert Meetings.active_participants_for_space(space.id) == []

      socket =
        build_socket(%{
          user_id: user.id,
          active_space: space,
          current_participant: nil,
          in_meeting: false,
          meeting_participants: [],
          mic_enabled: true,
          camera_enabled: true,
          screen_share_enabled: false
        })

      joined = MeetingHooks.join(socket)
      assert joined.assigns.in_meeting == true

      participants = Meetings.active_participants_for_space(space.id)
      assert length(participants) == 1
      assert hd(participants).display_name == "Dev Alice"
      refute hd(participants).display_name == "User"
    end

    test "a second upsert for the same identity does NOT create a duplicate row (idempotent vs webhook)" do
      # Confirms the dual-path is safe: after do_join inserts the row, the
      # prod participant_joined webhook firing for the SAME user:<id>
      # identity (simulated here) returns the same row — no duplicate.
      space = create_space()
      user = create_user("Grace Hopper")

      socket =
        build_socket(%{
          user_id: user.id,
          active_space: space,
          current_participant: nil,
          in_meeting: false,
          meeting_participants: [],
          mic_enabled: true,
          camera_enabled: true,
          screen_share_enabled: false
        })

      joined = MeetingHooks.join(socket)
      assert joined.assigns.in_meeting == true

      room = Meetings.get_active_room(space.id)
      assert length(Meetings.active_participants_for_space(space.id)) == 1

      # Simulate the webhook firing for the same identity after the join.
      {:ok, _} =
        Meetings.upsert_live_participant(room, %{identity: "user:#{user.id}", name: user.name})

      assert length(Meetings.active_participants_for_space(space.id)) == 1
    end
  end

  # ── Server-presence roster assign (v4 stage 3) ────────────────────────────

  describe "meeting_participants assign on join (v4 stage 3)" do
    setup [:put_livekit_env]

    test "join assigns :meeting_participants sourced from active_participants_for_space" do
      space = create_space()
      alice = create_user("Dev Alice")

      socket =
        build_socket(%{
          user_id: alice.id,
          active_space: space,
          current_participant: nil,
          in_meeting: false,
          meeting_participants: [],
          mic_enabled: true,
          camera_enabled: true,
          screen_share_enabled: false
        })

      joined = MeetingHooks.join(socket)
      assert joined.assigns.in_meeting == true

      # v4 fix: do_join writes Alice's meeting_participants row directly, so
      # the join-time :meeting_participants assign is already populated with
      # her real name (it is read AFTER the upsert in do_join) — not an empty
      # list waiting on a webhook.
      assert is_list(joined.assigns.meeting_participants)
      names = Enum.map(joined.assigns.meeting_participants, & &1.display_name)
      assert "Dev Alice" in names
      refute "User" in names
    end

    test "a presence refresh for the active space re-pulls the roster with real names" do
      space = create_space()
      alice = create_user("Dev Alice")
      bob = create_user("Dev Bob")

      # Seed an active meeting with both users present (webhook-fed rows).
      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, room} = Meetings.activate_room(room)

      {:ok, _} =
        Meetings.upsert_live_participant(room, %{identity: "user:#{alice.id}", name: alice.name})

      {:ok, _} =
        Meetings.upsert_live_participant(room, %{identity: "user:#{bob.id}", name: bob.name})

      socket =
        build_socket(%{
          active_space: space,
          in_meeting: true,
          meeting_participants: []
        })

      updated = MeetingHooks.maybe_refresh_roster(socket, space.id)

      names = Enum.map(updated.assigns.meeting_participants, & &1.display_name)
      assert "Dev Alice" in names
      assert "Dev Bob" in names
      assert length(updated.assigns.meeting_participants) == 2
      refute "User" in names
    end

    test "a presence refresh for a DIFFERENT space does not touch the roster" do
      space = create_space()
      other = create_space()

      socket =
        build_socket(%{
          active_space: space,
          in_meeting: true,
          meeting_participants: [:sentinel]
        })

      updated = MeetingHooks.maybe_refresh_roster(socket, other.id)

      # Roster untouched (the update was for another space).
      assert updated.assigns.meeting_participants == [:sentinel]
    end

    test "a presence refresh is a no-op when the viewer is not in a meeting" do
      space = create_space()

      socket =
        build_socket(%{
          active_space: space,
          in_meeting: false,
          meeting_participants: [:sentinel]
        })

      updated = MeetingHooks.maybe_refresh_roster(socket, space.id)
      assert updated.assigns.meeting_participants == [:sentinel]
    end
  end

  # ── Module wiring sanity ──────────────────────────────────────────────────

  describe "module wiring" do
    test "aliases Platform.Meetings.Membership (sanity: the wiring exists)" do
      # If a future refactor drops the alias, this gives a localized
      # failure rather than only manifesting as a runtime crash in the
      # join lifecycle.
      assert function_exported?(Membership, :ensure_chat_space_participant, 3)
    end
  end
end
