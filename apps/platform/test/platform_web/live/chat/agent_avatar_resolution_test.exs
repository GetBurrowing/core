defmodule PlatformWeb.ChatLive.AgentAvatarResolutionTest do
  @moduledoc """
  Task 01a00122 stage 4 — an agent's avatar reaches the CHAT participant
  view-model.

  The bug this pins: `PresenceHooks.participant_identity/3`'s agent clause used
  to read `participant.avatar_url`, i.e. the `chat_participants.avatar_url`
  column — but `Chat.do_add_agent_participant/3` inserts only
  `participant_type`, `participant_id`, `display_name`, `attention_mode` and
  `joined_at`, and NOTHING anywhere writes that column for an agent row. So the
  value was structurally guaranteed to be `nil` for every agent in every space,
  and `sender_avatar_url/2` could never return an agent's face.

  The fix resolves from the `agents` table via
  `Chat.agent_avatar_map_for_participants/1` and threads the result in, exactly
  the way `agent_color_map_for_participants/1` already resolves `agent.color`.
  The participant column is deliberately NOT backfilled — see the
  "denormalisation" test below, which is the guard on that decision.
  """

  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Repo
  alias PlatformWeb.ChatLive.PresenceHooks

  # ── Builders ─────────────────────────────────────────────────────────────

  defp space!(attrs \\ %{}) do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, space} =
      Chat.create_space(
        Map.merge(%{name: "Avatar Test #{n}", slug: "avatar-test-#{n}", kind: "channel"}, attrs)
      )

    space
  end

  defp agent!(attrs) do
    n = System.unique_integer([:positive, :monotonic])

    defaults = %{
      slug: "avatar-agent-#{n}",
      name: "Avatar Agent #{n}",
      status: "active",
      max_concurrent: 1,
      sandbox_mode: "off",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    }

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    agent
  end

  # The identity map keyed the way every render region reads it.
  defp identity_map(space) do
    participants = Chat.list_participants(space.id)
    avatars = Chat.agent_avatar_map_for_participants(participants)
    PresenceHooks.build_participant_identity_map(participants, %{}, avatars)
  end

  # ── The seam itself ──────────────────────────────────────────────────────

  describe "Chat.agent_avatar_map_for_participants/1" do
    test "resolves an agent's avatar_url from the agents table, keyed by participant.id" do
      space = space!()
      agent = agent!(%{avatar_url: "/agents/abc/avatar?v=GKHEI"})
      {:ok, participant} = Chat.add_agent_participant(space.id, agent)

      map = Chat.agent_avatar_map_for_participants(Chat.list_participants(space.id))

      assert Map.get(map, participant.id) == "/agents/abc/avatar?v=GKHEI"
    end

    test "the ?v= cache token is passed through verbatim — never stripped or parsed" do
      # The serving route does not change when the bytes do, so the query
      # string IS the cache-busting mechanism. Dropping it would pin every
      # viewer to a stale image forever.
      space = space!()
      url = "/agents/de305d54/avatar?v=aB3-_x9"
      agent = agent!(%{avatar_url: url})
      {:ok, participant} = Chat.add_agent_participant(space.id, agent)

      map = Chat.agent_avatar_map_for_participants(Chat.list_participants(space.id))

      assert Map.get(map, participant.id) == url
    end

    test "an agent with no avatar is ABSENT, so Map.get yields nil (never an empty string)" do
      space = space!()
      agent = agent!(%{avatar_url: nil})
      {:ok, participant} = Chat.add_agent_participant(space.id, agent)

      map = Chat.agent_avatar_map_for_participants(Chat.list_participants(space.id))

      refute Map.has_key?(map, participant.id)
      assert Map.get(map, participant.id) == nil
    end

    test "a blank avatar_url is normalised out rather than passed on as junk" do
      space = space!()
      agent = agent!(%{avatar_url: "   "})
      {:ok, participant} = Chat.add_agent_participant(space.id, agent)

      map = Chat.agent_avatar_map_for_participants(Chat.list_participants(space.id))

      assert Map.get(map, participant.id) == nil
    end

    test "no agent participants means no query result to key on" do
      assert Chat.agent_avatar_map_for_participants([]) == %{}
    end

    test "several agents in one space each resolve to their OWN avatar" do
      space = space!()
      a1 = agent!(%{avatar_url: "/agents/one/avatar?v=AAA"})
      a2 = agent!(%{avatar_url: "/agents/two/avatar?v=BBB"})
      a3 = agent!(%{avatar_url: nil})

      {:ok, p1} = Chat.add_agent_participant(space.id, a1)
      {:ok, p2} = Chat.add_agent_participant(space.id, a2)
      {:ok, p3} = Chat.add_agent_participant(space.id, a3)

      map = Chat.agent_avatar_map_for_participants(Chat.list_participants(space.id))

      assert Map.get(map, p1.id) == "/agents/one/avatar?v=AAA"
      assert Map.get(map, p2.id) == "/agents/two/avatar?v=BBB"
      assert Map.get(map, p3.id) == nil
    end
  end

  # ── End-to-end through the view-model the templates actually read ────────

  describe "agent avatar through participant_identity/3 and sender_avatar_url/2" do
    test "an agent WITH an avatar resolves to that URL" do
      space = space!()
      agent = agent!(%{avatar_url: "/agents/xyz/avatar?v=Q7T2"})
      {:ok, participant} = Chat.add_agent_participant(space.id, agent)

      map = identity_map(space)

      assert %{participant_type: "agent", avatar_url: "/agents/xyz/avatar?v=Q7T2"} =
               Map.fetch!(map, participant.id)

      # The accessor the message row calls (chat_message.ex:111).
      assert PresenceHooks.sender_avatar_url(map, participant.id) ==
               "/agents/xyz/avatar?v=Q7T2"
    end

    test "an agent WITHOUT an avatar resolves to nil, not an empty string" do
      space = space!()
      agent = agent!(%{avatar_url: nil})
      {:ok, participant} = Chat.add_agent_participant(space.id, agent)

      map = identity_map(space)
      identity = Map.fetch!(map, participant.id)

      assert identity.participant_type == "agent"

      assert identity.avatar_url == nil,
             "expected nil so agent_avatar/1 falls back to the initial glyph, got: " <>
               inspect(identity.avatar_url)

      refute identity.avatar_url == ""

      assert PresenceHooks.sender_avatar_url(map, participant.id) == nil
    end

    test "the agent's name and seed are untouched by the avatar seam" do
      space = space!()
      agent = agent!(%{name: "Helper Bot", avatar_url: "/agents/hb/avatar?v=Z1"})
      {:ok, participant} = Chat.add_agent_participant(space.id, agent)

      identity = Map.fetch!(identity_map(space), participant.id)

      assert identity.name == "Helper Bot"
      assert identity.display_name == "Helper Bot"
      assert identity.principal_id == agent.id
      assert identity.avatar_seed == agent.id
      assert identity.archived == false
    end
  end

  # ── The decision this stage made, pinned ─────────────────────────────────

  describe "chat_participants.avatar_url is NOT denormalised for agents" do
    test "adding an agent participant leaves the participant column nil" do
      # Backfilling would copy a mutable field onto every participant row in
      # every space, so changing an agent's avatar would mean rewriting all of
      # them. If this ever fails, someone has reintroduced that coupling.
      space = space!()
      agent = agent!(%{avatar_url: "/agents/nd/avatar?v=K9"})
      {:ok, participant} = Chat.add_agent_participant(space.id, agent)

      row = Repo.get!(Participant, participant.id)
      assert row.avatar_url == nil

      # ...and the view-model still shows the face, sourced from the agent.
      assert Map.fetch!(identity_map(space), participant.id).avatar_url ==
               "/agents/nd/avatar?v=K9"
    end

    test "changing the agent's avatar changes what a fresh rebuild resolves" do
      space = space!()
      agent = agent!(%{avatar_url: "/agents/mv/avatar?v=OLD"})
      {:ok, participant} = Chat.add_agent_participant(space.id, agent)

      assert Map.fetch!(identity_map(space), participant.id).avatar_url ==
               "/agents/mv/avatar?v=OLD"

      {:ok, _} =
        agent
        |> Agent.changeset(%{avatar_url: "/agents/mv/avatar?v=NEW"})
        |> Repo.update()

      # No participant row was touched — the next presence rebuild simply reads
      # the new value. (Already-connected sessions keep the old snapshot until
      # that rebuild; see the CACHING note on build_participant_identity_map/3.)
      assert Repo.get!(Participant, participant.id).avatar_url == nil

      assert Map.fetch!(identity_map(space), participant.id).avatar_url ==
               "/agents/mv/avatar?v=NEW"
    end
  end

  # ── Humans must be untouched ─────────────────────────────────────────────

  describe "human avatar resolution is unchanged" do
    test "a user's avatar still comes off the participant row, then the user" do
      from_participant = %Participant{
        id: "p-1",
        participant_type: "user",
        participant_id: "u-1",
        display_name: "Ada",
        avatar_url: "/uploads/from-participant.png"
      }

      assert %{participant_type: "user", avatar_url: "/uploads/from-participant.png"} =
               PresenceHooks.participant_identity(from_participant, %User{
                 id: "u-1",
                 name: "Ada",
                 avatar_url: "/uploads/from-user.png"
               })

      from_user = %Participant{
        id: "p-2",
        participant_type: "user",
        participant_id: "u-2",
        display_name: "Grace",
        avatar_url: nil
      }

      assert %{avatar_url: "/uploads/from-user.png"} =
               PresenceHooks.participant_identity(from_user, %User{
                 id: "u-2",
                 name: "Grace",
                 avatar_url: "/uploads/from-user.png"
               })
    end

    test "a user with no avatar anywhere is still nil" do
      p = %Participant{
        id: "p-3",
        participant_type: "user",
        participant_id: "u-3",
        display_name: "Nobody",
        avatar_url: nil
      }

      assert %{avatar_url: nil} =
               PresenceHooks.participant_identity(p, %User{id: "u-3", name: "Nobody"})
    end

    test "the agent avatar map cannot leak onto a human, even on an id collision" do
      # Agent avatars are keyed by participant.id. A human participant sharing
      # that key must NOT pick the entry up — only the agent clause reads it.
      p = %Participant{
        id: "shared-id",
        participant_type: "user",
        participant_id: "u-4",
        display_name: "Human",
        avatar_url: nil
      }

      identity =
        PresenceHooks.participant_identity(
          p,
          %User{id: "u-4", name: "Human", avatar_url: nil},
          %{"shared-id" => "/agents/leak/avatar?v=NOPE"}
        )

      assert identity.participant_type == "user"
      assert identity.avatar_url == nil
    end
  end
end
