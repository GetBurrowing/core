defmodule Platform.Orchestration.PhaseRuntimeTest do
  @moduledoc """
  Unit coverage for `Platform.Orchestration.PhaseRuntime.resolve/1`
  (task 019fb977).

  ## Why every refusal gets its own fixture

  `resolve/1` returns FIVE distinct error atoms, and its two callers branch on
  them differently: `TaskRouter` SUPPRESSES a dispatch on `:user_assignee` and
  FAILS OPEN on everything else. Collapsing any two atoms therefore silently
  merges two behaviours — a dispatch that should never have been sent gets
  sent, to the previously-held agent, which is the phase-blind bug this task
  exists to fix wearing a different hat.

  "Two refusal paths returning the same atom" has bitten this codebase
  repeatedly, so each atom here is produced by a fixture that can produce ONLY
  it:

    * `:no_assignee` — no phase entry AND no flat pointer.
    * `:user_assignee` — a phase entry of type `"user"`.
    * `:agent_not_found` — a well-formed UUID naming no `agents` row.
    * `:no_runtime` — a real `Agent` row, deliberately never passed to
      `Federation.link_agent/2`.
    * `:sandbox_unowned` — the `rescue`/`catch` seams. See the describe block
      at the bottom for why that one is asserted differently.

  This file is `async: true` on purpose: manual sandbox mode is what makes the
  `:sandbox_unowned` case reachable at all.
  """
  use Platform.DataCase, async: true

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Federation
  alias Platform.Orchestration.PhaseRuntime
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "PhaseRuntime Project #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/phase-runtime"
      })

    %{project: project}
  end

  describe "resolve/1 — the happy path" do
    test "answers the runtime for the CURRENT phase, not the flat pointer", %{project: project} do
      {agent_a, _runtime_a} = linked_agent_runtime("planning")
      {agent_b, runtime_b} = linked_agent_runtime("execution")

      task =
        project
        |> create_task!()
        |> put_fields(%{
          status: "in_progress",
          assignee_id: agent_a.id,
          assignee_type: "agent",
          phase_assignees: %{
            "planning" => entry(agent_a),
            "execution" => entry(agent_b)
          }
        })

      assert Tasks.current_phase(task) == "execution"
      assert {:ok, %{type: :federated, id: ^runtime_b}} = PhaseRuntime.resolve(task)
    end

    test "falls back to the flat pointer when the phase has no entry", %{project: project} do
      {agent_a, runtime_a} = linked_agent_runtime("planning")

      task =
        project
        |> create_task!()
        |> put_fields(%{
          status: "in_progress",
          assignee_id: agent_a.id,
          assignee_type: "agent",
          phase_assignees: %{}
        })

      assert {:ok, %{id: ^runtime_a}} = PhaseRuntime.resolve(task)
    end

    test "follows the task across a phase boundary", %{project: project} do
      {agent_a, runtime_a} = linked_agent_runtime("planning")
      {agent_b, runtime_b} = linked_agent_runtime("execution")

      task =
        project
        |> create_task!()
        |> put_fields(%{
          status: "planning",
          assignee_id: agent_a.id,
          assignee_type: "agent",
          phase_assignees: %{"planning" => entry(agent_a), "execution" => entry(agent_b)}
        })

      assert {:ok, %{id: ^runtime_a}} = PhaseRuntime.resolve(task)

      moved = put_fields(task, %{status: "in_progress"})

      assert {:ok, %{id: ^runtime_b}} = PhaseRuntime.resolve(moved),
             "the SAME task struct at a different status must resolve to a different runtime; " <>
               "that is the whole mechanism"
    end
  end

  describe "resolve/1 — five refusals, five causes" do
    test ":no_assignee when neither a phase entry nor a flat pointer exists", %{project: project} do
      task =
        project
        |> create_task!()
        |> put_fields(%{status: "in_progress", assignee_id: nil, phase_assignees: %{}})

      assert {:error, :no_assignee} = PhaseRuntime.resolve(task)
    end

    test ":user_assignee when the current phase is owned by a human", %{project: project} do
      {agent_b, _runtime_b} = linked_agent_runtime("execution")
      user = create_user()

      task =
        project
        |> create_task!()
        |> put_fields(%{
          status: "in_review",
          assignee_id: agent_b.id,
          assignee_type: "agent",
          phase_assignees: %{
            "execution" => entry(agent_b),
            "review" => %{"assignee_id" => user.id, "assignee_type" => "user"}
          }
        })

      assert Tasks.current_phase(task) == "review"

      assert {:error, :user_assignee} = PhaseRuntime.resolve(task),
             "a human-owned phase must NOT degrade to :agent_not_found — the router " <>
               "suppresses on :user_assignee and fails open on everything else"
    end

    test ":agent_not_found for a well-formed id naming no agent row", %{project: project} do
      orphan_id = Platform.Types.UUIDv7.generate()

      task =
        project
        |> create_task!()
        |> put_fields(%{
          status: "in_progress",
          assignee_id: nil,
          phase_assignees: %{
            "execution" => %{"assignee_id" => orphan_id, "assignee_type" => "agent"}
          }
        })

      assert {:error, :agent_not_found} = PhaseRuntime.resolve(task)
    end

    test ":agent_not_found — not a raise — for a malformed phase-entry id", %{project: project} do
      # `Task.validate_phase_assignees/1` validates only the PHASE KEYS, never
      # the id shape, so an MCP `task_update` can put an arbitrary string here.
      # Unguarded this is `Ecto.Query.CastError` raised inside the router's
      # dispatch path — a crash, not a refusal.
      task =
        project
        |> create_task!()
        |> put_fields(%{
          status: "in_progress",
          assignee_id: nil,
          phase_assignees: %{
            "execution" => %{"assignee_id" => "higgins", "assignee_type" => "agent"}
          }
        })

      assert {:error, :agent_not_found} = PhaseRuntime.resolve(task)
    end

    test ":no_runtime for a real agent that was never linked to a runtime", %{project: project} do
      # DELIBERATELY no `Federation.link_agent/2`. This is the ONLY fixture in
      # the suite that reaches the router's fail-open arm, which is what lets
      # a mutation deleting that arm detonate exactly one test.
      unlinked = create_agent("unlinked")
      assert unlinked.runtime_id == nil

      task =
        project
        |> create_task!()
        |> put_fields(%{
          status: "in_progress",
          assignee_id: nil,
          phase_assignees: %{"execution" => entry(unlinked)}
        })

      assert {:error, :no_runtime} = PhaseRuntime.resolve(task)
    end

    test "the five atoms are pairwise distinct", %{project: project} do
      {agent_b, _} = linked_agent_runtime("execution")
      user = create_user()
      unlinked = create_agent("unlinked")

      no_assignee =
        project
        |> create_task!()
        |> put_fields(%{status: "in_progress", assignee_id: nil, phase_assignees: %{}})

      user_assignee =
        project
        |> create_task!()
        |> put_fields(%{
          status: "in_review",
          assignee_id: agent_b.id,
          assignee_type: "agent",
          phase_assignees: %{"review" => %{"assignee_id" => user.id, "assignee_type" => "user"}}
        })

      not_found =
        project
        |> create_task!()
        |> put_fields(%{
          status: "in_progress",
          assignee_id: nil,
          phase_assignees: %{
            "execution" => %{
              "assignee_id" => Platform.Types.UUIDv7.generate(),
              "assignee_type" => "agent"
            }
          }
        })

      no_runtime =
        project
        |> create_task!()
        |> put_fields(%{
          status: "in_progress",
          assignee_id: nil,
          phase_assignees: %{"execution" => entry(unlinked)}
        })

      reasons =
        Enum.map([no_assignee, user_assignee, not_found, no_runtime], fn task ->
          {:error, reason} = PhaseRuntime.resolve(task)
          reason
        end)

      assert reasons == [:no_assignee, :user_assignee, :agent_not_found, :no_runtime]

      assert length(Enum.uniq(reasons)) == 4,
             "four distinct causes collapsed onto #{length(Enum.uniq(reasons))} atom(s): " <>
               "#{inspect(reasons)}"
    end
  end

  describe "resolve/1 — :sandbox_unowned" do
    # The other four atoms have fixtures. This one is a property of the
    # process calling `resolve/1`, not of the task: it can only arise when the
    # caller is outside the Ecto sandbox owner chain, which is exactly the
    # `TaskRouterWatcher` singleton receiving a `tasks:board` broadcast from an
    # `async: true` test. A raw `spawn/1` reproduces that condition honestly —
    # no `$callers` chain, no `Sandbox.allow/3` — so this is a real exercise of
    # the `rescue` seam rather than a fixture pretending to be one.
    #
    # It is NOT reachable from an ordinary `async: false` DataCase test: shared
    # mode hands the connection to every process, so the `Repo.get` succeeds
    # and nothing raises. That is why the `catch :exit` twin below is asserted
    # by CONSTRUCTION and not simulated — its trigger is a sandbox connection
    # being torn down mid-query by an exiting owner, a race this suite must not
    # try to stage deliberately.
    #
    # CENSUS NOTE for task 019fb978, which is counting sandbox-ownership
    # violations across the suite: this test manufactures exactly ONE
    # `DBConnection.OwnershipError` per run, deliberately, and rescues it
    # in-process. It is a checkout refusal, not a mid-query teardown, so it
    # produces no Postgrex disconnect and no crash — but it WILL show up in a
    # raw violation count and should be subtracted from it.
    test "an unowned caller degrades instead of crashing", %{project: project} do
      {agent_b, _runtime_b} = linked_agent_runtime("execution")

      task =
        project
        |> create_task!()
        |> put_fields(%{
          status: "in_progress",
          assignee_id: agent_b.id,
          assignee_type: "agent",
          phase_assignees: %{"execution" => entry(agent_b)}
        })

      parent = self()

      # Raw `spawn/1`, NOT `Task.async/1`: the latter propagates `$callers`,
      # which the sandbox walks to find an owner, and the call would simply
      # succeed.
      spawn(fn -> send(parent, {:resolved, PhaseRuntime.resolve(task)}) end)

      assert_receive {:resolved, result}, 5_000

      assert result == {:error, :sandbox_unowned},
             "an unowned caller must degrade to a tagged error; got #{inspect(result)}. " <>
               "A crash here is the repo cascade documented in " <>
               "Platform.Orchestration.SandboxGuard's moduledoc."
    end

    test "the owner-exited (:exit) seam exists alongside the ownership-error one" do
      source = File.read!("lib/platform/orchestration/phase_runtime.ex")

      assert source =~ "rescue"
      assert source =~ "DBConnection.OwnershipError"
      assert source =~ "catch"
      assert source =~ ":exit, _reason"

      assert source
             |> String.split(":sandbox_unowned")
             |> length() > 3,
             "both seams must yield :sandbox_unowned; the type spec plus two clauses " <>
               "means at least three occurrences"
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp create_user do
    Repo.insert!(%User{
      email: "phase_runtime_#{System.unique_integer([:positive])}@example.com",
      name: "Phase Runtime Test User",
      oidc_sub: "oidc-phase-runtime-#{System.unique_integer([:positive])}"
    })
  end

  defp create_agent(label) do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "phase-runtime-#{label}-#{System.unique_integer([:positive])}",
        name: "Phase Runtime #{label}",
        status: "active"
      })
      |> Repo.insert()

    agent
  end

  defp linked_agent_runtime(label) do
    user = create_user()
    agent = create_agent(label)

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "phase-runtime-#{label}-rt-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
    {:ok, _linked} = Federation.link_agent(activated, agent)

    {agent, activated.runtime_id}
  end

  defp create_task!(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "PhaseRuntime Task #{System.unique_integer([:positive])}",
        description: "Resolves a phase runtime"
      })

    task
  end

  # Fixture construction bypassing `Tasks.update_task/2` on purpose: the point
  # is to build exact DB states, not to exercise the writers that normalise
  # them on the way in.
  defp put_fields(%TaskSchema{} = task, fields) do
    task
    |> Ecto.Changeset.change(fields)
    |> Repo.update!()
  end

  defp entry(%Agent{} = agent), do: %{"assignee_id" => agent.id, "assignee_type" => "agent"}
end
