defmodule Platform.Chat.ChannelMembersAdminTest do
  @moduledoc """
  Task 01a0fd62-a7ef-7001-8477-bd17e47bbaca stage 3: `Chat.admin_add_agent/3`
  and `Chat.admin_remove_agent/3`, the context gate behind the channel members
  panel. Task 01a199e4-561b-7000-b30c-1fa66d3add90 stage 1 adds
  `Chat.admin_add_person/3` and `Chat.list_addable_people/1`, the people-add
  gate behind the same panel.

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

  # ── People (task 01a199e4 stage 1) ─────────────────────────────────────────

  defp membership!(user, org_id, role, external \\ false) do
    %Platform.Tenancy.OrgMembership{}
    |> Platform.Tenancy.OrgMembership.changeset(%{
      user_id: user.id,
      org_id: org_id,
      role: role,
      external: external
    })
    |> Repo.insert!()
  end

  defp org_user!(org_id, role \\ "member") do
    user = user!()
    membership!(user, org_id, role)
    user
  end

  defp org_channel!(org_id) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "People #{n}",
        slug: "people-#{n}",
        kind: "channel",
        org_id: org_id
      })

    space
  end

  defp user_rows(space_id, user_id) do
    Repo.all(
      from(p in Participant,
        where:
          p.space_id == ^space_id and p.participant_type == "user" and
            p.participant_id == ^user_id
      )
    )
  end

  defp addable_ids(space), do: space |> Chat.list_addable_people() |> Enum.map(& &1.id)

  # A channel in a tenant org with one human admin participant.
  defp people_ctx do
    org_id = Platform.Tenancy.get_org_by_slug!("initech").id
    space = org_channel!(org_id)
    admin = org_user!(org_id)
    user_participant!(space.id, admin, "admin")
    %{org_id: org_id, space: space, admin: admin}
  end

  describe "admin_add_person/3" do
    test "a channel admin seats an org member as a member with unbounded history, who can post" do
      c = people_ctx()
      ben = org_user!(c.org_id)
      assert ben.id in addable_ids(c.space)

      assert {:ok, %Participant{} = p} = Chat.admin_add_person(c.space, c.admin.id, ben.id)

      assert [row] = user_rows(c.space.id, ben.id)
      assert row.id == p.id
      assert row.role == "member"
      assert row.display_name == ben.name
      assert %DateTime{} = row.joined_at
      assert row.history_visible_from == nil

      assert {:ok, _msg} =
               Chat.post_message(%{
                 space_id: c.space.id,
                 participant_id: row.id,
                 content_type: "text",
                 content: "hello from Ben"
               })

      refute ben.id in addable_ids(c.space)
    end

    test "an org admin of the space's org who is not a participant is authorized" do
      c = people_ctx()
      org_admin = org_user!(c.org_id, "admin")
      ben = org_user!(c.org_id)

      assert {:ok, _} = Chat.admin_add_person(c.space, org_admin.id, ben.id)
      assert [_] = user_rows(c.space.id, ben.id)
      assert user_rows(c.space.id, org_admin.id) == []
    end

    test "a root admin with no row in the space's org is authorized" do
      c = people_ctx()
      root = org_user!(Platform.Tenancy.get_org_by_slug!("acme").id, "admin")
      assert Platform.Tenancy.root_admin?(root)
      ben = org_user!(c.org_id)

      assert {:ok, _} = Chat.admin_add_person(c.space, root.id, ben.id)
      assert [_] = user_rows(c.space.id, ben.id)
      assert user_rows(c.space.id, root.id) == []
    end

    test "a plain member and a nil actor are unauthorized and write no row" do
      c = people_ctx()
      member = org_user!(c.org_id)
      user_participant!(c.space.id, member, "member")
      ben = org_user!(c.org_id)

      assert {:error, :unauthorized} = Chat.admin_add_person(c.space, member.id, ben.id)
      assert {:error, :unauthorized} = Chat.admin_add_person(c.space, nil, ben.id)
      assert user_rows(c.space.id, ben.id) == []

      # Positive control: the admin's add of the same person lands.
      assert {:ok, _} = Chat.admin_add_person(c.space, c.admin.id, ben.id)
      assert [_] = user_rows(c.space.id, ben.id)
    end

    test "a DM, a group and an execution space are not_channel, even for a root admin" do
      org_id = Platform.Tenancy.get_org_by_slug!("initech").id
      root = org_user!(Platform.Tenancy.get_org_by_slug!("acme").id, "admin")
      sam = org_user!(org_id)
      other = org_user!(org_id)
      {:ok, dm} = Chat.find_or_create_dm(root.id, "user", other.id)

      # `find_or_create_dm/3` seats both ends; the others get the root admin
      # as an admin row, so only the kind clause can refuse.
      spaces =
        [dm] ++
          for kind <- ~w(group execution) do
            space =
              Repo.insert!(%Platform.Chat.Space{
                kind: kind,
                name: kind,
                org_id: org_id,
                slug: "people-#{kind}-#{System.unique_integer([:positive])}"
              })

            user_participant!(space.id, root, "admin")
            space
          end

      for space <- spaces do
        assert {:error, :not_channel} = Chat.admin_add_person(space, root.id, sam.id)
        assert user_rows(space.id, sam.id) == []
        assert Chat.list_addable_people(space) == []
      end
    end

    test "an external user is refused :external and never offered, even with an internal membership" do
      c = people_ctx()
      ext = user!()
      membership!(ext, c.org_id, "member", true)

      # Internal in the space's org, external in another org.
      dual = org_user!(c.org_id)
      membership!(dual, Platform.Tenancy.get_org_by_slug!("globex").id, "member", true)

      ids = addable_ids(c.space)
      refute ext.id in ids
      refute dual.id in ids

      assert {:error, :external} = Chat.admin_add_person(c.space, c.admin.id, ext.id)
      assert {:error, :external} = Chat.admin_add_person(c.space, c.admin.id, dual.id)
      assert user_rows(c.space.id, ext.id) == []
      assert user_rows(c.space.id, dual.id) == []
    end

    test "a member of a different non-root org is not offered and is not_found" do
      c = people_ctx()
      kim = org_user!(Platform.Tenancy.get_org_by_slug!("globex").id)

      refute kim.id in addable_ids(c.space)
      assert {:error, :not_found} = Chat.admin_add_person(c.space, c.admin.id, kim.id)
      assert user_rows(c.space.id, kim.id) == []
    end

    test "a member lacking a restricted channel's role is not offered and is not_found" do
      c = people_ctx()
      lou = org_user!(c.org_id)

      # Positive control: before the restriction Lou is offered.
      assert lou.id in addable_ids(c.space)

      root = org_user!(Platform.Tenancy.get_org_by_slug!("acme").id, "admin")
      assert {:ok, _} = Platform.Access.Restrictions.restrict_space(c.space, ["admin"], root.id)

      refute lou.id in addable_ids(c.space)
      assert {:error, :not_found} = Chat.admin_add_person(c.space, c.admin.id, lou.id)
      assert user_rows(c.space.id, lou.id) == []
    end

    test "existing participants are never offered and adding one is already_member" do
      c = people_ctx()
      member = org_user!(c.org_id)
      co_admin = org_user!(c.org_id)
      user_participant!(c.space.id, member, "member")
      user_participant!(c.space.id, co_admin, "admin")
      hal = org_user!(c.org_id)

      ids = addable_ids(c.space)
      assert hal.id in ids

      for seated <- [c.admin, member, co_admin] do
        refute seated.id in ids

        assert {:error, :already_member} =
                 Chat.admin_add_person(c.space, c.admin.id, seated.id)

        assert [_] = user_rows(c.space.id, seated.id)
      end
    end

    test "an archived user and a malformed id are not_found, never a cast error" do
      c = people_ctx()
      gone = org_user!(c.org_id)

      gone
      |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
      |> Repo.update!()

      refute gone.id in addable_ids(c.space)
      assert {:error, :not_found} = Chat.admin_add_person(c.space, c.admin.id, gone.id)
      assert {:error, :not_found} = Chat.admin_add_person(c.space, c.admin.id, "not-a-uuid")
      assert {:error, :not_found} = Chat.admin_add_person(c.space, c.admin.id, nil)

      assert {:error, :not_found} =
               Chat.admin_add_person(c.space, c.admin.id, Ecto.UUID.generate())

      assert user_rows(c.space.id, gone.id) == []
    end

    test "an archived channel is space_archived and writes no row" do
      c = people_ctx()
      ben = org_user!(c.org_id)
      {:ok, archived} = Chat.archive_space(c.space)

      assert {:error, :space_archived} = Chat.admin_add_person(archived, c.admin.id, ben.id)
      assert user_rows(c.space.id, ben.id) == []
    end
  end

  describe "list_addable_people/1" do
    test "offers internal space-org and root-org members, sorted by name then email" do
      c = people_ctx()
      acme_id = Platform.Tenancy.get_org_by_slug!("acme").id
      n = System.unique_integer([:positive])

      zed =
        Repo.insert!(%Platform.Accounts.User{
          name: "Zz People #{n}",
          email: "b-#{n}@example.com",
          oidc_sub: "sub-zb-#{n}"
        })

      zed2 =
        Repo.insert!(%Platform.Accounts.User{
          name: "Zz People #{n}",
          email: "a-#{n}@example.com",
          oidc_sub: "sub-za-#{n}"
        })

      membership!(zed, c.org_id, "member")
      membership!(zed2, acme_id, "member")

      ids = addable_ids(c.space)
      assert zed.id in ids
      assert zed2.id in ids

      # Same name: the email breaks the tie.
      assert Enum.filter(ids, &(&1 in [zed.id, zed2.id])) == [zed2.id, zed.id]
    end
  end
end
