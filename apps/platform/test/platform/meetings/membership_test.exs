defmodule Platform.Meetings.MembershipTest do
  @moduledoc """
  Unit tests for `Platform.Meetings.Membership` — the canonical hook
  for adding a user to the chat space bound to a meeting.

  These tests pin the idempotency contract: two calls for the same
  `(space_id, user_id)` produce a single row, and BOTH calls return
  `{:ok, %Participant{}}`. That contract is what lets
  `MeetingHooks.do_join/1` call the helper unconditionally on every
  join lifecycle without leaking duplicate rows.
  """

  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Meetings.Membership

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp create_space do
    {:ok, space} =
      Chat.create_space(%{
        name: "Membership Test Space",
        slug: "membership-test-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  # ── ensure_chat_space_participant/3 ───────────────────────────────────────

  describe "ensure_chat_space_participant/3" do
    test "inserts a participant row on first call and returns {:ok, %Participant{}}" do
      space = create_space()
      user_id = Ecto.UUID.generate()

      assert {:ok, %Participant{} = p} =
               Membership.ensure_chat_space_participant(space.id, user_id, "Ada")

      assert p.space_id == space.id
      assert p.participant_type == "user"
      assert p.participant_id == user_id
      assert p.display_name == "Ada"
      assert [^p] = Chat.list_participants(space.id, participant_type: "user")
    end

    test "is idempotent: two calls produce one row" do
      space = create_space()
      user_id = Ecto.UUID.generate()

      assert {:ok, %Participant{} = first} =
               Membership.ensure_chat_space_participant(space.id, user_id, "Ada")

      assert {:ok, %Participant{} = second} =
               Membership.ensure_chat_space_participant(space.id, user_id, "Ada")

      assert first.id == second.id

      participants = Chat.list_participants(space.id, participant_type: "user")
      assert length(participants) == 1
      assert hd(participants).id == first.id
    end

    test "returns {:ok, %Participant{}} on duplicate calls (matches first-call shape)" do
      space = create_space()
      user_id = Ecto.UUID.generate()

      {:ok, _} = Membership.ensure_chat_space_participant(space.id, user_id, "Ada")

      # Second call's result must be the same shape — never {:error, _} —
      # so callers (MeetingHooks.do_join/1) don't have to special-case
      # the duplicate path.
      result = Membership.ensure_chat_space_participant(space.id, user_id, "Ada")
      assert {:ok, %Participant{}} = result
    end

    test "falls back to \"User\" when display_name is nil" do
      space = create_space()
      user_id = Ecto.UUID.generate()

      assert {:ok, %Participant{display_name: "User"}} =
               Membership.ensure_chat_space_participant(space.id, user_id, nil)
    end

    test "different user_ids in the same space produce distinct rows" do
      space = create_space()
      user_a = Ecto.UUID.generate()
      user_b = Ecto.UUID.generate()

      {:ok, pa} = Membership.ensure_chat_space_participant(space.id, user_a, "Ada")
      {:ok, pb} = Membership.ensure_chat_space_participant(space.id, user_b, "Bob")

      assert pa.id != pb.id

      ids =
        space.id
        |> Chat.list_participants(participant_type: "user")
        |> Enum.map(& &1.participant_id)
        |> Enum.sort()

      assert Enum.sort([user_a, user_b]) == ids
    end
  end
end
