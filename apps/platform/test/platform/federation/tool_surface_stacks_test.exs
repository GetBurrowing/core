defmodule Platform.Federation.ToolSurfaceStacksTest do
  @moduledoc """
  End-to-end MCP-tool coverage for the stack_* surface (ADR 0041, Task
  Stacks T3 stage 3).

  These tests exercise the stack tools strictly through
  `Platform.Federation.ToolSurface.execute/3` — i.e. as an MCP client
  would. Stage 2's `tool_surface_test.exs` already covers each tool's
  individual happy/error branches in isolation; this file is the
  integration counterpart that drives full lifecycles end-to-end and
  asserts only on response envelopes. `Repo` is used solely for
  fixture setup, never to verify outcomes — the contract under test is
  the MCP surface.

  Stage 3's stack_start cascade is documented in ADR 0041 but is not
  yet wired (T4 will replace the body with `Stacks.start_stack/1`).
  The cascade test asserts current behaviour and carries a TODO(T4).
  """

  use Platform.DataCase, async: false

  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task

  # ADR 0042 sponsor tests: insert a bare user row bypassing the
  # `Platform.Accounts.User.changeset/2` name requirement so tests don't
  # need to plumb an OIDC identity fixture. Mirror of the same helper in
  # `apps/platform/test/platform/tasks/stacks_test.exs`.
  defp insert_sponsor_user(opts \\ []) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: Keyword.get(opts, :name, "Sponsor #{n}"),
      email: Keyword.get(opts, :email, "tool-stack-sponsor-#{n}@example.com"),
      oidc_sub: "sub-tool-stack-sponsor-#{n}"
    })
  end

  # ── Fixtures ───────────────────────────────────────────────────────

  defp create_project(attrs \\ %{}) do
    default = %{name: "Stacks E2E #{System.unique_integer([:positive])}"}
    {:ok, project} = Tasks.create_project(Map.merge(default, attrs))
    project
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Create a stack via the MCP surface and return the stack_id +
  # rollup_branch. Keeps the test bodies focused on the assertion path.
  defp create_stack_via_tool(project_id, slug, name \\ "E2E Stack") do
    {:ok, result} =
      ToolSurface.execute(
        "stack_create",
        %{"project_id" => project_id, "slug" => slug, "name" => name},
        %{}
      )

    result
  end

  # ── Scenarios ──────────────────────────────────────────────────────

  describe "stack_create end-to-end" do
    test "returns {stack_id, rollup_branch} with rollup_branch derived from slug" do
      project = create_project()
      slug = unique_slug("e2e-create")

      {:ok, result} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Created"},
          %{}
        )

      assert is_binary(result.stack_id)
      # rollup_branch derivation is part of the documented contract for
      # this tool (ADR 0041 §branching) — exercised through the MCP
      # response, not by querying the Stacks context directly.
      assert result.rollup_branch == "stack/#{slug}"
      # No sponsor supplied → envelope carries an explicit nil so the
      # caller can render without a follow-up stack_get.
      assert result.sponsor == nil
    end

    # ADR 0042 Decision 8 — sponsor_user_id is threaded into attrs and
    # the return envelope carries a preloaded sponsor map so callers
    # can render immediately without another round-trip.
    test "accepts sponsor_user_id and returns the preloaded sponsor envelope" do
      project = create_project()
      user = insert_sponsor_user(name: "Rowan")
      slug = unique_slug("e2e-create-sponsored")

      {:ok, result} =
        ToolSurface.execute(
          "stack_create",
          %{
            "project_id" => project.id,
            "slug" => slug,
            "name" => "Sponsored",
            "sponsor_user_id" => user.id
          },
          %{}
        )

      assert is_binary(result.stack_id)
      assert result.sponsor == %{id: user.id, name: "Rowan", email: user.email}
    end

    test "returns a sponsor_fk envelope when sponsor_user_id references no user" do
      project = create_project()
      slug = unique_slug("e2e-create-bad-sponsor")

      {:error, error} =
        ToolSurface.execute(
          "stack_create",
          %{
            "project_id" => project.id,
            "slug" => slug,
            "name" => "Bad Sponsor",
            "sponsor_user_id" => Ecto.UUID.generate()
          },
          %{}
        )

      assert error.code == "sponsor_fk"
      assert error.recoverable == true
    end
  end

  # `stack_update` mirrors `task_update` for the stack surface (ADR 0042
  # Decision 8). Sponsor semantics: omit key → leave untouched, pass
  # UUID → set, pass explicit nil → clear.
  describe "stack_update end-to-end" do
    test "sets the sponsor on an unsponsored stack" do
      project = create_project()
      user = insert_sponsor_user(name: "Rowan")

      %{stack_id: stack_id, sponsor: initial_sponsor} =
        create_stack_via_tool(project.id, unique_slug("e2e-upd-set"), "Unsponsored")

      assert initial_sponsor == nil

      {:ok, updated} =
        ToolSurface.execute(
          "stack_update",
          %{"stack_id" => stack_id, "sponsor_user_id" => user.id},
          %{}
        )

      assert updated.id == stack_id
      assert updated.sponsor_user_id == user.id
      assert updated.sponsor == %{id: user.id, name: "Rowan", email: user.email}
    end

    test "clears the sponsor when sponsor_user_id is explicitly null" do
      project = create_project()
      user = insert_sponsor_user()

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{
            "project_id" => project.id,
            "slug" => unique_slug("e2e-upd-clear"),
            "name" => "Has Sponsor",
            "sponsor_user_id" => user.id
          },
          %{}
        )

      {:ok, cleared} =
        ToolSurface.execute(
          "stack_update",
          %{"stack_id" => stack_id, "sponsor_user_id" => nil},
          %{}
        )

      assert cleared.sponsor_user_id == nil
      assert cleared.sponsor == nil
    end

    test "updates name and description without touching sponsor" do
      project = create_project()
      user = insert_sponsor_user(name: "Rowan")

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{
            "project_id" => project.id,
            "slug" => unique_slug("e2e-upd-name"),
            "name" => "Original",
            "sponsor_user_id" => user.id
          },
          %{}
        )

      {:ok, updated} =
        ToolSurface.execute(
          "stack_update",
          %{
            "stack_id" => stack_id,
            "name" => "Renamed",
            "description" => "Now with prose"
          },
          %{}
        )

      assert updated.name == "Renamed"
      assert updated.description == "Now with prose"
      # Sponsor stays put — the key was omitted from args, not passed
      # as nil.
      assert updated.sponsor_user_id == user.id
      assert updated.sponsor.id == user.id
    end

    test "returns sponsor_fk envelope for an unknown sponsor UUID" do
      project = create_project()
      %{stack_id: stack_id} = create_stack_via_tool(project.id, unique_slug("e2e-upd-badfk"))

      {:error, error} =
        ToolSurface.execute(
          "stack_update",
          %{"stack_id" => stack_id, "sponsor_user_id" => Ecto.UUID.generate()},
          %{}
        )

      assert error.code == "sponsor_fk"
      assert error.recoverable == true
    end

    test "returns stack_not_found for a missing stack_id" do
      {:error, error} =
        ToolSurface.execute(
          "stack_update",
          %{"stack_id" => Ecto.UUID.generate(), "name" => "Nope"},
          %{}
        )

      assert error.code == "stack_not_found"
      assert error.recoverable == false
    end

    test "accepts auto_plan and auto_accept_plan and persists them on the stack" do
      project = create_project()
      slug = unique_slug("e2e-auto-flags")

      {:ok, result} =
        ToolSurface.execute(
          "stack_create",
          %{
            "project_id" => project.id,
            "slug" => slug,
            "name" => "Auto Flags",
            "auto_plan" => true,
            "auto_accept_plan" => true
          },
          %{}
        )

      # The MCP tool contract for stack_create returns {stack_id,
      # rollup_branch} only; the two new flags are verified by loading
      # the persisted stack (still through the Stacks context, because
      # stack_get's serialize_stack extension is deferred to stage 6).
      stack = Platform.Tasks.Stacks.get_stack(result.stack_id)
      assert stack.auto_plan == true
      assert stack.auto_accept_plan == true
    end
  end

  describe "stack_add end-to-end" do
    test "accepts a task and reports task_id + stack_id + stack_position" do
      project = create_project()
      %{stack_id: stack_id} = create_stack_via_tool(project.id, unique_slug("e2e-add"))
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Attachable"})

      {:ok, result} =
        ToolSurface.execute(
          "stack_add",
          %{"stack_id" => stack_id, "task_id" => task.id},
          %{}
        )

      assert result.task_id == task.id
      assert result.stack_id == stack_id
      assert result.stack_position == 1
    end

    test "rejects a cycle-creating add with the documented error envelope" do
      project = create_project()
      %{stack_id: stack_id} = create_stack_via_tool(project.id, unique_slug("e2e-cycle"))

      # Two tasks: A is a clean root, B blocks on A. We attach A first
      # so the stack has a member; then we patch A in-place to declare
      # a dep on B (A→B and B→A). Once we attach B, the resulting
      # in-stack DAG is cyclic and `stack_add` must roll back.
      {:ok, task_a} = Tasks.create_task(%{project_id: project.id, title: "A"})

      {:ok, _} =
        ToolSurface.execute(
          "stack_add",
          %{"stack_id" => stack_id, "task_id" => task_a.id},
          %{}
        )

      {:ok, task_b} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "B",
          dependencies: [%{"task_id" => task_a.id, "kind" => "blocks"}]
        })

      # Patch A to point at B *after* it's attached. We can't go through
      # the MCP surface to do this (there's no edge-mutation tool), so
      # this is a fixture step.
      attached_a = Tasks.get_task_record(task_a.id)

      attached_a
      |> Task.changeset(%{
        dependencies: [%{"task_id" => task_b.id, "kind" => "blocks"}]
      })
      |> Repo.update!()

      {:error, error} =
        ToolSurface.execute(
          "stack_add",
          %{"stack_id" => stack_id, "task_id" => task_b.id},
          %{}
        )

      assert error.code == "cycle"
      assert is_binary(error.error)
      assert is_binary(error.suggestion)
      assert is_list(error.path)
      # Both members involved in the cycle must surface in `path` so an
      # operator can diagnose the offending edge.
      path_ids = MapSet.new(error.path)
      assert MapSet.member?(path_ids, task_a.id)
      assert MapSet.member?(path_ids, task_b.id)
    end
  end

  describe "stack_get end-to-end" do
    test "returns the documented shape: stack, members, edges, executable_now, cross_stack_deps" do
      project = create_project()
      slug = unique_slug("e2e-get")
      %{stack_id: stack_id} = create_stack_via_tool(project.id, slug, "Get Shape")

      {:ok, root} = Tasks.create_task(%{project_id: project.id, title: "Root"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => root.id, "kind" => "blocks"}]
        })

      {:ok, _} =
        ToolSurface.execute(
          "stack_add",
          %{"stack_id" => stack_id, "task_id" => root.id},
          %{}
        )

      {:ok, _} =
        ToolSurface.execute(
          "stack_add",
          %{"stack_id" => stack_id, "task_id" => child.id},
          %{}
        )

      {:ok, result} = ToolSurface.execute("stack_get", %{"stack_id" => stack_id}, %{})

      # `stack` sub-map carries the lifecycle fields callers depend on.
      assert result.stack.id == stack_id
      assert result.stack.slug == slug
      assert result.stack.status == "forming"
      assert result.stack.rollup_branch == "stack/#{slug}"
      assert is_binary(result.stack.base_branch)
      assert result.stack.name == "Get Shape"

      # `members` lists each attached task with the in-stack metadata
      # callers need to render a board (status + position + own deps).
      assert length(result.members) == 2
      assert Enum.all?(result.members, &Map.has_key?(&1, :stack_position))
      assert Enum.all?(result.members, &Map.has_key?(&1, :status))
      assert Enum.all?(result.members, &Map.has_key?(&1, :dependencies))

      # `edges` reports the in-stack dep DAG; child → root is the only
      # edge here.
      assert Enum.any?(
               result.edges,
               &(&1.from_task_id == child.id and &1.to_task_id == root.id and &1.kind == "blocks")
             )

      # `executable_now` lists the in-stack roots that have no
      # unsatisfied in-stack deps — the child is blocked by the root.
      assert root.id in result.executable_now
      refute child.id in result.executable_now

      # No cross-stack edges in this scenario.
      assert result.cross_stack_deps == []

      # `members_in_merge_order` is the topological (foundational-first)
      # ordering of member ids: root (level 0) before child (level 1).
      assert result.members_in_merge_order == [root.id, child.id]
    end

    test "surfaces auto_plan and auto_accept_plan on the stack record (stack v2 stage 6)" do
      project = create_project()
      slug = unique_slug("e2e-get-auto-flags")

      # Create with both flags set so we can round-trip through stack_get.
      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{
            "project_id" => project.id,
            "slug" => slug,
            "name" => "Get Flags",
            "auto_plan" => true,
            "auto_accept_plan" => true
          },
          %{}
        )

      {:ok, result} = ToolSurface.execute("stack_get", %{"stack_id" => stack_id}, %{})

      assert result.stack.auto_plan == true
      assert result.stack.auto_accept_plan == true

      # Regression: a stack with defaults (both false) also surfaces both
      # keys — clients relying on `Map.has_key?/2` to detect Stack v2
      # support don't need special-casing.
      default_slug = unique_slug("e2e-get-auto-flags-default")

      %{stack_id: default_stack_id} =
        create_stack_via_tool(project.id, default_slug, "Get Defaults")

      {:ok, default_result} =
        ToolSurface.execute("stack_get", %{"stack_id" => default_stack_id}, %{})

      assert default_result.stack.auto_plan == false
      assert default_result.stack.auto_accept_plan == false
    end

    test "members_in_merge_order falls back to creation order with no declared deps" do
      project = create_project()
      slug = unique_slug("e2e-get-nodep")
      %{stack_id: stack_id} = create_stack_via_tool(project.id, slug, "No Deps")

      {:ok, first} = Tasks.create_task(%{project_id: project.id, title: "First"})
      {:ok, second} = Tasks.create_task(%{project_id: project.id, title: "Second"})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => first.id}, %{})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => second.id}, %{})

      {:ok, result} = ToolSurface.execute("stack_get", %{"stack_id" => stack_id}, %{})

      # No edges → single topological level → stack_position (creation) order.
      assert result.members_in_merge_order == [first.id, second.id]
    end
  end

  describe "stack_list end-to-end" do
    test "filters by project_id and status" do
      project_a = create_project()
      project_b = create_project()

      slug_forming_a = unique_slug("e2e-list-form-a")
      slug_started_a = unique_slug("e2e-list-start-a")
      slug_forming_b = unique_slug("e2e-list-form-b")

      %{stack_id: forming_a_id} =
        create_stack_via_tool(project_a.id, slug_forming_a, "Forming A")

      %{stack_id: started_a_id} =
        create_stack_via_tool(project_a.id, slug_started_a, "Started A")

      %{stack_id: forming_b_id} =
        create_stack_via_tool(project_b.id, slug_forming_b, "Forming B")

      # Promote one of project_a's stacks to in_progress so we can
      # distinguish status filtering from project filtering.
      {:ok, _} =
        ToolSurface.execute("stack_start", %{"stack_id" => started_a_id}, %{})

      # project filter: only project_a's two stacks come back.
      {:ok, project_a_results} =
        ToolSurface.execute("stack_list", %{"project_id" => project_a.id}, %{})

      project_a_ids = Enum.map(project_a_results, & &1.id)
      assert forming_a_id in project_a_ids
      assert started_a_id in project_a_ids
      refute forming_b_id in project_a_ids

      # status filter (combined with project_id): only the in_progress
      # member of project_a comes back.
      {:ok, in_progress_results} =
        ToolSurface.execute(
          "stack_list",
          %{"project_id" => project_a.id, "status" => "in_progress"},
          %{}
        )

      in_progress_ids = Enum.map(in_progress_results, & &1.id)
      assert started_a_id in in_progress_ids
      refute forming_a_id in in_progress_ids
      refute forming_b_id in in_progress_ids
      assert Enum.all?(in_progress_results, &(&1.status == "in_progress"))
    end
  end

  describe "stack_start end-to-end" do
    test "flips a forming stack to in_progress and cascades members (ADR 0041 T4)" do
      project = create_project()

      %{stack_id: stack_id} =
        create_stack_via_tool(project.id, unique_slug("e2e-start"), "Start Me")

      # Two members: a clean root and a child blocked on it. T4 cascade:
      # root → in_progress, child → stack_pending.
      {:ok, root_task} = Tasks.create_task(%{project_id: project.id, title: "Root"})

      {:ok, child_task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => root_task.id, "kind" => "blocks"}]
        })

      # ADR 0042 Decision 4: EVERY member (root AND parked child) needs
      # an approved plan before the commencement gate opens; without it
      # the cascade refuses upfront with `:stack_plans_pending`.
      {:ok, _} = Tasks.create_plan(%{task_id: root_task.id, status: "approved"})
      {:ok, _} = Tasks.create_plan(%{task_id: child_task.id, status: "approved"})

      {:ok, _} =
        ToolSurface.execute(
          "stack_add",
          %{"stack_id" => stack_id, "task_id" => root_task.id},
          %{}
        )

      {:ok, _} =
        ToolSurface.execute(
          "stack_add",
          %{"stack_id" => stack_id, "task_id" => child_task.id},
          %{}
        )

      {:ok, started} =
        ToolSurface.execute("stack_start", %{"stack_id" => stack_id}, %{})

      assert started.status == "in_progress"
      assert started.id == stack_id
      # `started` and `parked` arrays are part of the cascade payload.
      assert is_list(started.started)
      assert is_list(started.parked)

      {:ok, after_start} =
        ToolSurface.execute("stack_get", %{"stack_id" => stack_id}, %{})

      root_member = Enum.find(after_start.members, &(&1.id == root_task.id))
      child_member = Enum.find(after_start.members, &(&1.id == child_task.id))

      assert root_member.status == "in_progress"
      assert child_member.status == "stack_pending"
    end
  end

  describe "stack_start_planning end-to-end" do
    test "cascades every backlog member to planning and round-trips through stack_get" do
      project = create_project()

      %{stack_id: stack_id} =
        create_stack_via_tool(project.id, unique_slug("e2e-start-planning"), "Plan Me")

      {:ok, m1} = Tasks.create_task(%{project_id: project.id, title: "Member 1"})
      {:ok, m2} = Tasks.create_task(%{project_id: project.id, title: "Member 2"})
      {:ok, m3} = Tasks.create_task(%{project_id: project.id, title: "Member 3"})

      for task <- [m1, m2, m3] do
        {:ok, _} =
          ToolSurface.execute(
            "stack_add",
            %{"stack_id" => stack_id, "task_id" => task.id},
            %{}
          )
      end

      {:ok, result} =
        ToolSurface.execute("stack_start_planning", %{"stack_id" => stack_id}, %{})

      assert result.id == stack_id
      # An all-`planning` stack rolls up to `forming` per ADR 0041.
      assert result.status == "forming"
      planning_ids = result.planning |> Enum.map(& &1.id) |> Enum.sort()
      assert planning_ids == Enum.sort([m1.id, m2.id, m3.id])

      # Round-trip: every member now reads `planning` from stack_get.
      {:ok, after_plan} = ToolSurface.execute("stack_get", %{"stack_id" => stack_id}, %{})
      assert Enum.all?(after_plan.members, &(&1.status == "planning"))
    end

    test "re-invocation on an in-flight stack returns a noop envelope (Stack v2)" do
      project = create_project()

      %{stack_id: stack_id} =
        create_stack_via_tool(project.id, unique_slug("e2e-start-planning-mixed"), "Mixed Plan")

      {:ok, backlog_member} = Tasks.create_task(%{project_id: project.id, title: "Backlog"})
      {:ok, ahead_member} = Tasks.create_task(%{project_id: project.id, title: "Already ahead"})

      {:ok, _} =
        ToolSurface.execute(
          "stack_add",
          %{"stack_id" => stack_id, "task_id" => backlog_member.id},
          %{}
        )

      {:ok, _} =
        ToolSurface.execute(
          "stack_add",
          %{"stack_id" => stack_id, "task_id" => ahead_member.id},
          %{}
        )

      # Pre-advance one member past backlog. Under Stack v2's wave-
      # gated dispatch (ADR 0045), any non-backlog member is treated as
      # "planning already kicked off" and the tool returns a noop
      # envelope instead of picking up the remaining backlog member.
      Repo.get!(Task, ahead_member.id)
      |> Task.changeset(%{status: "planning"})
      |> Repo.update!()

      {:ok, result} =
        ToolSurface.execute("stack_start_planning", %{"stack_id" => stack_id}, %{})

      assert result.noop == true
      assert result.noop_reason == :already_in_flight
      assert result.planning == []

      # The pre-advanced member is left at its existing status.
      assert Tasks.get_task_record(ahead_member.id).status == "planning"
      # The backlog member is NOT dragged forward — wave gating owns
      # that transition once ahead_member's plan approves.
      assert Tasks.get_task_record(backlog_member.id).status == "backlog"

      # Second invocation is likewise a noop.
      {:ok, second} =
        ToolSurface.execute("stack_start_planning", %{"stack_id" => stack_id}, %{})

      assert second.noop == true
      assert second.noop_reason == :already_in_flight
    end

    test "returns a not-found error envelope for a missing stack" do
      {:error, error} =
        ToolSurface.execute(
          "stack_start_planning",
          %{"stack_id" => Ecto.UUID.generate()},
          %{}
        )

      assert error.error =~ "Stack not found"
      assert error.recoverable == false
    end

    test "auto_plan stack surfaces mode: :auto and waves_total on the response (stack v2 stage 6)" do
      project = create_project()

      %{stack_id: stack_id} =
        ToolSurface.execute(
          "stack_create",
          %{
            "project_id" => project.id,
            "slug" => unique_slug("e2e-auto-plan-response"),
            "name" => "Auto Response",
            "auto_plan" => true,
            "auto_accept_plan" => true
          },
          %{}
        )
        |> then(fn {:ok, r} -> r end)

      {:ok, m1} = Tasks.create_task(%{project_id: project.id, title: "Auto M1"})
      {:ok, m2} = Tasks.create_task(%{project_id: project.id, title: "Auto M2"})
      {:ok, m3} = Tasks.create_task(%{project_id: project.id, title: "Auto M3"})

      for task <- [m1, m2, m3] do
        {:ok, _} =
          ToolSurface.execute(
            "stack_add",
            %{"stack_id" => stack_id, "task_id" => task.id},
            %{}
          )
      end

      # Chain m3 → m2 → m1 → 3 waves.
      {:ok, _} =
        ToolSurface.execute(
          "stack_add_dependency",
          %{"stack_id" => stack_id, "from_task_id" => m2.id, "to_task_id" => m1.id},
          %{}
        )

      {:ok, _} =
        ToolSurface.execute(
          "stack_add_dependency",
          %{"stack_id" => stack_id, "from_task_id" => m3.id, "to_task_id" => m2.id},
          %{}
        )

      {:ok, result} =
        ToolSurface.execute("stack_start_planning", %{"stack_id" => stack_id}, %{})

      # Stack v2 stage 6 fields on the response envelope.
      assert result.mode == :auto
      assert result.waves_total == 3
      # Auto mode dispatches every wave — all three members hit planning.
      planning_ids = result.planning |> Enum.map(& &1.id) |> Enum.sort()
      assert planning_ids == Enum.sort([m1.id, m2.id, m3.id])

      # Serialized stack record still carries both flags for callers
      # inspecting the envelope in isolation.
      assert result.auto_plan == true
      assert result.auto_accept_plan == true
    end

    test "manual stack surfaces mode: :manual and waves_total on the response" do
      project = create_project()

      %{stack_id: stack_id} =
        create_stack_via_tool(
          project.id,
          unique_slug("e2e-manual-response"),
          "Manual Response"
        )

      {:ok, m1} = Tasks.create_task(%{project_id: project.id, title: "Manual M1"})
      {:ok, m2} = Tasks.create_task(%{project_id: project.id, title: "Manual M2"})

      for task <- [m1, m2] do
        {:ok, _} =
          ToolSurface.execute(
            "stack_add",
            %{"stack_id" => stack_id, "task_id" => task.id},
            %{}
          )
      end

      {:ok, _} =
        ToolSurface.execute(
          "stack_add_dependency",
          %{"stack_id" => stack_id, "from_task_id" => m2.id, "to_task_id" => m1.id},
          %{}
        )

      {:ok, result} =
        ToolSurface.execute("stack_start_planning", %{"stack_id" => stack_id}, %{})

      assert result.mode == :manual
      assert result.waves_total == 2
      # Manual mode dispatches only wave 0 → m1 alone.
      assert result.planning |> Enum.map(& &1.id) == [m1.id]
      assert result.auto_plan == false
      assert result.auto_accept_plan == false
    end
  end

  describe "stack_eject and stack_abandon end-to-end" do
    test "stack_eject detaches a member and returns task_id + stack_id" do
      project = create_project()

      %{stack_id: stack_id} =
        create_stack_via_tool(project.id, unique_slug("e2e-eject"), "Eject Happy")

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Detachable"})

      {:ok, _} =
        ToolSurface.execute(
          "stack_add",
          %{"stack_id" => stack_id, "task_id" => task.id},
          %{}
        )

      {:ok, eject_result} =
        ToolSurface.execute(
          "stack_eject",
          %{"stack_id" => stack_id, "task_id" => task.id},
          %{}
        )

      assert eject_result.task_id == task.id
      assert eject_result.stack_id == stack_id

      # Round-trip through `stack_get`: the ejected task should no
      # longer appear among members.
      {:ok, after_eject} = ToolSurface.execute("stack_get", %{"stack_id" => stack_id}, %{})
      member_ids = Enum.map(after_eject.members, & &1.id)
      refute task.id in member_ids
    end

    test "stack_abandon flips status to abandoned and records reason" do
      project = create_project()

      %{stack_id: stack_id} =
        create_stack_via_tool(project.id, unique_slug("e2e-abandon"), "Abandon Me")

      {:ok, abandon_result} =
        ToolSurface.execute(
          "stack_abandon",
          %{"stack_id" => stack_id, "reason" => "pivoted scope"},
          %{}
        )

      assert abandon_result.status == "abandoned"
      assert abandon_result.id == stack_id
      assert abandon_result.description =~ "pivoted scope"

      # Round-trip: stack_get should reflect the abandoned status.
      {:ok, after_abandon} = ToolSurface.execute("stack_get", %{"stack_id" => stack_id}, %{})
      assert after_abandon.stack.status == "abandoned"
    end
  end

  describe "task_create with stack_id end-to-end" do
    test "persists both the task and its stack membership in one call" do
      project = create_project()

      %{stack_id: stack_id} =
        create_stack_via_tool(project.id, unique_slug("e2e-tc-stack"), "Combined")

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Created and stacked",
            "stack_id" => stack_id
          },
          %{}
        )

      assert is_binary(result.id)
      assert result.title == "Created and stacked"
      assert result.stack_id == stack_id
      assert result.stack_position == 1

      # Round-trip through stack_get: the new task is now a member.
      {:ok, get_result} = ToolSurface.execute("stack_get", %{"stack_id" => stack_id}, %{})
      member_ids = Enum.map(get_result.members, & &1.id)
      assert result.id in member_ids
    end

    test "rejects task_create cleanly when stack_id refers to a missing stack" do
      project = create_project()
      bogus_stack_id = Ecto.UUID.generate()

      {:error, error} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Will fail to attach",
            "stack_id" => bogus_stack_id
          },
          %{}
        )

      # The error envelope must be a stable contract for callers; the
      # add_task -> :stack_not_found leg goes through stack_add's error
      # mapper.
      assert error.error =~ "Stack not found"
      assert error.recoverable == false
    end
  end

  describe "stack_assign_agents end-to-end" do
    test "simple mode assigns one agent to all phases and percolates to members" do
      project = create_project()
      slug = unique_slug("e2e-assign")
      %{stack_id: stack_id} = create_stack_via_tool(project.id, slug)

      {:ok, m1} = Tasks.create_task(%{project_id: project.id, title: "Member 1"})
      {:ok, m2} = Tasks.create_task(%{project_id: project.id, title: "Member 2"})

      {:ok, _} =
        ToolSurface.execute(
          "stack_add",
          %{"stack_id" => stack_id, "task_id" => m1.id},
          %{}
        )

      {:ok, _} =
        ToolSurface.execute(
          "stack_add",
          %{"stack_id" => stack_id, "task_id" => m2.id},
          %{}
        )

      agent = Ecto.UUID.generate()

      {:ok, result} =
        ToolSurface.execute(
          "stack_assign_agents",
          %{"stack_id" => stack_id, "assignee_id" => agent},
          %{}
        )

      assert result.stack_id == stack_id
      assert result.phase_assignees["planning"]["assignee_id"] == agent
      assert result.phase_assignees["execution"]["assignee_id"] == agent
      assert result.phase_assignees["review"]["assignee_id"] == agent
      assert Enum.sort(result.percolated) == Enum.sort([m1.id, m2.id])
      assert result.skipped == []

      # Round-trip through stack_get: stack default + member badges.
      {:ok, get_result} = ToolSurface.execute("stack_get", %{"stack_id" => stack_id}, %{})
      assert get_result.stack.phase_assignees["execution"]["assignee_id"] == agent

      for member <- get_result.members do
        assert member.assignment == "inherited"
        assert member.assignee_id == agent
      end
    end

    test "advanced mode assigns per-phase ids" do
      project = create_project()
      slug = unique_slug("e2e-assign-adv")
      %{stack_id: stack_id} = create_stack_via_tool(project.id, slug)

      planner = Ecto.UUID.generate()
      executor = Ecto.UUID.generate()
      reviewer = Ecto.UUID.generate()

      {:ok, result} =
        ToolSurface.execute(
          "stack_assign_agents",
          %{
            "stack_id" => stack_id,
            "planning" => planner,
            "execution" => executor,
            "review" => reviewer
          },
          %{}
        )

      assert result.phase_assignees["planning"]["assignee_id"] == planner
      assert result.phase_assignees["execution"]["assignee_id"] == executor
      assert result.phase_assignees["review"]["assignee_id"] == reviewer
    end

    test "skips members with an individual override and reports them" do
      project = create_project()
      slug = unique_slug("e2e-assign-skip")
      %{stack_id: stack_id} = create_stack_via_tool(project.id, slug)

      {:ok, m1} = Tasks.create_task(%{project_id: project.id, title: "Inheriting"})
      {:ok, m2} = Tasks.create_task(%{project_id: project.id, title: "Overridden"})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => m1.id}, %{})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => m2.id}, %{})

      # m2 carries an individual override.
      agent_b = Ecto.UUID.generate()
      {:ok, m2} = Tasks.set_phase_assignees(Repo.get!(Task, m2.id), all_phase_attrs(agent_b))

      {:ok, _} =
        Tasks.update_task(m2, %{metadata: Map.put(m2.metadata || %{}, "assignee_override", true)})

      agent_a = Ecto.UUID.generate()

      {:ok, result} =
        ToolSurface.execute(
          "stack_assign_agents",
          %{"stack_id" => stack_id, "assignee_id" => agent_a},
          %{}
        )

      assert result.percolated == [m1.id]
      assert result.skipped == [%{task_id: m2.id, reason: "individual_override"}]

      {:ok, get_result} = ToolSurface.execute("stack_get", %{"stack_id" => stack_id}, %{})
      by_id = Map.new(get_result.members, &{&1.id, &1})
      assert by_id[m1.id].assignment == "inherited"
      assert by_id[m1.id].assignee_id == agent_a
      assert by_id[m2.id].assignment == "override"
      assert by_id[m2.id].assignee_id == agent_b
    end

    test "returns a not-found error envelope for a missing stack" do
      {:error, error} =
        ToolSurface.execute(
          "stack_assign_agents",
          %{"stack_id" => Ecto.UUID.generate(), "assignee_id" => Ecto.UUID.generate()},
          %{}
        )

      assert error.error =~ "Stack not found"
      assert error.recoverable == false
    end
  end

  # Task 019fe762: the commencement gate returns a THREE-tuple
  # `{:error, :stack_plans_pending, %{stack_id, waiting_on}}`. Both MCP
  # entry points that can move a member into `in_progress` used to have
  # no clause for that arity — `task_start`'s `case` raised
  # `CaseClauseError`, `task_update`'s `with/else` raised
  # `WithClauseError`. Both surfaced as a 500: the one message designed
  # to name the blockers was the message that crashed.
  describe "commencement-gate refusal through the MCP surface" do
    # Gated fixture: `subject` holds an approved plan (so it clears
    # `require_approved_plan_for/3` and actually reaches the gate) while
    # `blocker` has none, so `waiting_on` is non-empty.
    defp gated_stack(opts \\ []) do
      project = create_project()

      %{stack_id: stack_id} =
        create_stack_via_tool(project.id, unique_slug("e2e-gate"), "Gated")

      {:ok, subject} = Tasks.create_task(%{project_id: project.id, title: "Subject Member"})
      {:ok, blocker} = Tasks.create_task(%{project_id: project.id, title: "Blocking Member"})

      {:ok, _} = Tasks.create_plan(%{task_id: subject.id, status: "approved"})

      if Keyword.get(opts, :plan_blocker?, false) do
        {:ok, _} = Tasks.create_plan(%{task_id: blocker.id, status: "approved"})
      end

      for task <- [subject, blocker] do
        {:ok, _} =
          ToolSurface.execute(
            "stack_add",
            %{"stack_id" => stack_id, "task_id" => task.id},
            %{}
          )
      end

      %{stack_id: stack_id, subject: Tasks.get_task_record(subject.id), blocker: blocker}
    end

    test "task_start returns a structured error naming the unplanned sibling" do
      %{subject: subject, blocker: blocker} = gated_stack()

      {:error, error} = ToolSurface.execute("task_start", %{"task_id" => subject.id}, %{})

      assert error.recoverable == true
      assert error.error =~ "missing an approved plan"
      # The blocking member is named by BOTH title and id — a bare uuid
      # list forces the caller into another round trip.
      assert error.error =~ blocker.id
      assert error.error =~ "Blocking Member"
      assert error.suggestion =~ "plan_approve"
    end

    test "task_start says the stack has not started when every member IS planned" do
      # `CommencementGate.open?/1` is false whenever the stack row itself
      # is not `in_progress`, and `waiting_on/1` is then `[]`. Rendering
      # the blocker branch here would emit a dangling empty enumeration.
      %{stack_id: stack_id, subject: subject} = gated_stack(plan_blocker?: true)

      {:error, error} = ToolSurface.execute("task_start", %{"task_id" => subject.id}, %{})

      assert error.recoverable == true
      assert error.error =~ "has not started yet"
      assert error.error =~ stack_id
      assert error.suggestion =~ "stack_start"
      refute error.error =~ "missing an approved plan"
      # No dangling enumeration — the blocker phrasing ends in ": " when
      # the list is empty, and that colon-space must not appear at all.
      refute error.error =~ "approved plan: "
    end

    test "task_update(status: in_progress) returns the same envelope, never a raise" do
      %{subject: subject, blocker: blocker} = gated_stack()

      {:error, error} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => subject.id, "status" => "in_progress"},
          %{}
        )

      assert error.recoverable == true
      assert error.error =~ "missing an approved plan"
      assert error.error =~ blocker.id
      assert error.error =~ "Blocking Member"
    end

    # Controls: the new clause must not have swallowed the pre-existing
    # refusals. Assert the DISTINGUISHING substring of each, not merely
    # that an error came back.
    test "task_start still reports :no_approved_plan with its own wording" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Planless"})

      {:error, error} = ToolSurface.execute("task_start", %{"task_id" => task.id}, %{})

      assert error.error =~ "no approved plan exists for task"
      refute error.error =~ "missing an approved plan"
      refute error.error =~ "has not started yet"
    end

    test "task_start still reports :invalid_transition with its own wording" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Finished"})
      {:ok, _} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, task} = Tasks.update_task(task, %{status: "done"})

      {:error, error} = ToolSurface.execute("task_start", %{"task_id" => task.id}, %{})

      assert error.error =~ "Cannot start task from status done"
      refute error.error =~ "missing an approved plan"
      refute error.error =~ "has not started yet"
    end

    test "task_update still reports :no_approved_plan with its own wording" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Planless Update"})

      {:error, error} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "status" => "in_progress"},
          %{}
        )

      assert error.error =~ "has no approved plan and is not a sponsor-bypass candidate"
      refute error.error =~ "missing an approved plan"
      refute error.error =~ "has not started yet"
    end

    test "task_update still reports :invalid_transition with its own wording" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Finished Update"})
      {:ok, _} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, task} = Tasks.update_task(task, %{status: "done"})

      {:error, error} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "status" => "in_progress"},
          %{}
        )

      assert error.error =~ "Invalid status transition from 'done' to 'in_progress'"
      refute error.error =~ "missing an approved plan"
      refute error.error =~ "has not started yet"
    end
  end

  defp all_phase_attrs(agent_id) do
    entry = %{"assignee_id" => agent_id, "assignee_type" => "agent"}
    %{"planning" => entry, "execution" => entry, "review" => entry}
  end
end
