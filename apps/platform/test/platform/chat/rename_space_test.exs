defmodule Platform.Chat.RenameSpaceTest do
  @moduledoc """
  `Platform.Chat.rename_space/3` (task 01a19948 stage 2): a participant, user
  or agent, renames a channel; the slug is re-derived and the rename is
  broadcast so open views update without a reload.
  """
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures, only: [acme_org_id: 0]

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Chat.Space
  alias Platform.Repo

  defp unique, do: System.unique_integer([:positive])

  defp user! do
    n = unique()

    Repo.insert!(%User{
      email: "rename-#{n}@example.com",
      name: "Rename #{n}",
      oidc_sub: "oidc-rename-#{n}"
    })
  end

  defp agent! do
    n = unique()

    Repo.insert!(%Agent{
      slug: "rename-agent-#{n}",
      name: "Rename Agent #{n}",
      status: "active",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    })
  end

  # A channel in the acme org whose creator is seated as its admin.
  defp channel!(creator, name \\ "Plan this week's work") do
    {:ok, space} =
      Chat.create_channel(%{
        name: name,
        slug: "rename-#{unique()}",
        org_id: acme_org_id(),
        created_by: creator.id
      })

    space
  end

  describe "a participant renames a channel" do
    test "a user participant renames it: name and slug change and the rename is broadcast" do
      user = user!()
      space = channel!(user)
      :ok = ChatPubSub.subscribe(space.id)

      assert {:ok, %Space{} = renamed} =
               Chat.rename_space({:user, user.id}, space.id, "  Weekly planning  ")

      assert renamed.name == "Weekly planning"
      assert renamed.slug == "weekly-planning"

      stored = Repo.get!(Space, space.id)
      assert {stored.name, stored.slug} == {"Weekly planning", "weekly-planning"}

      space_id = space.id
      assert_receive {:space_renamed, %Space{id: ^space_id, name: "Weekly planning"}}, 1_000
    end

    test "the rename is broadcast on the space-lifecycle topic too" do
      user = user!()
      space = channel!(user)
      :ok = ChatPubSub.subscribe_spaces()

      assert {:ok, _} = Chat.rename_space({:user, user.id}, space.id, "Launch prep")

      space_id = space.id
      assert_receive {:space_renamed, %Space{id: ^space_id, name: "Launch prep"}}, 1_000
    end

    test "an agent participant renames it" do
      user = user!()
      agent = agent!()
      space = channel!(user)
      {:ok, _} = Chat.add_agent_participant(space.id, agent.id)

      assert {:ok, renamed} = Chat.rename_space({:agent, agent.id}, space.id, "Spring launch")
      assert renamed.name == "Spring launch"
      assert renamed.slug == "spring-launch"
    end
  end

  describe "refusals change nothing" do
    test "a non-participant agent is :forbidden" do
      space = channel!(user!())
      outsider = agent!()

      assert {:error, :forbidden} = Chat.rename_space({:agent, outsider.id}, space.id, "Taken")
      assert Repo.get!(Space, space.id).name == space.name
    end

    test "a non-participant user is :forbidden" do
      space = channel!(user!())
      outsider = user!()

      assert {:error, :forbidden} = Chat.rename_space({:user, outsider.id}, space.id, "Taken")
      assert Repo.get!(Space, space.id).name == space.name
    end

    test "an unknown space and a malformed id are :forbidden" do
      user = user!()

      assert {:error, :forbidden} = Chat.rename_space({:user, user.id}, Ecto.UUID.generate(), "X")
      assert {:error, :forbidden} = Chat.rename_space({:user, user.id}, "not-a-uuid", "X")
    end

    test "a dm is :not_applicable" do
      user = user!()
      other = user!()
      {:ok, dm} = Chat.find_or_create_dm(user.id, "user", other.id)

      assert {:error, :not_applicable} = Chat.rename_space({:user, user.id}, dm.id, "Renamed")
      assert Repo.get!(Space, dm.id).name == dm.name
    end

    test "a group is :not_applicable" do
      user = user!()
      a = user!()
      b = user!()

      {:ok, group} =
        Chat.create_group_conversation(user.id, [
          %{type: "user", id: a.id},
          %{type: "user", id: b.id}
        ])

      assert group.kind == "group"
      assert {:error, :not_applicable} = Chat.rename_space({:user, user.id}, group.id, "Renamed")
      assert Repo.get!(Space, group.id).name == group.name
    end

    test "an archived channel is refused" do
      user = user!()
      space = channel!(user)
      {:ok, _} = Chat.archive_space(space)

      assert {:error, :space_archived} = Chat.rename_space({:user, user.id}, space.id, "Renamed")
      assert Repo.get!(Space, space.id).name == space.name
    end

    test "a blank name and an 81-character name are refused" do
      user = user!()
      space = channel!(user)

      assert {:error, %Ecto.Changeset{} = blank} =
               Chat.rename_space({:user, user.id}, space.id, "   ")

      assert blank.errors[:name]

      assert {:error, %Ecto.Changeset{} = long} =
               Chat.rename_space({:user, user.id}, space.id, String.duplicate("a", 81))

      assert long.errors[:name]
      assert {:error, %Ecto.Changeset{}} = Chat.rename_space({:user, user.id}, space.id, nil)

      assert Repo.get!(Space, space.id).name == space.name

      # 80 characters is allowed.
      assert {:ok, _} = Chat.rename_space({:user, user.id}, space.id, String.duplicate("a", 80))
    end
  end

  describe "slug" do
    test "a slug collision in the org gets a 6-hex suffix" do
      user = user!()

      {:ok, _taken} =
        Chat.create_channel(%{name: "Launch", slug: "launch", org_id: acme_org_id()})

      space = channel!(user)

      assert {:ok, renamed} = Chat.rename_space({:user, user.id}, space.id, "Launch")
      assert renamed.name == "Launch"
      assert renamed.slug =~ ~r/\Alaunch-[0-9a-f]{6}\z/
    end

    test "a name with no ASCII letter or digit still gets a slug" do
      user = user!()
      space = channel!(user)

      assert {:ok, renamed} = Chat.rename_space({:user, user.id}, space.id, "\u{1F680}")
      assert renamed.slug =~ ~r/\Achannel-[0-9a-f]{6}\z/
    end

    test "a slug that would start with a reserved prefix is prefixed" do
      user = user!()
      space = channel!(user)

      assert {:ok, renamed} = Chat.rename_space({:user, user.id}, space.id, "DM etiquette")
      refute Chat.reserved_slug_prefix?(renamed.slug)
      assert renamed.slug == "channel-dm-etiquette"
    end
  end
end
