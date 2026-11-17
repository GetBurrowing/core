defmodule Platform.Showrunner.ProvisionTest do
  @moduledoc """
  `Platform.Showrunner.provision/1` and its mix task (task 01a1eaf6 stage 4):
  idempotent, keeps an operator-set cadence, reports the social bundle.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Access.RuntimeProfile
  alias Platform.Access.RuntimeProfiles
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Responsibility
  alias Platform.Roles.RoleAssignment
  alias Platform.Showrunner
  alias Platform.Showrunner.Config
  alias Platform.ShowrunnerSocialFixture
  alias Platform.Tenancy

  setup do
    :ok = ShowrunnerSocialFixture.register()

    user = World.create_user!()
    World.plain_member!(user, Tenancy.get_org_by_slug!("globex"))

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "showrunner-#{System.unique_integer([:positive])}",
        name: "Showrunner",
        status: "active",
        kind: "native",
        workspace_id: nil
      })
      |> Repo.insert!()

    {:ok, space} =
      Chat.create_space(%{
        name: "How to Computer",
        slug: "htc-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "HTC #{System.unique_integer([:positive])}",
        repo_url: "https://example.com/htc"
      })

    attrs = %{
      agent_id: agent.id,
      space_id: space.id,
      project_id: project.id,
      escalate_user_id: user.id
    }

    %{agent: agent, user: user, space: space, attrs: attrs}
  end

  defp runtime!(agent, owner, modules) do
    runtime =
      Repo.insert!(%AgentRuntime{
        runtime_id: "showrunner-#{System.unique_integer([:positive])}",
        owner_user_id: owner.id,
        agent_id: agent.id,
        status: "active"
      })

    Repo.insert!(%RuntimeProfile{
      runtime_id: runtime.id,
      tool_profile: modules,
      restricted_permissions: RuntimeProfiles.translated_permissions(modules)
    })

    agent |> Ecto.Changeset.change(runtime_id: runtime.id) |> Repo.update!()
  end

  defp showrunner_rows,
    do: Repo.all(from(r in Responsibility, where: r.feature == "showrunner", order_by: r.key))

  test "provisioning twice: one assignment, six rows, the operator's cadence kept, the bundle reported",
       %{agent: agent, user: user, space: space, attrs: attrs} do
    runtime!(agent, user, ["context_read", "social"])

    assert {:ok, first} = Showrunner.provision(attrs)
    assert first.role == :assigned
    assert first.social_bundle == :present
    assert first.warnings == []
    assert length(first.responsibilities) == 6

    # An operator moves the pitch to Tuesdays between the two runs.
    {:ok, _} =
      Config.configure(
        Platform.TenancyFixtures.root_admin!(),
        "showrunner.weekly_pitch",
        %{expression: "0 15 * * 2"}
      )

    assert {:ok, second} = Showrunner.provision(attrs)
    assert second.role == :unchanged
    assert second.social_bundle == :present

    assert Repo.aggregate(from(a in RoleAssignment, where: a.role_key == "showrunner"), :count) ==
             1

    rows = showrunner_rows()
    assert Enum.map(rows, & &1.key) == Enum.sort(Showrunner.keys())

    for row <- rows do
      config = Config.read(row)
      assert config.space_id == space.id
      assert config.escalate_user_id == user.id
      assert row.trigger_config["operator_set"] == true
    end

    pitch = Responsibilities.get_by_key("showrunner.weekly_pitch")
    assert pitch.trigger_config["expression"] == "0 15 * * 2"

    post = Responsibilities.get_by_key("showrunner.post_show")
    assert post.trigger_kind == "event_topic"
    assert post.trigger_config["topic"] == "meeting:finished"

    assert Chat.get_agent_participant(space.id, agent.id)
  end

  test "an agent without the social bundle is provisioned with a warning", %{
    agent: agent,
    user: user,
    attrs: attrs
  } do
    runtime!(agent, user, ["context_read"])

    assert {:ok, report} = Showrunner.provision(attrs)
    assert report.social_bundle == {:absent, :not_effective}
    assert [warning] = report.warnings
    assert warning =~ "post_show and retro will park"

    lines = Mix.Tasks.Platform.Showrunner.Provision.lines(report)
    assert "social bundle: ABSENT (not_effective)" in lines
    assert Enum.any?(lines, &String.starts_with?(&1, "WARNING: "))
  end

  test "a role held by another agent is refused unless reassign is asked", %{attrs: attrs} do
    other =
      %Agent{}
      |> Agent.changeset(%{
        slug: "other-#{System.unique_integer([:positive])}",
        name: "Other",
        status: "active",
        kind: "native"
      })
      |> Repo.insert!()

    {:ok, _} = Platform.Roles.assign_role("showrunner", other.id)

    assert {:error, {:role_held_by, held}} = Showrunner.provision(attrs)
    assert held == other.id

    assert {:ok, %{role: :reassigned}} = Showrunner.provision(Map.put(attrs, :reassign, true))
    assert Platform.Roles.agent_id_for_role("showrunner") == attrs.agent_id
  end
end
