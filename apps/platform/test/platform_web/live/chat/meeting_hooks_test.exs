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

  # A LIVE `meetings` row bound to `space`. Deliberately explicit in the
  # tests that want one: see the no-meetings-row test below for why a
  # quickmeet join does NOT create one.
  defp seed_live_meeting(space) do
    {:ok, project} =
      %Platform.Tasks.Project{}
      |> Platform.Tasks.Project.changeset(%{
        name: "Quickmeet Project #{System.unique_integer([:positive])}",
        slug: "quickmeet-project-#{System.unique_integer([:positive])}",
        org_id: Platform.TenancyFixtures.fabrikam_org_id()
      })
      |> Platform.Repo.insert()

    meeting_id = Platform.Types.UUIDv7.generate()

    {:ok, meeting} =
      %Platform.Meetings.Meeting{id: meeting_id}
      |> Platform.Meetings.Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "quickmeet-#{System.unique_integer([:positive])}",
        name: "Quickmeet",
        livekit_room_name: "meeting-#{meeting_id}",
        status: "live"
      })
      |> Platform.Repo.insert()

    meeting
  end

  # ── Call-shell data plane (task 01a05b14 stage 6) ────────────────────────
  #
  # THE STAGE'S REAL WORK. Before this, `attach/2` assigned no meeting
  # id, no agent activity and no candidates — so the quickmeet could not
  # have rendered a rail whatever its markup said. These tests name the
  # data, not the markup; `partials_meeting_panel_test.exs` covers what
  # the rail does with it.
  describe "join hydrates the call shell (stage 6)" do
    setup [:put_livekit_env]

    test "join assigns the live meeting id, an AgentActivity and a candidate board" do
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
          screen_share_enabled: false,
          quickmeet_meeting_id: nil,
          quickmeet_meeting: nil,
          agent_activity: nil,
          agents_by_id: %{},
          meeting_candidates: nil,
          meeting_candidates_closed: nil,
          meeting_candidate_events: nil,
          active_meeting_tab: "people"
        })

      meeting = seed_live_meeting(space)

      joined = MeetingHooks.join(socket)

      assert joined.assigns.in_meeting == true
      assert joined.assigns.quickmeet_meeting_id == meeting.id
      assert joined.assigns.quickmeet_meeting.id == meeting.id

      assert %Platform.Meetings.AgentActivity{} = joined.assigns.agent_activity
      assert is_map(joined.assigns.agents_by_id)
      assert is_list(joined.assigns.meeting_candidates)
      assert is_list(joined.assigns.meeting_candidates_closed)
      assert is_map(joined.assigns.meeting_candidate_events)
    end

    test "leaving clears the meeting id and the hydrated rail state" do
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
          screen_share_enabled: false,
          quickmeet_meeting_id: nil,
          quickmeet_meeting: nil,
          quickmeet_rail_open: true,
          agent_activity: nil,
          agents_by_id: %{},
          meeting_candidates: nil,
          meeting_candidates_closed: nil,
          meeting_candidate_events: nil,
          active_meeting_tab: "people"
        })

      seed_live_meeting(space)

      joined = MeetingHooks.join(socket)
      assert is_binary(joined.assigns.quickmeet_meeting_id)

      left = MeetingHooks.reset_state(joined)

      assert left.assigns.in_meeting == false
      assert left.assigns.quickmeet_meeting_id == nil
      assert left.assigns.quickmeet_meeting == nil
      # The `<lg` sheet comes back down; a sheet left up would sit over
      # the chat the user just returned to.
      assert left.assigns.quickmeet_rail_open == false
      assert left.assigns.meeting_candidates == []
    end

    # DOCUMENTED, NOT PAPERED OVER. A quickmeet join calls
    # `ensure_room/1`, which writes a `meeting_rooms` row — NOT a
    # `meetings` row. `meetings` rows are created by `create_meeting/1`
    # (the `/meetings` path). So a chat space whose call came up purely
    # from the "Meet" button has no meeting id, and Canvas, Transcript
    # and the agent-activity badges have nothing to read from.
    #
    # The People pane still works, because it is fed by
    # `:meeting_participants`, which the join populates directly. That
    # is the honest behaviour and it is asserted here rather than being
    # hidden behind a fixture that always seeds a meeting: creating a
    # `meetings` row from a chat join would mint a slug, an inbox row
    # and a `room_finished` end-path, which is a lifecycle change and
    # not a rail wiring change.
    test "a join with no live meetings row leaves the shell empty but keeps People" do
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
          screen_share_enabled: false,
          quickmeet_meeting_id: nil,
          quickmeet_meeting: nil,
          agent_activity: nil,
          agents_by_id: %{},
          meeting_candidates: [],
          meeting_candidates_closed: [],
          meeting_candidate_events: %{},
          active_meeting_tab: "people"
        })

      refute Meetings.get_live_meeting_for_space(space.id)

      joined = MeetingHooks.join(socket)

      assert joined.assigns.in_meeting == true
      assert joined.assigns.quickmeet_meeting_id == nil

      names = Enum.map(joined.assigns.meeting_participants, & &1.display_name)
      assert "Dev Alice" in names
    end
  end

  describe "apply_agent_activity/2 (stage 6)" do
    test "folds a signal for THIS meeting into :agent_activity" do
      meeting_id = Ecto.UUID.generate()
      agent_id = Ecto.UUID.generate()

      socket =
        build_socket(%{
          quickmeet_meeting_id: meeting_id,
          agent_activity: Platform.Meetings.AgentActivity.new()
        })

      updated =
        MeetingHooks.apply_agent_activity(socket, %{
          meeting_id: meeting_id,
          agent_id: agent_id,
          signal: :computing,
          active?: true
        })

      assert Platform.Meetings.AgentActivity.for_agent(updated.assigns.agent_activity, agent_id) ==
               :computing
    end

    test "a signal for a DIFFERENT meeting is ignored" do
      socket =
        build_socket(%{
          quickmeet_meeting_id: Ecto.UUID.generate(),
          agent_activity: Platform.Meetings.AgentActivity.new()
        })

      agent_id = Ecto.UUID.generate()

      updated =
        MeetingHooks.apply_agent_activity(socket, %{
          meeting_id: Ecto.UUID.generate(),
          agent_id: agent_id,
          signal: :computing,
          active?: true
        })

      assert Platform.Meetings.AgentActivity.for_agent(updated.assigns.agent_activity, agent_id) ==
               :idle
    end

    # THE GUARD AGAINST DOUBLE-FOLDING. `MeetingLive` mounts this module
    # AND keeps its own top-level clause for `{:agent_activity, …}`. A
    # socket with no `:quickmeet_meeting_id` — which is every
    # `/meetings` socket, because `join_call_shell/2` refuses to set it
    # when `:meeting` is assigned — must pass the message through
    # untouched.
    test "a socket that never joined a quickmeet is left alone" do
      agent_id = Ecto.UUID.generate()

      socket =
        build_socket(%{
          quickmeet_meeting_id: nil,
          agent_activity: Platform.Meetings.AgentActivity.new()
        })

      updated =
        MeetingHooks.apply_agent_activity(socket, %{
          meeting_id: Ecto.UUID.generate(),
          agent_id: agent_id,
          signal: :computing,
          active?: true
        })

      assert Platform.Meetings.AgentActivity.for_agent(updated.assigns.agent_activity, agent_id) ==
               :idle
    end
  end

  # ── Toggle helpers broadcast media_state (stage 2) ────────────────────────

  describe "toggle_mic/1 broadcasts authoritative media state" do
    test "flips :mic_enabled and broadcasts post-toggle pair to MeetingState.topic(user_id)" do
      user_id = Ecto.UUID.generate()
      Platform.Meetings.State.subscribe(user_id)

      socket =
        build_socket(%{
          user_id: user_id,
          in_meeting: true,
          mic_enabled: true,
          camera_enabled: true,
          screen_share_enabled: false
        })

      updated = MeetingHooks.toggle_mic(socket)

      # Assign flipped to post-toggle truth.
      assert updated.assigns.mic_enabled == false
      assert updated.assigns.camera_enabled == true

      # Subscriber received the full pair — both booleans, no partial update.
      assert_receive {:meeting_media_state,
                      %{user_id: ^user_id, mic_enabled: false, camera_enabled: true}},
                     200
    end

    test "preserves the current :camera_enabled when broadcasting (no stale stitching)" do
      # Producer always carries the full pair so a camera-off + mic-toggle
      # reports camera-off — never reads a default and overwrites with true.
      user_id = Ecto.UUID.generate()
      Platform.Meetings.State.subscribe(user_id)

      socket =
        build_socket(%{
          user_id: user_id,
          in_meeting: true,
          mic_enabled: false,
          camera_enabled: false,
          screen_share_enabled: false
        })

      _ = MeetingHooks.toggle_mic(socket)

      assert_receive {:meeting_media_state,
                      %{user_id: ^user_id, mic_enabled: true, camera_enabled: false}},
                     200
    end

    test "no user_id (anonymous mount) is a safe no-op — no broadcast, no crash" do
      # Defensive: the bar/in-chat consumers key off user_id, so a missing
      # user_id can't be broadcast meaningfully. Must not raise.
      subscriber = Ecto.UUID.generate()
      Platform.Meetings.State.subscribe(subscriber)

      socket =
        build_socket(%{
          user_id: nil,
          in_meeting: true,
          mic_enabled: true,
          camera_enabled: true,
          screen_share_enabled: false
        })

      updated = MeetingHooks.toggle_mic(socket)
      assert updated.assigns.mic_enabled == false

      refute_receive {:meeting_media_state, _}, 100
    end
  end

  describe "toggle_camera/1 broadcasts authoritative media state" do
    test "flips :camera_enabled and broadcasts post-toggle pair to MeetingState.topic(user_id)" do
      user_id = Ecto.UUID.generate()
      Platform.Meetings.State.subscribe(user_id)

      socket =
        build_socket(%{
          user_id: user_id,
          in_meeting: true,
          mic_enabled: true,
          camera_enabled: true,
          screen_share_enabled: false
        })

      updated = MeetingHooks.toggle_camera(socket)

      assert updated.assigns.camera_enabled == false
      assert updated.assigns.mic_enabled == true

      assert_receive {:meeting_media_state,
                      %{user_id: ^user_id, mic_enabled: true, camera_enabled: false}},
                     200
    end

    test "preserves the current :mic_enabled when broadcasting (no stale stitching)" do
      user_id = Ecto.UUID.generate()
      Platform.Meetings.State.subscribe(user_id)

      socket =
        build_socket(%{
          user_id: user_id,
          in_meeting: true,
          mic_enabled: false,
          camera_enabled: true,
          screen_share_enabled: false
        })

      _ = MeetingHooks.toggle_camera(socket)

      # Camera flipped off, mic stays off — both reported faithfully.
      assert_receive {:meeting_media_state,
                      %{user_id: ^user_id, mic_enabled: false, camera_enabled: false}},
                     200
    end
  end

  # ── do_join/1 emits initial media_state so a fresh bar mount has truth ────

  describe "do_join/1 broadcasts initial media state on success" do
    setup [:put_livekit_env]

    test "after a successful join the subscriber receives both :meeting_joined and :meeting_media_state with initial truth" do
      space = create_space()
      user = create_user("Ada Lovelace")
      Platform.Meetings.State.subscribe(user.id)

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

      # The lifecycle emits join then the initial media truth — a fresh bar
      # mount that adopted us on :meeting_joined now has a media-state
      # snapshot to render against without a click.
      user_id = user.id
      assert_receive {:meeting_joined, %{user_id: ^user_id}}, 500

      assert_receive {:meeting_media_state,
                      %{user_id: ^user_id, mic_enabled: true, camera_enabled: true}},
                     500
    end
  end

  # ── Bar→chat media-state lockstep (V3 fix) ───────────────────────────────

  describe "apply_media_state/2 keeps chat-side assigns in lockstep with bar (V3 fix)" do
    # The reviewer's V3 diagnostic: MeetingHooks did NOT subscribe to
    # `meeting:state:{user_id}` events — only ShellLive did. So bar-side
    # broadcasts never updated ChatLive's `:mic_enabled` / `:camera_enabled`
    # assigns, and chat-side toggles then flipped against stale state.
    #
    # The fix has two parts:
    #   1. `attach/2` now calls `MeetingState.subscribe(user_id)` so this
    #      LiveView's MeetingHooks receives its own user's broadcasts.
    #   2. A new `handle_info({:meeting_media_state, ...}, socket)` clause
    #      delegates to the public `apply_media_state/2` which assigns the
    #      pair (guarded on uid match).
    #
    # We exercise (2) directly here — that's the load-bearing contract. The
    # subscription side is covered by the test below using PubSub end-to-end.

    test "applies the broadcast pair when uid matches socket.assigns.user_id" do
      user_id = Ecto.UUID.generate()

      socket =
        build_socket(%{
          user_id: user_id,
          in_meeting: true,
          mic_enabled: true,
          camera_enabled: true,
          screen_share_enabled: false
        })

      updated =
        MeetingHooks.apply_media_state(socket, %{
          user_id: user_id,
          mic_enabled: false,
          camera_enabled: true
        })

      # The bar-side toggle's authoritative truth now lives on the chat-side
      # socket too — a follow-up in-chat click will flip OFF this value, not
      # the stale `true`.
      assert updated.assigns.mic_enabled == false
      assert updated.assigns.camera_enabled == true
    end

    test "ignores broadcasts whose user_id does not match (defensive)" do
      user_id = Ecto.UUID.generate()
      other_user_id = Ecto.UUID.generate()

      socket =
        build_socket(%{
          user_id: user_id,
          in_meeting: true,
          mic_enabled: true,
          camera_enabled: true,
          screen_share_enabled: false
        })

      updated =
        MeetingHooks.apply_media_state(socket, %{
          user_id: other_user_id,
          mic_enabled: false,
          camera_enabled: false
        })

      # Untouched — events for other users never trample our assigns.
      assert updated.assigns.mic_enabled == true
      assert updated.assigns.camera_enabled == true
    end

    test "carries the full pair so a camera-off + bar-mic-flip preserves camera-off" do
      # Producer (MeetingState.broadcast_media_state/2) always carries the
      # full pair, so the apply path must respect both booleans — never
      # stitch a partial update that overrides camera back to its default.
      user_id = Ecto.UUID.generate()

      socket =
        build_socket(%{
          user_id: user_id,
          in_meeting: true,
          mic_enabled: true,
          camera_enabled: false,
          screen_share_enabled: false
        })

      updated =
        MeetingHooks.apply_media_state(socket, %{
          user_id: user_id,
          mic_enabled: false,
          camera_enabled: false
        })

      assert updated.assigns.mic_enabled == false
      assert updated.assigns.camera_enabled == false
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

    test "attach_guest/1 is exported (task 019f498d stage 3)" do
      # Public entry point for the guest ingress in `PlatformWeb.MeetingLive`.
      assert function_exported?(MeetingHooks, :attach_guest, 1)
    end
  end

  # ── attach_guest/1 — media-state seeding (task 019f498d stage 3) ──────────

  # ── Committed media intent survives attach + restore (task 01a08d5a stage 3) ──
  #
  # The LiveView-level twin (`meeting_hooks_reconnect_intent_test.exs`)
  # cannot raise `:meeting_reconnect?` because `Phoenix.LiveViewTest`
  # pins `_mounts` to 0; this is where the restore branch is pinned. The
  # sequence is the real one: `attach/2` on a fresh socket (the reconnect
  # mount) → `maybe_restore_on_reconnect/2` → `do_join/1`, with the ETS row
  # carrying the pair the previous process committed before it died.

  describe "committed media intent survives attach + restore (task 01a08d5a stage 3)" do
    setup [:put_livekit_env]

    # `attach_hook/4` reads `private.lifecycle`; `push_event/3` (the
    # restore join) reads `private.live_temp` — keep the struct's defaults.
    defp lifecycle_socket(assigns) do
      socket = %Phoenix.LiveView.Socket{assigns: Map.put(assigns, :__changed__, %{})}
      %{socket | private: Map.put(socket.private, :lifecycle, %Phoenix.LiveView.Lifecycle{})}
    end

    # The previous LV process: joined (row written), then committed a
    # toggle (pair cached on the row), then died without leaving.
    defp commit_before_drop(space, user, mic, camera) do
      _room = seed_live_meeting(space, user)
      Platform.Meetings.State.broadcast_joined(user.id, space.id, space.name, space.slug, nil)

      Platform.Meetings.State.broadcast_media_state(user.id, %{
        mic_enabled: mic,
        camera_enabled: camera
      })

      on_exit(fn -> Platform.Meetings.State.broadcast_left(user.id) end)
    end

    test "attach/2 seeds :mic_enabled/:camera_enabled from the committed pair, and the restore join keeps them" do
      space = create_space()
      user = create_user("Ada Lovelace")
      commit_before_drop(space, user, false, false)
      Platform.Meetings.State.subscribe(user.id)

      attached = MeetingHooks.attach(lifecycle_socket(%{user_id: user.id}), [])
      assert attached.assigns.mic_enabled == false
      assert attached.assigns.camera_enabled == false

      restored =
        attached
        |> Phoenix.Component.assign(:active_space, space)
        |> Phoenix.Component.assign(:current_participant, nil)
        |> Phoenix.Component.assign(:meeting_reconnect?, true)
        |> MeetingHooks.maybe_restore_on_reconnect(space)

      assert restored.assigns.in_meeting == true
      assert restored.assigns.mic_enabled == false
      assert restored.assigns.camera_enabled == false

      # The restore join's `join-meeting` push carries the committed pair.
      # Since FE-17 stage 4 (c1b076bc) the JS `_join` reads the payload
      # FIRST (`_desiredInitialMedia`) and only falls back to the dataset,
      # so the seeded assigns have to reach the payload, not just the DOM.
      push_events = restored.private[:live_temp][:push_events] || []

      assert [%{mic_enabled: false, camera_enabled: false}] =
               for(["join-meeting", payload] <- push_events, do: payload)

      # The restore join re-broadcasts the COMMITTED pair, not the
      # first-join defaults, and the row still carries it afterwards
      # (`broadcast_joined/5` rewrote the row; the pair must survive that).
      user_id = user.id
      assert_receive {:meeting_joined, %{user_id: ^user_id}}, 500

      assert_receive {:meeting_media_state,
                      %{user_id: ^user_id, mic_enabled: false, camera_enabled: false}},
                     500

      assert Platform.Meetings.State.media_intent(user.id) ==
               %{mic_enabled: false, camera_enabled: false}
    end

    test "only the toggled half is carried: mic off, camera on" do
      space = create_space()
      user = create_user("Ada Lovelace")
      commit_before_drop(space, user, false, true)

      attached = MeetingHooks.attach(lifecycle_socket(%{user_id: user.id}), [])
      assert attached.assigns.mic_enabled == false
      assert attached.assigns.camera_enabled == true
    end

    # POSITIVE CONTROL for the seed: a row with the pair both true, and no
    # row at all, both leave the literal seeds in place.
    test "a committed pair of {true, true} and no row at all both seed the first-join defaults" do
      space = create_space()
      user = create_user("Ada Lovelace")
      commit_before_drop(space, user, true, true)

      attached = MeetingHooks.attach(lifecycle_socket(%{user_id: user.id}), [])
      assert attached.assigns.mic_enabled == true
      assert attached.assigns.camera_enabled == true

      no_row = MeetingHooks.attach(lifecycle_socket(%{user_id: Ecto.UUID.generate()}), [])
      assert no_row.assigns.mic_enabled == true
      assert no_row.assigns.camera_enabled == true

      anonymous = MeetingHooks.attach(lifecycle_socket(%{user_id: nil}), [])
      assert anonymous.assigns.mic_enabled == true
      assert anonymous.assigns.camera_enabled == true
    end

    test "a genuine leave resets: reset_state/1 re-seeds true and the row (with its pair) is gone" do
      space = create_space()
      user = create_user("Ada Lovelace")
      commit_before_drop(space, user, false, false)

      attached = MeetingHooks.attach(lifecycle_socket(%{user_id: user.id}), [])
      assert attached.assigns.mic_enabled == false

      Platform.Meetings.State.broadcast_left(user.id)
      reset = MeetingHooks.reset_state(attached)
      assert reset.assigns.mic_enabled == true
      assert reset.assigns.camera_enabled == true
      assert Platform.Meetings.State.media_intent(user.id) == nil

      fresh = MeetingHooks.attach(lifecycle_socket(%{user_id: user.id}), [])
      assert fresh.assigns.mic_enabled == true
    end

    test "attach_guest/1 seeds from the guest pair keyed by :guest_intent_key, and only then" do
      key = Platform.Meetings.State.guest_intent_key("invite-token-#{System.unique_integer()}")
      on_exit(fn -> Platform.Meetings.State.clear_guest_media_intent(key) end)

      Platform.Meetings.State.put_guest_media_intent(key, %{
        mic_enabled: false,
        camera_enabled: true
      })

      seeded = MeetingHooks.attach_guest(lifecycle_socket(%{user_id: nil, guest_intent_key: key}))
      assert seeded.assigns.mic_enabled == false
      assert seeded.assigns.camera_enabled == true

      other = Platform.Meetings.State.guest_intent_key("some-other-token")

      unrelated =
        MeetingHooks.attach_guest(lifecycle_socket(%{user_id: nil, guest_intent_key: other}))

      assert unrelated.assigns.mic_enabled == true

      keyless = MeetingHooks.attach_guest(lifecycle_socket(%{user_id: nil}))
      assert keyless.assigns.mic_enabled == true
    end
  end

  describe "attach_guest/1" do
    test "seeds the same media-state assigns attach/2 seeds" do
      # Build a socket with the `:lifecycle` slot the `attach_hook/4` call
      # inside `attach_guest/1` reads. Mirroring the real LV socket shape
      # here beats coupling this contract test to a running LV pid.
      socket = %Phoenix.LiveView.Socket{
        assigns: Map.put(%{user_id: nil}, :__changed__, %{}),
        private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}}
      }

      seeded = MeetingHooks.attach_guest(socket)

      assert seeded.assigns.in_meeting == false
      assert seeded.assigns.mic_enabled == true
      assert seeded.assigns.camera_enabled == true
      assert seeded.assigns.screen_share_enabled == false
      assert seeded.assigns.meeting_counts == %{}
      assert seeded.assigns.meeting_participants == []
      # And confirm the hook actually landed on the `:meeting_events` slot.
      assert [_hook] = seeded.private.lifecycle.handle_event
    end
  end
end
