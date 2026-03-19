defmodule Platform.Chat.ConversationTest do
  @moduledoc """
  Tests for conversation management: DMs, groups, channels, and promotion.
  """

  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Repo

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp create_user(attrs \\ %{}) do
    default = %{
      email: "user-#{System.unique_integer([:positive])}@test.com",
      name: "User #{System.unique_integer([:positive])}",
      oidc_sub: "oidc-#{System.unique_integer([:positive])}"
    }

    {:ok, user} =
      %User{}
      |> User.changeset(Map.merge(default, attrs))
      |> Repo.insert()

    user
  end

  defp create_agent(attrs \\ %{}) do
    default = %{
      slug: "agent-#{System.unique_integer([:positive])}",
      name: "Agent #{System.unique_integer([:positive])}",
      status: "active"
    }

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(Map.merge(default, attrs))
      |> Repo.insert()

    agent
  end

  defp unique_slug, do: "test-#{System.unique_integer([:positive])}"

  # ── find_or_create_dm ──────────────────────────────────────────────────────

  describe "find_or_create_dm/4" do
    test "creates a new DM space between two users" do
      user1 = create_user()
      user2 = create_user()

      assert {:ok, space} = Chat.find_or_create_dm(user1.id, "user", user2.id)
      assert space.kind == "dm"
      assert space.is_direct == true
      assert space.created_by == user1.id
      assert is_nil(space.slug)
      assert is_nil(space.name)

      participants = Chat.list_participants(space.id)
      participant_ids = Enum.map(participants, & &1.participant_id) |> Enum.sort()
      assert participant_ids == Enum.sort([user1.id, user2.id])
    end

    test "returns existing DM on second call" do
      user1 = create_user()
      user2 = create_user()

      assert {:ok, space1} = Chat.find_or_create_dm(user1.id, "user", user2.id)
      assert {:ok, space2} = Chat.find_or_create_dm(user1.id, "user", user2.id)
      assert space1.id == space2.id
    end

    test "works for user-agent DMs" do
      user = create_user()
      agent = create_agent()

      assert {:ok, space} = Chat.find_or_create_dm(user.id, "agent", agent.id)
      assert space.kind == "dm"
      assert space.is_direct == true

      participants = Chat.list_participants(space.id)
      types = Enum.map(participants, & &1.participant_type) |> Enum.sort()
      assert types == ["agent", "user"]
    end
  end

  # ── create_group_conversation ──────────────────────────────────────────────

  describe "create_group_conversation/3" do
    test "creates group with 3+ members" do
      user1 = create_user()
      user2 = create_user()
      user3 = create_user()

      specs = [
        %{type: "user", id: user2.id},
        %{type: "user", id: user3.id}
      ]

      assert {:ok, space} = Chat.create_group_conversation(user1.id, specs)
      assert space.kind == "group"
      assert space.is_direct == false

      participants = Chat.list_participants(space.id)
      assert length(participants) == 3
    end

    test "redirects to DM for 2 members" do
      user1 = create_user()
      user2 = create_user()

      specs = [%{type: "user", id: user2.id}]

      assert {:ok, space} = Chat.create_group_conversation(user1.id, specs)
      assert space.kind == "dm"
      assert space.is_direct == true
    end
  end

  # ── promote_to_channel ─────────────────────────────────────────────────────

  describe "promote_to_channel/2" do
    test "works for group spaces" do
      user1 = create_user()
      user2 = create_user()
      user3 = create_user()

      specs = [
        %{type: "user", id: user2.id},
        %{type: "user", id: user3.id}
      ]

      {:ok, space} = Chat.create_group_conversation(user1.id, specs)
      slug = unique_slug()

      assert {:ok, updated} = Chat.promote_to_channel(space, %{name: "Team Chat", slug: slug})
      assert updated.kind == "channel"
      assert updated.name == "Team Chat"
      assert updated.slug == slug
    end

    test "fails for DM spaces (is_direct=true)" do
      user1 = create_user()
      user2 = create_user()

      {:ok, space} = Chat.find_or_create_dm(user1.id, "user", user2.id)

      assert {:error, :not_promotable} =
               Chat.promote_to_channel(space, %{name: "Test", slug: unique_slug()})
    end

    test "fails for channel spaces" do
      {:ok, space} = Chat.create_channel(%{name: "Test", slug: unique_slug(), kind: "channel"})

      assert {:error, :not_promotable} =
               Chat.promote_to_channel(space, %{name: "New", slug: unique_slug()})
    end
  end

  # ── create_channel ─────────────────────────────────────────────────────────

  describe "create_channel/1" do
    test "requires name and slug, enforces kind=channel" do
      slug = unique_slug()
      assert {:ok, space} = Chat.create_channel(%{name: "Dev", slug: slug})
      assert space.kind == "channel"
      assert space.name == "Dev"
      assert space.slug == slug
    end

    test "fails without name" do
      assert {:error, %Ecto.Changeset{}} = Chat.create_channel(%{slug: unique_slug()})
    end

    test "fails without slug" do
      assert {:error, %Ecto.Changeset{}} = Chat.create_channel(%{name: "Test"})
    end
  end

  # ── list_user_conversations ────────────────────────────────────────────────

  describe "list_user_conversations/1" do
    test "returns only spaces where user is an active participant" do
      user1 = create_user()
      user2 = create_user()
      user3 = create_user()

      {:ok, dm_space} = Chat.find_or_create_dm(user1.id, "user", user2.id)
      {:ok, _other_dm} = Chat.find_or_create_dm(user2.id, "user", user3.id)

      conversations = Chat.list_user_conversations(user1.id)
      conversation_ids = Enum.map(conversations, & &1.id)

      assert dm_space.id in conversation_ids
    end
  end

  # ── display_name_for_space ─────────────────────────────────────────────────

  describe "display_name_for_space/3" do
    test "shows space name for channels" do
      {:ok, space} = Chat.create_channel(%{name: "General", slug: unique_slug()})
      assert Chat.display_name_for_space(space, [], "any-id") == "General"
    end

    test "shows other person for DMs" do
      user1 = create_user(%{name: "Alice"})
      user2 = create_user(%{name: "Bob"})

      {:ok, space} = Chat.find_or_create_dm(user1.id, "user", user2.id)
      participants = Chat.list_participants(space.id)

      assert Chat.display_name_for_space(space, participants, user1.id) == "Bob"
      assert Chat.display_name_for_space(space, participants, user2.id) == "Alice"
    end

    test "shows comma-separated names for groups" do
      user1 = create_user(%{name: "Alice"})
      user2 = create_user(%{name: "Bob"})
      user3 = create_user(%{name: "Charlie"})

      specs = [
        %{type: "user", id: user2.id},
        %{type: "user", id: user3.id}
      ]

      {:ok, space} = Chat.create_group_conversation(user1.id, specs)
      participants = Chat.list_participants(space.id)

      name = Chat.display_name_for_space(space, participants, user1.id)
      assert String.contains?(name, "Bob")
      assert String.contains?(name, "Charlie")
    end
  end
end
