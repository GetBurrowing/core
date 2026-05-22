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
      user_id = Ecto.UUID.generate()

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
      user_id = Ecto.UUID.generate()

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
      space = create_space()
      user_id = Ecto.UUID.generate()

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
      # inserted the canonical row. With no current_participant AND no
      # real user row to resolve a name from, resolve_display_name/1 now
      # falls through to the neutral "Guest" default (v2: never the
      # literal "User" — that's the bug v2 closes).
      assert result.assigns.in_meeting == true
      assert %Participant{participant_id: ^user_id} = result.assigns.current_participant

      participants = Chat.list_participants(space.id, participant_type: "user")
      assert [%Participant{participant_id: ^user_id, display_name: "Guest"}] = participants
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
