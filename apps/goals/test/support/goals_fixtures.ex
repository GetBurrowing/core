defmodule Platform.GoalsFixtures do
  @moduledoc """
  Goals test fixtures (task 01a1dfc0). Core rows (users, orgs, memberships,
  spaces, participants, agents) are made through core's own schemas, contexts
  and `Platform.TenancyFixtures`; nothing here writes to apps/platform.
  """

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  def unique, do: System.unique_integer([:positive])

  @doc "A fresh tenant org id (one per call)."
  def org_id!, do: Platform.TenancyFixtures.tenant_org_id("goals-org-#{unique()}")

  @doc """
  A user with no membership who holds `goals.use` (task 01a1e229): the one
  fixture every Goals test builds its people on. Goals checks the permission
  inside the context, so a person without it sees nothing; use
  `user_without_goals_use!/0` for that person.
  """
  def user!, do: user_without_goals_use!() |> grant_goals_use!()

  @doc """
  Grants `user` `goals.use` the way the component tests always have: an
  allow on a space, recorded by core's `Platform.Access.Grants`. One space
  per test process carries every such grant, so creating people adds no
  space after the first. Returns the user.
  """
  def grant_goals_use!(user) do
    {:ok, _} =
      Platform.Access.Grants.grant(%{
        principal: user,
        permission: "goals.use",
        resource: {:space, goals_use_space_id()}
      })

    user
  end

  defp goals_use_space_id do
    case Process.get({__MODULE__, :goals_use_space_id}) do
      nil ->
        id = space!(org_id!()).id
        Process.put({__MODULE__, :goals_use_space_id}, id)
        id

      id ->
        id
    end
  end

  @doc """
  Revokes every `goals.use` grant `user` holds, through core, which pushes
  the change to the person's connected live views. `push: false` deletes
  the rows without that push, for a live view that must find out from its
  own next call (a socket the push did not reach). Returns the user.
  """
  def revoke_goals_use!(user, opts \\ []) do
    grants =
      for grant <- Platform.Access.Grants.list_for_principals([{:user, user.id}]),
          grant.permission == "goals.use",
          do: grant

    if Keyword.get(opts, :push, true) do
      for grant <- grants, do: {:ok, _} = Platform.Access.Grants.revoke(grant)
    else
      for grant <- grants, do: Repo.delete!(grant)
    end

    user
  end

  @doc """
  Sets `agent`'s external runtime tool profile to `modules` (default the
  `goals` bundle) through core's `Platform.Access.RuntimeProfiles`, so the
  runtime can call the Goals tools when its owner holds `goals.use` (task
  01a1eab6 stage 3: a lead without them is refused a New goal start).
  Call after `enable_goals!/1`: the bundle is only a valid module while
  Goals is on. Returns the agent.
  """
  def grant_goals_tools!(%Platform.Agents.Agent{runtime_id: id} = agent, modules \\ ["goals"])
      when is_binary(id) do
    runtime = Repo.get!(Platform.Agents.AgentRuntime, id)
    {:ok, _} = Platform.Access.RuntimeProfiles.set_tool_profile(runtime, modules)
    agent
  end

  @doc "A user with no membership and no `goals.use`."
  def user_without_goals_use! do
    n = unique()

    %User{}
    |> User.changeset(%{
      email: "goals-user-#{n}@example.com",
      name: "Goals User #{n}",
      oidc_sub: "goals-user-#{n}"
    })
    |> Repo.insert!()
  end

  @doc "A user with an internal `member` membership in `org_id`."
  def member!(org_id), do: user!() |> join_org!(org_id)

  @doc "Gives `user` a membership in `org_id` (`external: true` for an external one)."
  def join_org!(user, org_id, opts \\ []) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: org_id,
      role: Keyword.get(opts, :role, "member"),
      external: Keyword.get(opts, :external, false)
    })
    |> Repo.insert!()

    user
  end

  @doc "An external member of `org_id`, through core's marker."
  def external_member!(org_id) do
    user = user!()
    {:ok, _} = Platform.Tenancy.mark_membership_external(%{user_id: user.id, org_id: org_id})
    user
  end

  @doc "A root-org admin (core's fixture) who holds `goals.use`."
  def root_admin!, do: Platform.TenancyFixtures.root_admin!() |> grant_goals_use!()

  @doc "A real `agents` row."
  def agent! do
    n = unique()
    Repo.insert!(%Platform.Agents.Agent{slug: "goals-agent-#{n}", name: "Goals Agent #{n}"})
  end

  @doc """
  An agent that passes `Platform.Goals.Coaches`'s rule for an internal
  user (task 01a1eab7): active, accepts chat, and an external runtime owned
  by `owner` (a `goals.use` holder) with the `goals` bundle. A goal's coach
  set through `Platform.Goals.update_goal/3` must be one. Call after
  `enable_goals!/1`.
  """
  def coach_agent!(owner \\ user!()) do
    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        owner_user_id: owner.id,
        runtime_id: "goals-coach-#{unique()}",
        display_name: "Goals coach",
        status: "active"
      })

    agent!()
    |> Ecto.Changeset.change(runtime_type: "external", runtime_id: runtime.id)
    |> Repo.update!()
    |> grant_goals_tools!()
  end

  @doc "A channel space in `org_id`, through core's Chat context."
  def space!(org_id) do
    n = unique()

    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Goals chan #{n}",
        slug: "goals-chan-#{n}",
        kind: "channel",
        org_id: org_id
      })

    space
  end

  @doc "Adds a user (`:user`) or agent (`:agent`) participant to a space."
  def join_space!(space_id, type, id) when type in [:user, :agent] do
    {:ok, participant} =
      Platform.Chat.add_participant(space_id, %{
        participant_type: Atom.to_string(type),
        participant_id: id,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  @doc "Leaves a space the way core does: `Platform.Chat.remove_participant/1` deletes the row."
  def leave_space!(participant) do
    {:ok, _} = Platform.Chat.remove_participant(participant)
    :ok
  end

  @doc "Sets `:goals, :enabled` for the test and restores it on exit."
  def enable_goals!(test_context \\ %{}) do
    previous = Application.fetch_env(:goals, :enabled)
    Application.put_env(:goals, :enabled, true)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:goals, :enabled, value)
        :error -> Application.delete_env(:goals, :enabled)
      end
    end)

    test_context
  end

  @doc "A goal owned by `owner` in `org_id`, created through the context."
  def goal!(owner, org_id, attrs \\ %{}) do
    {:ok, goal} =
      Platform.Goals.create_goal(owner, Map.merge(%{org_id: org_id, title: "Ship"}, attrs))

    goal
  end
end
