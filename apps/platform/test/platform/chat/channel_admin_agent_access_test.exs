defmodule Platform.Chat.ChannelAdminAgentAccessTest do
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      name: "Channel authority #{n}",
      email: "channel-authority-#{n}@example.test",
      oidc_sub: "channel-authority-#{n}"
    })
  end

  defp membership!(user, org_id, role, external \\ false) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: org_id,
      role: role,
      external: external
    })
    |> Repo.insert!()
  end

  defp channel! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Channel authority #{n}",
        slug: "channel-authority-#{n}",
        kind: "channel",
        org_id: Tenancy.get_org_by_slug!("initech").id
      })

    space
  end

  defp participant!(space, user, role \\ "member") do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        role: role,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp agent! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      name: "Channel helper #{n}",
      slug: "channel-helper-#{n}",
      status: "active"
    })
  end

  defp grant_admin!(:root_admin, user, _space),
    do: membership!(user, Tenancy.get_root_org().id, "admin")

  defp grant_admin!(:org_admin, user, space), do: membership!(user, space.org_id, "admin")

  defp assert_refused(space, user) do
    agent = agent!()
    refute Chat.can_summon_agents?(space, user.id)
    assert {:error, :unauthorized} = Chat.admin_add_agent(space, user.id, agent.id)

    refute Repo.exists?(
             from(p in Participant,
               where:
                 p.space_id == ^space.id and p.participant_type == "agent" and
                   p.participant_id == ^agent.id
             )
           )
  end

  defp execution!(sponsor) do
    {:ok, project} =
      Platform.Tasks.create_project(%{name: "Authority #{System.unique_integer([:positive])}"})

    {:ok, task} =
      Platform.Tasks.create_task(%{
        project_id: project.id,
        title: "Authority sponsor",
        sponsor_user_id: sponsor.id
      })

    {:ok, space} =
      Chat.create_space(%{
        kind: "execution",
        name: "Authority",
        metadata: %{"task_id" => task.id}
      })

    space
  end

  for authority <- [:org_admin, :root_admin] do
    test "#{authority} may add an agent without being a channel admin" do
      authority = unquote(authority)
      user = user!()
      space = channel!()
      participant = participant!(space, user)
      grant_admin!(authority, user, space)
      agent = agent!()

      assert Repo.get!(Participant, participant.id).role == "member"

      assert Repo.aggregate(
               from(p in Participant,
                 where:
                   p.space_id == ^space.id and p.participant_type == "user" and p.role == "admin"
               ),
               :count
             ) == 0

      assert Chat.can_manage_roles?(space, user.id)
      allowed = Chat.can_summon_agents?(space, user.id)
      result = Chat.admin_add_agent(space, user.id, agent.id)

      assert allowed
      assert {:ok, added} = result
      assert added.participant_id == agent.id
      assert added.history_visible_from != nil
      assert Repo.get!(Participant, participant.id).role == "member"
    end

    test "#{authority} may add to a channel without a participant row" do
      user = user!()
      space = channel!()
      grant_admin!(unquote(authority), user, space)
      agent = agent!()

      assert Chat.can_summon_agents?(space, user.id)
      assert {:ok, added} = Chat.admin_add_agent(space, user.id, agent.id)
      assert added.participant_id == agent.id

      refute Repo.exists?(
               from(p in Participant,
                 where: p.space_id == ^space.id and p.participant_id == ^user.id
               )
             )
    end

    test "#{authority} authority alone does not grant execution-space access" do
      user = user!()
      channel = channel!()
      grant_admin!(unquote(authority), user, channel)
      execution = execution!(user!())
      execution = execution |> Ecto.Changeset.change(org_id: channel.org_id) |> Repo.update!()
      participant!(execution, user)

      assert_refused(execution, user)
    end

    test "external user with #{authority} authority is refused" do
      user = user!()
      space = channel!()
      grant_admin!(unquote(authority), user, space)
      membership!(user, Tenancy.get_org_by_slug!("globex").id, "member", true)
      participant!(space, user)

      # The global external flag must win even over an internal admin grant.
      assert Chat.can_manage_roles?(space, user.id)
      assert_refused(space, user)
    end
  end

  test "plain members, external members and another org's admin are refused" do
    for authority <- [:member, :external, :other_org_admin] do
      user = user!()
      space = channel!()
      participant!(space, user)

      case authority do
        :member -> membership!(user, space.org_id, "member")
        :external -> membership!(user, space.org_id, "member", true)
        :other_org_admin -> membership!(user, Tenancy.get_org_by_slug!("globex").id, "admin")
      end

      assert_refused(space, user)
    end
  end

  test "external channel admins and execution sponsors are refused before either grant" do
    user = user!()
    space = channel!()
    membership!(user, space.org_id, "member", true)
    participant!(space, user, "admin")
    assert_refused(space, user)

    execution = execution!(user)
    participant!(execution, user)
    assert_refused(execution, user)
  end

  test "an external root-admin membership cannot bypass the external-user guard" do
    user = user!()
    membership!(user, Tenancy.get_root_org().id, "admin", true)
    space = channel!()
    participant!(space, user)

    assert Tenancy.root_admin?(user)
    assert Tenancy.external_user?(user)
    assert_refused(space, user)
  end

  test "internal channel admins and execution sponsors retain the writer grant" do
    user = user!()
    space = channel!()
    participant!(space, user, "admin")
    assert Chat.can_summon_agents?(space, user.id)
    assert {:ok, _} = Chat.admin_add_agent(space, user.id, agent!().id)

    sponsor = user!()
    execution = execution!(sponsor)
    participant!(execution, sponsor)
    assert Chat.can_summon_agents?(execution, sponsor.id)
    assert {:ok, _} = Chat.admin_add_agent(execution, sponsor.id, agent!().id)
  end

  test "root authority adds no DM grant and the writer keeps its DM refusal" do
    user = user!()
    membership!(user, Tenancy.get_root_org().id, "admin")
    {:ok, dm} = Chat.find_or_create_dm(user.id, "user", user!().id)
    refute Chat.can_summon_agents?(dm, user.id)
    assert {:error, :dm} = Chat.admin_add_agent(dm, user.id, agent!().id)
  end
end
