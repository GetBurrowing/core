defmodule Platform.Chat.ChannelMembersAdminTest do
  @moduledoc """
  Task 01a0fd62-a7ef-7001-8477-bd17e47bbaca stage 3: `Chat.admin_add_agent/3`
  and `Chat.admin_remove_agent/3`, the context gate behind the channel members
  panel.

  Every refusal asserts the DB row count alongside the error tuple, so a
  version that returned the right error after writing anyway cannot pass.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Chat.ActiveAgentStore
  alias Platform.Chat.Participant
  alias Platform.Repo

  defp agent!(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    Repo.insert!(
      struct(
        %Platform.Agents.Agent{
          name: "Members Agent #{n}",
          slug: "members-agent-#{n}",
          status: "active"
        },
        attrs
      )
    )
  end

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: "Members User #{n}",
      email: "members-#{n}@example.com",
      oidc_sub: "sub-members-#{n}"
    })
  end

  defp channel! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{name: "Members #{n}", slug: "members-#{n}", kind: "channel"})

    space
  end

  defp user_participant!(space_id, user, role) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        role: role,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp agent_rows(space_id, agent_id) do
    Repo.all(
      from(p in Participant,
        where:
          p.space_id == ^space_id and p.participant_type == "agent" and
            p.participant_id == ^agent_id
      )
    )
  end

  describe "admin_add_agent/3" do
    test "an admin add writes an agent row with history_visible_from set" do
      space = channel!()
      admin = user!()
      user_participant!(space.id, admin, "admin")
      agent = agent!()

      assert {:ok, %Participant{} = p} = Chat.admin_add_agent(space, admin.id, agent.id)

      assert [row] = agent_rows(space.id, agent.id)
      assert row.id == p.id
      assert row.attention_mode == "mention"
      assert %DateTime{} = row.history_visible_from
    end

    test "a member add is unauthorized and writes no row" do
      space = channel!()
      member = user!()
      user_participant!(space.id, member, "member")
      agent = agent!()

      assert {:error, :unauthorized} = Chat.admin_add_agent(space, member.id, agent.id)
      assert agent_rows(space.id, agent.id) == []

      # Positive control on the same space and agent: an admin's add lands, so
      # the empty result above is the gate and not a broken fixture.
      admin = user!()
      user_participant!(space.id, admin, "admin")
      assert {:ok, _} = Chat.admin_add_agent(space, admin.id, agent.id)
      assert [_] = agent_rows(space.id, agent.id)
    end

    test "a nil actor is unauthorized" do
      space = channel!()
      agent = agent!()

      assert {:error, :unauthorized} = Chat.admin_add_agent(space, nil, agent.id)
      assert agent_rows(space.id, agent.id) == []
    end

    test "an archived agent is not summonable and writes no row" do
      space = channel!()
      admin = user!()
      user_participant!(space.id, admin, "admin")
      archived = agent!(%{status: "archived"})

      assert {:error, :not_found} = Chat.admin_add_agent(space, admin.id, archived.id)
      assert agent_rows(space.id, archived.id) == []
    end

    test "a malformed agent id is not_found rather than a cast error" do
      space = channel!()
      admin = user!()
      user_participant!(space.id, admin, "admin")

      assert {:error, :not_found} = Chat.admin_add_agent(space, admin.id, "not-a-uuid")
      assert {:error, :not_found} = Chat.admin_add_agent(space, admin.id, nil)
    end

    test "a DM is refused" do
      a = user!()
      b = user!()
      {:ok, dm} = Chat.find_or_create_dm(a.id, "user", b.id)
      agent = agent!()

      assert {:error, :dm} = Chat.admin_add_agent(dm, a.id, agent.id)
      assert agent_rows(dm.id, agent.id) == []
    end

    test "an execution space's sponsor is authorized, by the same predicate" do
      sponsor = user!()

      {:ok, project} =
        Platform.Tasks.create_project(%{name: "Members #{System.unique_integer([:positive])}"})

      {:ok, task} =
        Platform.Tasks.create_task(%{
          project_id: project.id,
          title: "Sponsored members",
          sponsor_user_id: sponsor.id
        })

      {:ok, exec} =
        Chat.create_space(%{kind: "execution", name: "exec", metadata: %{"task_id" => task.id}})

      user_participant!(exec.id, sponsor, "member")
      agent = agent!()

      assert Chat.can_summon_agents?(exec, sponsor.id)
      assert {:ok, _} = Chat.admin_add_agent(exec, sponsor.id, agent.id)
      assert [_] = agent_rows(exec.id, agent.id)

      # Positive control: a non-sponsor member of the same space is refused.
      other = user!()
      user_participant!(exec.id, other, "member")
      second = agent!()
      assert {:error, :unauthorized} = Chat.admin_add_agent(exec, other.id, second.id)
      assert agent_rows(exec.id, second.id) == []
    end
  end

  describe "list_addable_agents/1" do
    test "offers summonable agents not yet present, and nothing archived" do
      space = channel!()
      admin = user!()
      user_participant!(space.id, admin, "admin")
      present = agent!()
      absent = agent!()
      archived = agent!(%{status: "archived"})
      {:ok, _} = Chat.admin_add_agent(space, admin.id, present.id)

      ids = space |> Chat.list_addable_agents() |> Enum.map(& &1.id)

      assert absent.id in ids
      refute present.id in ids
      refute archived.id in ids
    end
  end

  describe "admin_remove_agent/3" do
    test "an admin remove deletes the row and clears the active-agent mutex" do
      space = channel!()
      admin = user!()
      user_participant!(space.id, admin, "admin")
      agent = agent!()
      {:ok, row} = Chat.admin_add_agent(space, admin.id, agent.id)

      :ok = ActiveAgentStore.set_active(space.id, row.id)
      assert ActiveAgentStore.get_active(space.id) == row.id

      assert {:ok, removed} = Chat.admin_remove_agent(space, admin.id, row.id)
      assert removed.id == row.id
      assert agent_rows(space.id, agent.id) == []
      assert ActiveAgentStore.get_active(space.id) == nil
    end

    test "a member remove is unauthorized and leaves the row" do
      space = channel!()
      admin = user!()
      member = user!()
      user_participant!(space.id, admin, "admin")
      user_participant!(space.id, member, "member")
      agent = agent!()
      {:ok, row} = Chat.admin_add_agent(space, admin.id, agent.id)

      assert {:error, :unauthorized} = Chat.admin_remove_agent(space, member.id, row.id)
      assert [_] = agent_rows(space.id, agent.id)
    end

    test "removing a user row is refused" do
      space = channel!()
      admin = user!()
      member = user!()
      user_participant!(space.id, admin, "admin")
      member_row = user_participant!(space.id, member, "member")

      assert {:error, :not_an_agent} = Chat.admin_remove_agent(space, admin.id, member_row.id)
      assert Repo.get(Participant, member_row.id)
    end

    test "an agent row from ANOTHER space is not_found and is left alone" do
      space = channel!()
      other = channel!()
      admin = user!()
      user_participant!(space.id, admin, "admin")
      user_participant!(other.id, admin, "admin")
      agent = agent!()
      {:ok, foreign_row} = Chat.admin_add_agent(other, admin.id, agent.id)

      assert {:error, :not_found} = Chat.admin_remove_agent(space, admin.id, foreign_row.id)
      assert [_] = agent_rows(other.id, agent.id)
    end

    test "a DM is refused" do
      a = user!()
      b = user!()
      {:ok, dm} = Chat.find_or_create_dm(a.id, "user", b.id)
      [row | _] = Chat.list_participants(dm.id)

      assert {:error, :dm} = Chat.admin_remove_agent(dm, a.id, row.id)
      assert Repo.get(Participant, row.id)
    end
  end
end
