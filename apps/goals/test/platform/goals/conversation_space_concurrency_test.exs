defmodule Platform.Goals.ConversationSpaceConcurrencyTest do
  @moduledoc """
  `Platform.Goals.Conversation.ensure_space/1` from several processes at
  once gives ONE space (task 01a20939 stage 1).

  Inside the SQL sandbox every process shares one connection, so two
  transactions can never overlap and the race cannot happen. This module
  puts the pool in `:auto` mode (the pattern of
  `Platform.Goals.IntakeDispatchIntegrationTest`): each caller has its own
  real connection and really commits, so without the goal-row lock every
  caller reads "no space yet" and makes its own. Every row the test creates
  is deleted in `on_exit`.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat.{Participant, Space}
  alias Platform.Goals.{Conversation, Goal}
  alias Platform.Repo
  alias Platform.Tenancy.Org

  @callers 6

  setup do
    Sandbox.mode(Repo, :auto)
    n = System.unique_integer([:positive])
    root = Platform.Tenancy.get_root_org()

    org =
      %Org{}
      |> Org.changeset(%{
        name: "Goal space #{n}",
        slug: "goal-space-#{n}",
        parent_org_id: root.id
      })
      |> Repo.insert!()

    owner =
      Repo.insert!(%User{
        email: "goal-space-#{n}@example.com",
        name: "Goal space owner #{n}",
        oidc_sub: "oidc-goal-space-#{n}"
      })

    coach = Repo.insert!(%Agent{slug: "goal-space-coach-#{n}", name: "Goal space coach #{n}"})

    goal =
      Repo.insert!(%Goal{
        org_id: org.id,
        owner_user_id: owner.id,
        coach_agent_id: coach.id,
        title: "Concurrent"
      })

    on_exit(fn ->
      space_ids =
        Repo.all(
          from(s in Space,
            where: fragment("?->>'goal_id' = ?", s.metadata, ^goal.id),
            select: s.id
          )
        )

      Repo.delete_all(from(g in Goal, where: g.id == ^goal.id))
      Repo.delete_all(from(p in Participant, where: p.space_id in ^space_ids))
      Repo.delete_all(from(s in Space, where: s.id in ^space_ids))
      Repo.delete_all(from(a in Agent, where: a.id == ^coach.id))
      Repo.delete_all(from(u in User, where: u.id == ^owner.id))
      Repo.delete_all(from(o in Org, where: o.id == ^org.id))
      Sandbox.mode(Repo, :manual)
    end)

    %{goal: goal}
  end

  test "concurrent ensure_space calls all return one space", %{goal: goal} do
    parent = self()

    tasks =
      for _ <- 1..@callers do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> Conversation.ensure_space(goal))
        end)
      end

    pids = for _ <- 1..@callers, do: receive(do: ({:ready, pid} -> pid))
    Enum.each(pids, &send(&1, :go))

    results = Enum.map(tasks, &Task.await(&1, 30_000))
    ids = for {:ok, %Space{id: id}} <- results, do: id

    assert length(ids) == @callers
    assert length(Enum.uniq(ids)) == 1

    spaces =
      Repo.all(from(s in Space, where: fragment("?->>'goal_id' = ?", s.metadata, ^goal.id)))

    assert [%Space{id: only}] = spaces
    assert [only] == Enum.uniq(ids)
    assert Repo.get!(Goal, goal.id).conversation_space_id == only

    assert Repo.aggregate(from(p in Participant, where: p.space_id == ^only), :count) == 2
  end
end
