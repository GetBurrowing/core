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

  @doc "A user with no membership."
  def user! do
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

  @doc "A root-org admin (core's fixture)."
  def root_admin!, do: Platform.TenancyFixtures.root_admin!()

  @doc "A real `agents` row."
  def agent! do
    n = unique()
    Repo.insert!(%Platform.Agents.Agent{slug: "goals-agent-#{n}", name: "Goals Agent #{n}"})
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
