defmodule Platform.Chat.SpaceAccessTest do
  @moduledoc """
  Unit coverage for `Platform.Chat.SpaceAccess.authorize_writer/2` (task
  01a01ce0, stage 1).

  The adversarial half of this work lives in
  `test/security/chat_space_write_authorization_test.exs`, which drives the
  real LiveView transport with forged params. This file pins the predicate's
  own contract: which actor shapes resolve, which deny, and that the denials
  are denials rather than raises.

  The shape-rejection tests matter more than they look. An authorization
  predicate that raises on a malformed id is a 500 on a request path, and one
  that falls through an unrecognised shape to a permissive default is a
  bypass. Both failure modes are asserted here rather than assumed.
  """

  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Chat.SpaceAccess
  alias Platform.Repo

  # 16 characters. The discriminating shape for this class: `Ecto.UUID.cast/1`
  # hex-encodes a raw 16-byte binary and returns `{:ok, _}`, so a bare cast
  # would let this through to raise against the strict UUIDv7 key.
  # `Platform.UUID.valid?/1` is what rejects it.
  @slug_16 "space-slug-16chr"

  defp space! do
    slug = "space-access-#{System.unique_integer([:positive, :monotonic])}"
    {:ok, space} = Chat.create_space(%{name: "Space Access", slug: slug, kind: "channel"})
    space
  end

  defp join_user!(space_id, user_id) do
    {:ok, participant} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user_id,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp agent! do
    n = System.unique_integer([:positive, :monotonic])
    Repo.insert!(%Agent{slug: "space-access-agent-#{n}", name: "Agent #{n}", status: "active"})
  end

  describe "user principals" do
    test "a member resolves to their participant row" do
      space = space!()
      user_id = Ecto.UUID.generate()
      participant = join_user!(space.id, user_id)

      assert {:ok, %Participant{} = resolved} =
               SpaceAccess.authorize_writer(space.id, {:user, user_id})

      assert resolved.id == participant.id
      assert resolved.space_id == space.id
      assert resolved.participant_type == "user"
    end

    test "a non-member is forbidden" do
      space = space!()
      member_id = Ecto.UUID.generate()
      _member = join_user!(space.id, member_id)

      # Positive control in the same test: the space DOES grant somebody, so
      # the refusal below is the predicate discriminating rather than an empty
      # participants table answering for it.
      assert {:ok, _} = SpaceAccess.authorize_writer(space.id, {:user, member_id})

      assert {:error, :forbidden} =
               SpaceAccess.authorize_writer(space.id, {:user, Ecto.UUID.generate()})
    end

    test "membership of one space does not carry into another" do
      home = space!()
      target = space!()
      user_id = Ecto.UUID.generate()
      _ = join_user!(home.id, user_id)

      assert {:ok, _} = SpaceAccess.authorize_writer(home.id, {:user, user_id})
      assert {:error, :forbidden} = SpaceAccess.authorize_writer(target.id, {:user, user_id})
    end

    test "a bare %{id: user_id} map answers identically to {:user, user_id}" do
      space = space!()
      user_id = Ecto.UUID.generate()
      participant = join_user!(space.id, user_id)

      assert {:ok, from_tuple} = SpaceAccess.authorize_writer(space.id, {:user, user_id})
      assert {:ok, from_map} = SpaceAccess.authorize_writer(space.id, %{id: user_id})
      assert from_tuple.id == from_map.id
      assert from_map.id == participant.id

      # And the map shape denies where the tuple denies, so the shorthand is
      # not a second, looser door.
      assert {:error, :forbidden} =
               SpaceAccess.authorize_writer(space.id, %{id: Ecto.UUID.generate()})
    end
  end

  describe "agent principals" do
    test "an agent participant resolves to its participant row" do
      space = space!()
      agent = agent!()
      {:ok, participant} = Chat.add_agent_participant(space.id, agent)

      assert {:ok, %Participant{} = resolved} =
               SpaceAccess.authorize_writer(space.id, {:agent, agent.id})

      assert resolved.id == participant.id
      assert resolved.participant_type == "agent"
    end

    test "an agent that is not a participant is forbidden" do
      space = space!()
      present = agent!()
      absent = agent!()
      {:ok, _} = Chat.add_agent_participant(space.id, present)

      assert {:ok, _} = SpaceAccess.authorize_writer(space.id, {:agent, present.id})
      assert {:error, :forbidden} = SpaceAccess.authorize_writer(space.id, {:agent, absent.id})
    end

    test "a user-typed row does not satisfy an {:agent, id} actor, or the reverse" do
      # `participant_type` is part of the lookup, so an id that happens to
      # appear in the space under the other type is not a match. Without this
      # the two principal taxonomies would share one namespace.
      space = space!()
      shared_id = Ecto.UUID.generate()
      _ = join_user!(space.id, shared_id)

      assert {:ok, _} = SpaceAccess.authorize_writer(space.id, {:user, shared_id})
      assert {:error, :forbidden} = SpaceAccess.authorize_writer(space.id, {:agent, shared_id})
    end
  end

  describe "shapes that must deny rather than bypass or raise" do
    test "a nil actor is forbidden" do
      space = space!()
      _ = join_user!(space.id, Ecto.UUID.generate())

      assert {:error, :forbidden} = SpaceAccess.authorize_writer(space.id, nil)
    end

    test "unrecognised actor shapes are forbidden, and :system is one of them" do
      space = space!()
      member_id = Ecto.UUID.generate()
      _ = join_user!(space.id, member_id)

      # Control: this space grants somebody, so a blanket-deny implementation
      # could not produce this row.
      assert {:ok, _} = SpaceAccess.authorize_writer(space.id, {:user, member_id})

      for actor <- [
            # `:system` is CanvasAccess's opt-out and is deliberately absent
            # here: `chat_pins.pinned_by` is a `chat_participants.id` under
            # `validate_required`, so a system grant has no row to attribute to.
            :system,
            {:system, member_id},
            {:service, member_id},
            {:user, nil},
            {:agent, nil},
            {:user, 42},
            %{},
            %{id: nil},
            %{user_id: member_id},
            member_id,
            :admin,
            [user: member_id]
          ] do
        assert {:error, :forbidden} = SpaceAccess.authorize_writer(space.id, actor),
               "actor #{inspect(actor)} must DENY, not resolve"
      end
    end

    test "a non-UUID space_id is forbidden and does not raise" do
      user_id = Ecto.UUID.generate()

      assert {:error, :forbidden} = SpaceAccess.authorize_writer(@slug_16, {:user, user_id})
      assert {:error, :forbidden} = SpaceAccess.authorize_writer("not-a-uuid", {:user, user_id})
      assert {:error, :forbidden} = SpaceAccess.authorize_writer("", {:user, user_id})
      assert {:error, :forbidden} = SpaceAccess.authorize_writer(nil, {:user, user_id})
    end

    test "a non-UUID principal id is forbidden and does not raise" do
      space = space!()

      assert {:error, :forbidden} = SpaceAccess.authorize_writer(space.id, {:user, @slug_16})
      assert {:error, :forbidden} = SpaceAccess.authorize_writer(space.id, {:agent, "higgins"})
      assert {:error, :forbidden} = SpaceAccess.authorize_writer(space.id, %{id: @slug_16})
    end
  end
end
