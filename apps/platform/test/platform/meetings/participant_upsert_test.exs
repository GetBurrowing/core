defmodule Platform.Meetings.ParticipantUpsertTest do
  @moduledoc """
  Data-layer tests for the live-join WRITE path added in v2 of task
  019e4b3e: `parse_identity/1`, `upsert_live_participant/2`, and
  `mark_live_participant_left/2`.

  These are the regression net for the gap v1 never exercised — v1's e2e
  SEEDED participant rows, so it never proved that a real join produces a
  row with a resolvable `user_id`/`agent_id` FK. These tests assert at the
  DATA layer: the upsert must carry the parsed FK so the render path can
  resolve the real name instead of the literal "User".
  """

  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Participant
  alias Platform.Repo

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp create_room do
    {:ok, space} =
      Chat.create_space(%{
        name: "Upsert Test Space",
        slug: "upsert-test-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, room} = Meetings.ensure_room(space.id)
    room
  end

  defp create_user(name \\ "Ada Lovelace") do
    n = System.unique_integer([:positive])

    {:ok, user} =
      %User{}
      |> User.changeset(%{
        name: name,
        email: "user-#{n}@example.com",
        oidc_sub: "sub-#{n}"
      })
      |> Repo.insert()

    user
  end

  defp create_agent do
    n = System.unique_integer([:positive])

    {:ok, agent} =
      %Platform.Agents.Agent{}
      |> Platform.Agents.Agent.changeset(%{
        slug: "summarizer-#{n}",
        name: "Summarizer",
        status: "active"
      })
      |> Repo.insert()

    agent
  end

  # ── parse_identity/1 ─────────────────────────────────────────────────────

  describe "parse_identity/1" do
    test "parses a user identity" do
      uuid = Ecto.UUID.generate()
      assert {:user, ^uuid} = Meetings.parse_identity("user:#{uuid}")
    end

    test "parses an agent identity" do
      uuid = Ecto.UUID.generate()
      assert {:agent, ^uuid} = Meetings.parse_identity("agent:#{uuid}")
    end

    test "returns :unknown for a non-uuid suffix" do
      assert :unknown = Meetings.parse_identity("user:not-a-uuid")
    end

    test "returns :unknown for an unprefixed string" do
      assert :unknown = Meetings.parse_identity(Ecto.UUID.generate())
    end

    test "returns :unknown for garbage and nil" do
      assert :unknown = Meetings.parse_identity("garbage")
      assert :unknown = Meetings.parse_identity(nil)
    end
  end

  # ── upsert_live_participant/2 ────────────────────────────────────────────

  describe "upsert_live_participant/2" do
    test "sets user_id from a user identity" do
      room = create_room()
      user = create_user()

      assert {:ok, p} =
               Meetings.upsert_live_participant(room, %{
                 identity: "user:#{user.id}",
                 name: "Ada Lovelace"
               })

      assert p.user_id == user.id
      assert is_nil(p.agent_id)
      assert p.display_name == "Ada Lovelace"
      assert is_nil(p.left_at)
    end

    test "sets agent_id from an agent identity" do
      room = create_room()
      agent = create_agent()

      assert {:ok, p} =
               Meetings.upsert_live_participant(room, %{
                 identity: "agent:#{agent.id}",
                 name: "Summarizer"
               })

      assert p.agent_id == agent.id
      assert is_nil(p.user_id)
      assert p.display_name == "Summarizer"
    end

    test "an unknown identity yields a nil-FK row carrying the name" do
      room = create_room()

      assert {:ok, p} =
               Meetings.upsert_live_participant(room, %{
                 identity: "sip:+15551234",
                 name: "Caller"
               })

      assert is_nil(p.user_id)
      assert is_nil(p.agent_id)
      assert p.display_name == "Caller"
    end

    test "a missing name falls back to \"User\"" do
      room = create_room()

      assert {:ok, p} =
               Meetings.upsert_live_participant(room, %{identity: "unknown", name: nil})

      assert p.display_name == "User"
    end

    test "is idempotent on a duplicate participant_joined for the same user identity" do
      room = create_room()
      user = create_user()
      attrs = %{identity: "user:#{user.id}", name: "Ada Lovelace"}

      assert {:ok, p1} = Meetings.upsert_live_participant(room, attrs)
      assert {:ok, p2} = Meetings.upsert_live_participant(room, attrs)

      assert p1.id == p2.id

      active =
        Repo.all(from(p in Participant, where: p.room_id == ^room.id and is_nil(p.left_at)))

      assert length(active) == 1
    end

    test "dedupes by user_id even when the LiveKit name differs on re-fire" do
      room = create_room()
      user = create_user()

      assert {:ok, p1} =
               Meetings.upsert_live_participant(room, %{
                 identity: "user:#{user.id}",
                 name: "Ada Lovelace"
               })

      # Reconnect re-fires with a slightly different name; still one row.
      assert {:ok, p2} =
               Meetings.upsert_live_participant(room, %{
                 identity: "user:#{user.id}",
                 name: "Ada L."
               })

      assert p1.id == p2.id
    end
  end

  # ── active_participant_for_user_in_space/2 ───────────────────────────────

  describe "active_participant_for_user_in_space/2" do
    test "returns the active participant row for a user in the active meeting" do
      room = create_room()
      {:ok, room} = Meetings.activate_room(room)
      user = create_user()

      {:ok, joined} =
        Meetings.upsert_live_participant(room, %{
          identity: "user:#{user.id}",
          name: "Ada Lovelace"
        })

      found = Meetings.active_participant_for_user_in_space(room.space_id, user.id)
      assert found.id == joined.id
      assert found.user_id == user.id
    end

    test "returns nil when the user has left the meeting" do
      room = create_room()
      {:ok, room} = Meetings.activate_room(room)
      user = create_user()

      {:ok, _} =
        Meetings.upsert_live_participant(room, %{
          identity: "user:#{user.id}",
          name: "Ada Lovelace"
        })

      {:ok, _} =
        Meetings.mark_live_participant_left(room, %{
          identity: "user:#{user.id}",
          name: "Ada Lovelace"
        })

      assert is_nil(Meetings.active_participant_for_user_in_space(room.space_id, user.id))
    end

    test "returns nil when no active room exists for the space" do
      room = create_room()
      user = create_user()

      # Room is idle (not activated) → get_active_room/1 returns nil.
      assert is_nil(Meetings.active_participant_for_user_in_space(room.space_id, user.id))
    end

    test "returns nil for a different user than the one in the meeting" do
      room = create_room()
      {:ok, room} = Meetings.activate_room(room)
      user = create_user()
      other = create_user("Grace Hopper")

      {:ok, _} =
        Meetings.upsert_live_participant(room, %{
          identity: "user:#{user.id}",
          name: "Ada Lovelace"
        })

      assert is_nil(Meetings.active_participant_for_user_in_space(room.space_id, other.id))
    end

    test "returns nil for non-binary args" do
      assert is_nil(Meetings.active_participant_for_user_in_space(nil, nil))
    end
  end

  # ── mark_live_participant_left/2 ─────────────────────────────────────────

  describe "mark_live_participant_left/2" do
    test "sets left_at matching by user_id even when the name differs" do
      room = create_room()
      user = create_user()

      {:ok, joined} =
        Meetings.upsert_live_participant(room, %{
          identity: "user:#{user.id}",
          name: "Ada Lovelace"
        })

      # LiveKit's leave payload may carry a different display name; match
      # must resolve by the FK, not the name.
      assert {:ok, left} =
               Meetings.mark_live_participant_left(room, %{
                 identity: "user:#{user.id}",
                 name: "Somebody Else"
               })

      assert left.id == joined.id
      refute is_nil(left.left_at)
    end

    test "returns :not_found when no active row matches" do
      room = create_room()

      assert {:error, :not_found} =
               Meetings.mark_live_participant_left(room, %{
                 identity: "user:#{Ecto.UUID.generate()}",
                 name: "Ghost"
               })
    end
  end
end
