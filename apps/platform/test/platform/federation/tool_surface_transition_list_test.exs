defmodule Platform.Federation.ToolSurfaceTransitionListTest do
  @moduledoc """
  Tests for `task_transition_list` — the read-back MCP surface over
  `task_phase_transitions`.

  This tool is a READ ONLY. The rows already exist and are already trustworthy:
  `Platform.Tasks.Task`'s changeset ends with
  `prepare_changes(&record_status_transition/1)`, so each row is written inside
  the same `Repo` transaction as the status change it describes. No second
  writer is added anywhere, which is why there is no test here asserting that a
  call to this tool records something — it must not.

  It lives in the `task` bundle: anything able to MOVE a task may read why it
  moved (ADR 0034, and the `01a00570` precedent for review reads).

  ## What these tests actually exercise

  Every assertion is on `ToolSurface.execute/3` OUTPUT, never on the
  registration map. On task `01a00570` a registration that read correctly while
  the call itself failed was the entire failure mode; a test that only asserts
  the tool is listed would have passed through it.

  Three behaviours are pinned:

    * a task with a recorded transition returns `from_status`, `to_status`,
      `occurred_at` and `actor_kind` — from a transition made by really
      updating the task, not by inserting a row by hand;

    * a tenant-pinned agent from a SIBLING org is denied, and the denial body
      carries none of the transition prose. Authorization runs BEFORE
      serialization, so the refutes scan the whole envelope rather than the
      `error` string — that is the only thing that catches an
      authorize-after-serialize mutation;

    * a zero-row task returns `count: 0` PLUS an explicit note saying the task
      predates the instrumentation. A bare `[]` reads as "nothing happened",
      and that confusion is the exact error class this tool exists to close.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Agents.Agent
  alias Platform.Federation.{ToolAuthorization, ToolSurface}
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy

  setup do
    acme = ensure_root_org()
    globex = ensure_tenant_org("globex-transitions-#{u()}", acme)
    vandelay_ind = ensure_tenant_org("vandelay-ind-transitions-#{u()}", acme)

    {:ok, project} = Tasks.create_project(%{name: "Transitions Proj #{u()}", org_id: globex.id})

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Moved Task"})
    # A real status change through the real changeset — this is what writes the
    # row. Inserting a PhaseTransition directly would test the serializer while
    # leaving the actual write path unexercised.
    {:ok, task} = Tasks.update_task(task, %{status: "planning"})

    {:ok, quiet_task} = Tasks.create_task(%{project_id: project.id, title: "Never Moved"})

    %{
      task: task,
      quiet_task: quiet_task,
      agent_globex: create_agent("globex-agent", %{"org_id" => globex.id}),
      agent_pt: create_agent("pt-agent", %{"org_id" => vandelay_ind.id}),
      agent_root: create_agent("root-agent", %{"org_id" => acme.id})
    }
  end

  describe "registration" do
    test "is registered under the task bundle and nowhere else" do
      names = ToolSurface.list_tools(["task"]) |> MapSet.new(& &1.name)
      assert "task_transition_list" in names

      others = ~w(canvas messaging plan review space context_read federation memory
                  skill attachment files)

      for bundle <- others do
        bundle_names = ToolSurface.list_tools([bundle]) |> MapSet.new(& &1.name)
        refute "task_transition_list" in bundle_names, "leaked into the #{bundle} bundle"
      end
    end

    test "a runtime holding the task bundle may call it; one without may not" do
      assert ToolAuthorization.authorize(
               "task_transition_list",
               Platform.RuntimeProfileFixtures.runtime!(root_admin!().id, ["task"])
             ) == :ok

      assert ToolAuthorization.authorize(
               "task_transition_list",
               Platform.RuntimeProfileFixtures.runtime!(root_admin!().id, ["plan", "review"])
             ) == {:error, :forbidden}
    end
  end

  describe "execute/3 happy path" do
    test "a recorded transition comes back with from/to, occurred_at and actor_kind", ctx do
      assert {:ok, result} =
               ToolSurface.execute(
                 "task_transition_list",
                 %{"task_id" => ctx.task.id},
                 context_for(ctx.agent_globex)
               )

      assert result.task_id == ctx.task.id
      assert result.count == 1
      assert [transition] = result.transitions
      assert transition.from_status == "backlog"
      assert transition.to_status == "planning"
      assert %DateTime{} = transition.occurred_at
      assert transition.actor_kind in ~w(user agent system unknown)
      assert Map.has_key?(transition, :actor_id)
      assert Map.has_key?(transition, :actor_label)
      assert Map.has_key?(transition, :via)
    end

    test "transitions are returned oldest first", ctx do
      {:ok, task} = Tasks.update_task(ctx.task, %{status: "in_progress"})
      {:ok, _} = Tasks.update_task(task, %{status: "in_review"})

      assert {:ok, result} =
               ToolSurface.execute(
                 "task_transition_list",
                 %{"task_id" => ctx.task.id},
                 context_for(ctx.agent_globex)
               )

      assert result.count == 3
      assert Enum.map(result.transitions, & &1.to_status) == ~w(planning in_progress in_review)
    end

    test "root-pinned agent reads a tenant task", ctx do
      assert {:ok, result} =
               ToolSurface.execute(
                 "task_transition_list",
                 %{"task_id" => ctx.task.id},
                 context_for(ctx.agent_root)
               )

      assert result.count == 1
    end

    test "agentless context permits — bare-call convention", ctx do
      assert {:ok, result} =
               ToolSurface.execute("task_transition_list", %{"task_id" => ctx.task.id}, %{})

      assert result.count == 1
    end
  end

  describe "zero rows is not zero data" do
    test "a task with no rows returns count 0 and says it predates instrumentation", ctx do
      assert {:ok, result} =
               ToolSurface.execute(
                 "task_transition_list",
                 %{"task_id" => ctx.quiet_task.id},
                 context_for(ctx.agent_globex)
               )

      assert result.count == 0
      assert result.transitions == []

      # The note is the whole point: `transitions: []` on its own reads as
      # "this task never changed status", which is a different claim.
      assert is_binary(result.note)
      assert result.note =~ "predates"
      refute result.note == ""
    end

    test "the note distinguishes the populated case from the empty one", ctx do
      {:ok, populated} =
        ToolSurface.execute(
          "task_transition_list",
          %{"task_id" => ctx.task.id},
          context_for(ctx.agent_globex)
        )

      {:ok, empty} =
        ToolSurface.execute(
          "task_transition_list",
          %{"task_id" => ctx.quiet_task.id},
          context_for(ctx.agent_globex)
        )

      refute populated.note == empty.note
      refute populated.note =~ "predates"
    end
  end

  describe "authorization" do
    test "sibling-org agent is denied and the denial leaks no transition prose", ctx do
      assert {:error, envelope} =
               ToolSurface.execute(
                 "task_transition_list",
                 %{"task_id" => ctx.task.id},
                 context_for(ctx.agent_pt)
               )

      assert envelope.recoverable == false
      assert envelope.error =~ "unauthorized"

      # Scan the WHOLE envelope, not just `error` — narrowing this would let an
      # authorize-after-serialize mutation pass while the leak persisted.
      blob = inspect(envelope)
      refute blob =~ "planning"
      refute blob =~ "backlog"
      refute blob =~ "occurred_at"
      refute blob =~ "actor_kind"
      refute Map.has_key?(envelope, :transitions)
      refute Map.has_key?(envelope, :count)
    end

    test "an unresolvable task is a refusal, not a permit", ctx do
      assert {:error, envelope} =
               ToolSurface.execute(
                 "task_transition_list",
                 %{"task_id" => Ecto.UUID.generate()},
                 context_for(ctx.agent_globex)
               )

      assert envelope.recoverable == false
    end

    # Without this, a call naming no task at all would fall through to
    # `list_for_task(nil)` and return the zero-row "predates instrumentation"
    # shape — a confident answer about a task the caller never identified.
    test "an absent task_id is refused, not answered with the zero-row shape", ctx do
      assert {:error, envelope} =
               ToolSurface.execute("task_transition_list", %{}, context_for(ctx.agent_globex))

      assert envelope.error =~ "task_id"
      refute Map.has_key?(envelope, :count)
      refute Map.has_key?(envelope, :note)
    end

    test "a malformed task id is refused rather than raising", ctx do
      assert {:error, envelope} =
               ToolSurface.execute(
                 "task_transition_list",
                 %{"task_id" => "not-a-uuid"},
                 context_for(ctx.agent_globex)
               )

      assert envelope.recoverable == false
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp u, do: System.unique_integer([:positive])

  defp ensure_root_org do
    case Repo.get_by(Tenancy.Org, slug: "acme") do
      nil ->
        {:ok, org} =
          %Tenancy.Org{}
          |> Tenancy.Org.changeset(%{slug: "acme", name: "Acme", parent_org_id: nil})
          |> Repo.insert()

        org

      org ->
        org
    end
  end

  defp ensure_tenant_org(slug, root) do
    {:ok, org} =
      %Tenancy.Org{}
      |> Tenancy.Org.changeset(%{slug: slug, name: slug, parent_org_id: root.id})
      |> Repo.insert()

    org
  end

  defp create_agent(slug_prefix, metadata) do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "#{slug_prefix}-#{System.unique_integer([:positive, :monotonic])}",
        name: String.capitalize(slug_prefix),
        status: "active",
        metadata: metadata
      })
      |> Repo.insert()

    agent
  end

  defp context_for(%Agent{id: id}), do: %{agent_id: id}
end
