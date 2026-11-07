defmodule Platform.Agents.TeamCheckTest do
  @moduledoc """
  `Platform.Agents.TeamCheck` and the `agents.team_check` responsibility, task
  01a1b6de stage 3: per-agent status from real rows for every agent kind,
  `execution.unblocked` clearing, the schedule and re-ask interval read from
  the row, and the refusal that keeps a healthy install from costing a turn.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Agents.TeamCheck
  alias Platform.Orchestration.RuntimeEvent
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.AgentsTeamCheck
  alias Platform.Tasks
  alias Platform.Tenancy.OrgMembership

  @now ~U[2026-11-07 12:00:00.000000Z]

  setup do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Team check #{n}"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Team check #{n}"})
    %{task: task}
  end

  defp user!(label) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "tc-#{label}-#{n}@example.com",
      name: "Person#{n} #{label}",
      oidc_sub: "oidc-tc-#{label}-#{n}"
    })
  end

  defp agent!(attrs) do
    n = System.unique_integer([:positive])

    Repo.insert!(
      struct(
        %Agent{slug: "tc-agent-#{n}", name: "Agent#{n}", status: "active"},
        attrs
      )
    )
  end

  # `agent_runtimes.owner_user_id` is NOT NULL: every federated agent is
  # bound to the human who registered its runtime, its sponsor.
  defp federated!(owner \\ nil) do
    owner = owner || user!("runtime-owner")
    agent = agent!(%{kind: "native", runtime_type: "external"})

    runtime =
      Repo.insert!(%AgentRuntime{
        runtime_id: "rt-tc-#{System.unique_integer([:positive])}",
        agent_id: agent.id,
        owner_user_id: owner.id,
        status: "active"
      })

    {agent, runtime}
  end

  defp fed_row(agent, online, last_seen \\ nil) do
    %{agent_id: agent.id, online: online, last_seen_at: last_seen, last_connected_at: nil}
  end

  defp event!(task, type, runtime_id, payload, minutes_ago) do
    Repo.insert!(
      RuntimeEvent.changeset(%RuntimeEvent{}, %{
        task_id: task.id,
        phase: "execution",
        runtime_id: runtime_id,
        event_type: type,
        occurred_at: DateTime.add(@now, -minutes_ago * 60, :second),
        idempotency_key: "tc-#{System.unique_integer([:positive])}",
        payload: payload
      })
    )
  end

  defp status_for(agent, opts) do
    opts
    |> Keyword.put_new(:now, @now)
    |> Keyword.put_new(:row, nil)
    |> TeamCheck.statuses()
    |> Enum.find(&(&1.agent_id == agent.id))
  end

  describe "classification from real rows" do
    test "an offline federated agent with a 403 on record reads offline", %{task: task} do
      {agent, runtime} = federated!()
      event!(task, "execution.blocked", runtime.runtime_id, %{"description" => "push: 403"}, 10)

      status =
        status_for(agent,
          federation: [fed_row(agent, false, DateTime.add(@now, -86_400, :second))]
        )

      assert status.class == :offline
    end

    test "the same 403 on a connected agent is access, fixed by its sponsor", %{task: task} do
      sponsor = user!("sponsor")
      {agent, runtime} = federated!(sponsor)

      event!(
        task,
        "execution.blocked",
        runtime.runtime_id,
        %{"description" => "git push refused", "required_capability" => "HTTP 403"},
        10
      )

      status = status_for(agent, federation: [fed_row(agent, true, @now)])
      assert status.class == :access
      assert status.fixer == %{id: sponsor.id, name: sponsor.name}
      assert status.evidence =~ "403"
    end

    test "execution.unblocked on the same task and stage clears the failure", %{task: task} do
      {agent, runtime} = federated!()
      stage = Ecto.UUID.generate()

      event!(
        task,
        "execution.blocked",
        runtime.runtime_id,
        %{"description" => "HTTP 401", "stage_id" => stage},
        30
      )

      event!(task, "execution.unblocked", "someone-else", %{"stage_id" => stage}, 10)

      assert status_for(agent, federation: [fed_row(agent, true, @now)]).class == :ok
    end

    test "an unblock on another stage, or before the block, clears nothing", %{task: task} do
      {agent, runtime} = federated!()
      stage = Ecto.UUID.generate()

      event!(task, "execution.unblocked", "x", %{"stage_id" => stage}, 40)

      event!(
        task,
        "execution.blocked",
        runtime.runtime_id,
        %{"description" => "HTTP 401", "stage_id" => stage},
        30
      )

      event!(task, "execution.unblocked", "x", %{"stage_id" => Ecto.UUID.generate()}, 10)

      assert status_for(agent, federation: [fed_row(agent, true, @now)]).class == :credentials
    end

    test "a failure reported_by the agent id is attributed to it", %{task: task} do
      {agent, _runtime} = federated!()

      event!(
        task,
        "execution.blocked",
        "tool-surface",
        %{"description" => "mix: command not found", "reported_by" => agent.id},
        5
      )

      assert status_for(agent, federation: [fed_row(agent, true, @now)]).class == :toolchain
    end

    test "a dispatch_unanswered row is attributed by dispatch_runtime_id", %{task: task} do
      {agent, runtime} = federated!()

      event!(
        task,
        "execution.dispatch_unanswered",
        "task-router",
        %{"description" => "quota exceeded", "dispatch_runtime_id" => runtime.runtime_id},
        5
      )

      assert status_for(agent, federation: [fed_row(agent, true, @now)]).class == :spend_consent
    end

    test "another agent's failure is not this agent's", %{task: task} do
      {agent, _} = federated!()
      {_other, other_rt} = federated!()
      event!(task, "execution.blocked", other_rt.runtime_id, %{"description" => "HTTP 403"}, 5)

      assert status_for(agent, federation: [fed_row(agent, true, @now)]).class == :ok
    end

    test "failures outside the row's lookback are not read", %{task: task} do
      {agent, runtime} = federated!()

      event!(
        task,
        "execution.blocked",
        runtime.runtime_id,
        %{"description" => "HTTP 403"},
        3 * 60
      )

      row = %Responsibilities.Responsibility{metadata: %{"lookback_hours" => 1}}

      assert status_for(agent, row: row, federation: [fed_row(agent, true, @now)]).class == :ok
    end
  end

  describe "every agent kind" do
    test "native built-in, federated with no runtime, and external HTTP all classify" do
      built_in = agent!(%{kind: "native", runtime_type: "built_in"})
      no_runtime = agent!(%{kind: "native", runtime_type: "external"})

      external =
        agent!(%{
          kind: "external",
          runtime_type: "http",
          endpoint_kind: "openai_compat",
          base_url: "http://127.0.0.1:1",
          model: "placeholder"
        })

      statuses = TeamCheck.statuses(now: @now, row: nil, federation: [])
      by_id = Map.new(statuses, &{&1.agent_id, &1})

      assert by_id[built_in.id].class == :ok
      assert by_id[no_runtime.id].class == :offline
      assert by_id[no_runtime.id].evidence =~ "no runtime"
      assert by_id[external.id].class == :offline
      assert by_id[external.id].kind == :ext_single_responsibility
    end

    test "the real federation_status path does not raise" do
      {agent, _} = federated!()
      status = TeamCheck.statuses(row: nil) |> Enum.find(&(&1.agent_id == agent.id))
      assert status.class == :offline
    end

    test "paused and archived agents are not checked" do
      paused = agent!(%{status: "paused"})
      ids = TeamCheck.statuses(now: @now, row: nil, federation: []) |> Enum.map(& &1.agent_id)
      refute paused.id in ids
    end
  end

  describe "the owner is the default fixer" do
    test "an unbound agent's fixer is the install owner" do
      owner = user!("owner")

      Repo.insert!(
        OrgMembership.changeset(%OrgMembership{}, %{
          user_id: owner.id,
          org_id: Platform.TenancyFixtures.acme_org_id(),
          role: "admin"
        })
      )

      agent = agent!(%{kind: "native", runtime_type: "external"})
      status = status_for(agent, federation: [])
      assert status.fixer == Platform.Accounts.install_owner()
      assert status.fixer != nil
    end
  end

  describe "schedule and interval are data on the row" do
    setup do
      [spec] = AgentsTeamCheck.register()
      {:ok, row} = Responsibilities.upsert_by_key(spec)
      %{row: row}
    end

    test "the declared default is daily", %{row: row} do
      assert TeamCheck.cadence(row) == %{cadence: :daily, hour_utc: 15}
      assert TeamCheck.reask_after_hours(row) == 72
    end

    test "an operator cadence write is what cadence/1 reads, and survives re-registration" do
      admin = user!("admin")

      Repo.insert!(
        OrgMembership.changeset(%OrgMembership{}, %{
          user_id: admin.id,
          org_id: Platform.TenancyFixtures.acme_org_id(),
          role: "admin"
        })
      )

      assert {:ok, _} = Responsibilities.set_cron_cadence(admin, "agents.team_check", :every_4h)
      assert TeamCheck.cadence() == %{cadence: :every_4h, hour_utc: nil}

      [spec] = AgentsTeamCheck.register()
      {:ok, _} = Responsibilities.upsert_by_key(spec)
      assert TeamCheck.cadence() == %{cadence: :every_4h, hour_utc: nil}
    end

    test "the re-ask interval comes from the row: operator config, then metadata", %{row: row} do
      {:ok, row} =
        Responsibilities.update_responsibility(row, %{
          metadata: Map.put(row.metadata, "reask_after_hours", 1)
        })

      assert TeamCheck.reask_after_hours(row) == 1

      # Task 01a1b6de stage 4: the operator's value beats declared metadata.
      {:ok, row} = Responsibilities.put_operator_config(row.key, %{"reask_after_hours" => 9})
      assert TeamCheck.reask_after_hours(row) == 9

      # Neither: the configured default.
      assert TeamCheck.reask_after_hours(%Responsibilities.Responsibility{metadata: %{}}) == 72
    end

    test "the offline threshold comes from the row's metadata" do
      {agent, _} = federated!()
      seen = DateTime.add(@now, -30 * 60, :second)

      short = %Responsibilities.Responsibility{metadata: %{"offline_after_minutes" => 10}}
      long = %Responsibilities.Responsibility{metadata: %{"offline_after_minutes" => 60}}

      assert status_for(agent, row: short, federation: [fed_row(agent, false, seen)]).class ==
               :offline

      assert status_for(agent, row: long, federation: [fed_row(agent, false, seen)]).class == :ok
    end
  end

  describe "the fire" do
    test "a stuck agent is raised once, then not again inside the interval", %{task: task} do
      sponsor = user!("sponsor")
      {agent, runtime} = federated!(sponsor)
      event!(task, "execution.blocked", runtime.runtime_id, %{"description" => "HTTP 403"}, 5)

      [spec] = AgentsTeamCheck.register()
      {:ok, row} = Responsibilities.upsert_by_key(spec)

      Repo.update!(Ecto.Changeset.change(runtime, last_connected_at: @now))

      first = AgentsTeamCheck.build_context(row, DateTime.add(@now, 60, :second))
      assert Enum.any?(first.raise, &(&1.agent_id == agent.id))
      assert {:ok, %{user: user}} = AgentsTeamCheck.build_prompt(first)
      assert user =~ agent.name
      assert user =~ sponsor.name

      second = AgentsTeamCheck.build_context(row, DateTime.add(@now, 120, :second))
      refute Enum.any?(second.raise, &(&1.agent_id == agent.id))
    end

    test "nothing due refuses the dispatch" do
      assert {:error, {:nothing_to_raise, _}} = AgentsTeamCheck.build_prompt(%{raise: []})
    end

    test "nothing on the team check path calls a model" do
      for mod <- [TeamCheck, AgentsTeamCheck] do
        {:ok, {_, [imports: imports]}} = :beam_lib.chunks(:code.which(mod), [:imports])

        offenders =
          imports
          |> Enum.map(&elem(&1, 0))
          |> Enum.uniq()
          |> Enum.filter(fn m ->
            name = Atom.to_string(m)

            String.starts_with?(name, "Elixir.Platform.Agents.Providers") or
              String.starts_with?(name, "Elixir.Req") or
              name in [
                "Elixir.Platform.Agents.AgentServer",
                "Elixir.Platform.Agents.ToollessChat"
              ]
          end)

        assert offenders == [], "#{inspect(mod)} calls #{inspect(offenders)}"
      end
    end
  end
end
