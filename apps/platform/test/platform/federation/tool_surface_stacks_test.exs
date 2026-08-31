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

      # `executable_now` is status-aware (01a05394-8300 stage 2): both
      # members are still `backlog` in a `forming` stack, so neither is
      # runnable now — they sit in `blocked_now`, and the member entries
      # say WHY: the root has no unmet deps, the child is behind the root.
      assert result.executable_now == []
      assert Enum.sort(result.blocked_now) == Enum.sort([root.id, child.id])
      assert Enum.find(result.members, &(&1.id == root.id)).blocked_by == []
      assert Enum.find(result.members, &(&1.id == child.id)).blocked_by == [root.id]

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

      # project filter: only project_a's two stacks come back. Task
      # 01a05394-8300 stage 4: the result is an envelope, and `total` is a
      # count over the same filters, so it is 2 here regardless of
      # project_b's stack.
      {:ok, %{stacks: project_a_results, total: 2, has_more: false}} =
        ToolSurface.execute("stack_list", %{"project_id" => project_a.id}, %{})

      project_a_ids = Enum.map(project_a_results, & &1.id)
      assert forming_a_id in project_a_ids
      assert started_a_id in project_a_ids
      refute forming_b_id in project_a_ids

      # status filter (combined with project_id): only the in_progress
      # member of project_a comes back — and `total` narrows with it.
      {:ok, %{stacks: in_progress_results, total: 1, has_more: false}} =
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

    # Task 01a05394-8300 stage 4 — pagination envelope, mirroring task_list.
    # Every fixture below is scoped to a project the test owns, and `total`
    # is asserted over that same filter, so stacks other tests leave in the
    # shared database cannot move the numbers.
    test "has_more is a fact from a real count, not a restatement of the page size" do
      project = create_project()

      ids =
        for i <- 1..3 do
          %{stack_id: id} =
            create_stack_via_tool(project.id, unique_slug("e2e-page-#{i}"), "Page #{i}")

          id
        end

      # More stacks than the limit: a full page, and has_more says so.
      {:ok, over} =
        ToolSurface.execute("stack_list", %{"project_id" => project.id, "limit" => 2}, %{})

      assert over.total == 3
      assert over.limit == 2
      assert over.offset == 0
      assert length(over.stacks) == 2
      assert over.total > length(over.stacks)
      assert over.has_more == true

      # PAIRED: a corpus of EXACTLY `limit`. This is the boundary where
      # `length(rows) == limit` lies — the page is full, and there is no more.
      {:ok, exact} =
        ToolSurface.execute("stack_list", %{"project_id" => project.id, "limit" => 3}, %{})

      assert exact.total == 3
      assert length(exact.stacks) == 3
      assert exact.has_more == false

      # Paging is total and stable: two consecutive pages neither skip nor
      # repeat an id, and their concatenation IS the unpaged order.
      {:ok, page_2} =
        ToolSurface.execute(
          "stack_list",
          %{"project_id" => project.id, "limit" => 2, "offset" => 2},
          %{}
        )

      assert page_2.offset == 2
      assert page_2.total == 3
      assert length(page_2.stacks) == 1
      assert page_2.has_more == false

      paged_ids = Enum.map(over.stacks ++ page_2.stacks, & &1.id)
      unpaged_ids = Enum.map(exact.stacks, & &1.id)

      assert paged_ids == unpaged_ids
      assert Enum.sort(paged_ids) == Enum.sort(ids)
      assert Enum.uniq(paged_ids) == paged_ids

      # The tool order is the context order (inserted_at desc, id desc), so
      # the third-created stack leads.
      assert hd(unpaged_ids) == List.last(ids)

      # An empty page past the end is still a well-formed envelope.
      {:ok, past} =
        ToolSurface.execute(
          "stack_list",
          %{"project_id" => project.id, "limit" => 2, "offset" => 3},
          %{}
        )

      assert past.stacks == []
      assert past.total == 3
      assert past.has_more == false
    end

    test "description is a visible preview: truncated flag + original length, intact when short" do
      alias Platform.Federation.ResultBound
      alias Platform.Tasks.Stack

      project = create_project()
      chars = ResultBound.snippet_chars()

      %{stack_id: long_id} =
        create_stack_via_tool(project.id, unique_slug("e2e-desc-long"), "Long")

      %{stack_id: short_id} =
        create_stack_via_tool(project.id, unique_slug("e2e-desc-short"), "Short")

      long_description = String.duplicate("x", chars) <> String.duplicate("y", 137)
      short_description = "a short description"

      Repo.update!(
        Ecto.Changeset.change(Repo.get!(Stack, long_id), description: long_description)
      )

      Repo.update!(
        Ecto.Changeset.change(Repo.get!(Stack, short_id), description: short_description)
      )

      {:ok, %{stacks: rows}} =
        ToolSurface.execute("stack_list", %{"project_id" => project.id}, %{})

      long_row = Enum.find(rows, &(&1.id == long_id))
      short_row = Enum.find(rows, &(&1.id == short_id))

      assert long_row.description_truncated == true
      assert long_row.description_length == byte_size(long_description)
      assert long_row.description == String.duplicate("x", chars)
      assert byte_size(long_row.description) < byte_size(long_description)

      # PAIRED positive control: a short description comes back whole.
      assert short_row.description_truncated == false
      assert short_row.description_length == byte_size(short_description)
      assert short_row.description == short_description
    end

    test "rows are identity + state: stack_get's sub-records are dropped by exact key" do
      alias Platform.Tasks.Stack

      project = create_project()

      %{stack_id: stack_id, rollup_branch: rollup_branch} =
        create_stack_via_tool(project.id, unique_slug("e2e-row-shape"), "Row Shape")

      # Stamp a rollup_pr so the curated sub-map is exercised, not just nil.
      stack = Repo.get!(Stack, stack_id)

      Repo.update!(
        Ecto.Changeset.change(stack,
          metadata:
            Map.merge(stack.metadata || %{}, %{
              "rollup_pr" => %{
                "number" => 42,
                "url" => "https://github.com/example/core/pull/42",
                "opened_at" => "2026-08-30T00:00:00Z",
                "auto_merge_armed" => true,
                "extra_writer_key" => "must not leak"
              }
            })
        )
      )

      {:ok, %{stacks: [row]}} =
        ToolSurface.execute("stack_list", %{"project_id" => project.id}, %{})

      assert row.id == stack_id
      assert row.rollup_branch == rollup_branch
      assert row.project_id == project.id
      assert row.status == "forming"

      assert row.rollup_pr == %{
               status: nil,
               number: 42,
               url: "https://github.com/example/core/pull/42",
               merged_at: nil,
               auto_merge_armed: true
             }

      assert row.rollup_branch_ready == nil

      # The exact key set. A revert of the row serializer to
      # `serialize_stack/1` adds `phase_assignees`, `sponsor`,
      # `sponsor_user_id`, `auto_plan` and `auto_accept_plan`, and the
      # `stack_get` envelope additionally carries `members`; none belong on a
      # list row.
      assert Map.keys(row) |> Enum.sort() ==
               Enum.sort([
                 :id,
                 :slug,
                 :name,
                 :status,
                 :rollup_branch,
                 :base_branch,
                 :description,
                 :description_truncated,
                 :description_length,
                 :project_id,
                 :epic_id,
                 :rollup_branch_ready,
                 :rollup_pr,
                 :inserted_at,
                 :updated_at
               ])

      for dropped <- [
            :members,
            :phase_assignees,
            :sponsor,
            :sponsor_user_id,
            :auto_plan,
            :auto_accept_plan,
            :metadata
          ] do
        refute Map.has_key?(row, dropped), "list row must not carry #{inspect(dropped)}"
      end

      # And the same stack through `stack_get` DOES carry what the row drops,
      # so the refutes above are about the row, not about the data.
      {:ok, %{stack: full}} = ToolSurface.execute("stack_get", %{"stack_id" => stack_id}, %{})
      assert Map.has_key?(full, :phase_assignees)
      assert Map.has_key?(full, :auto_plan)
      refute Map.has_key?(full, :description_truncated)
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

    # Task 01a05394 stage 5: the refusal says WHY each member is waiting
    # (`CommencementGate.waiting_detail/1`), not just which member.
    test "refusal names each waiting member with its title, id, and human reason" do
      project = create_project()

      %{stack_id: stack_id} =
        create_stack_via_tool(project.id, unique_slug("e2e-start-why"), "Why Waiting")

      pa = %{
        "planning" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
      }

      {:ok, orphan} = Tasks.create_task(%{project_id: project.id, title: "Orphan Member"})

      {:ok, pending} =
        Tasks.create_task(%{project_id: project.id, title: "Pending Member", phase_assignees: pa})

      {:ok, planless} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Planless Member",
          phase_assignees: pa
        })

      {:ok, _} = Tasks.create_plan(%{task_id: pending.id, status: "pending_review"})

      for task <- [orphan, pending, planless] do
        {:ok, _} =
          ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => task.id}, %{})
      end

      # Anti-vacuity: the orphan has no planner from any source.
      orphan = Tasks.get_task_record(orphan.id)
      stack = Platform.Tasks.Stacks.get_stack(stack_id)
      assert get_in(orphan.phase_assignees || %{}, ["planning"]) == nil
      assert orphan.assignee_id == nil
      assert get_in(stack.metadata || %{}, ["phase_assignees", "planning"]) == nil

      {:error, error} = ToolSurface.execute("stack_start", %{"stack_id" => stack_id}, %{})

      assert error.recoverable == true
      assert error.error =~ "missing an approved plan: "

      orphan_text = "Orphan Member (#{orphan.id}) — no planner assigned"
      pending_text = "Pending Member (#{pending.id}) — plan pending review"
      planless_text = "Planless Member (#{planless.id}) — no plan yet"

      assert error.error =~ orphan_text
      assert error.error =~ pending_text
      assert error.error =~ planless_text

      # Each reason is attached to ITS member: exactly one of each phrase,
      # and in stack_position order.
      [_, tail] = String.split(error.error, "missing an approved plan: ", parts: 2)
      assert String.split(tail, ", ") == [orphan_text, pending_text, planless_text]
    end
  end

  describe "stack_start_planning end-to-end" do
    test "cascades every backlog member to planning and round-trips through stack_get" do
      project = create_project()

      %{stack_id: stack_id} =
        create_stack_via_tool(project.id, unique_slug("e2e-start-planning"), "Plan Me")

      # Manual mode refuses members with no dispatchable planning assignee
      # (Stacks.dispatchable_planning_assignee?/2), so give each a planner.
      {:ok, m1} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Member 1",
          phase_assignees: %{
            "planning" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
          }
        })

      {:ok, m2} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Member 2",
          phase_assignees: %{
            "planning" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
          }
        })

      {:ok, m3} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Member 3",
          phase_assignees: %{
            "planning" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
          }
        })

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

      # Auto mode refuses members with no dispatchable planning assignee
      # (Stacks.dispatchable_planning_assignee?/2), so give each a
      # planner agent — otherwise they surface under `unassigned:`.
      pa = %{
        "planning" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
      }

      {:ok, m1} =
        Tasks.create_task(%{project_id: project.id, title: "Auto M1", phase_assignees: pa})

      {:ok, m2} =
        Tasks.create_task(%{project_id: project.id, title: "Auto M2", phase_assignees: pa})

      {:ok, m3} =
        Tasks.create_task(%{project_id: project.id, title: "Auto M3", phase_assignees: pa})

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

      {:ok, m1} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Manual M1",
          phase_assignees: %{
            "planning" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
          }
        })

      {:ok, m2} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Manual M2",
          phase_assignees: %{
            "planning" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
          }
        })

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

    # Task 01a05394 stage 4: the envelope must report a member with no
    # resolvable planner under `unassigned`, never under `planning` — the
    # bug was precisely that the report and the DB disagreed. Asserts on
    # the RETURNED payload first; DB state is a secondary check.
    test "mixed stack: unresolvable member lands in `unassigned`, assigned member in `planning` with assignee_id" do
      project = create_project()

      %{stack_id: stack_id} =
        create_stack_via_tool(project.id, unique_slug("e2e-mixed-assignee"), "Mixed Assignees")

      planner_id = Ecto.UUID.generate()

      {:ok, assigned} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Has planner",
          phase_assignees: %{
            "planning" => %{"assignee_id" => planner_id, "assignee_type" => "agent"}
          }
        })

      {:ok, orphan} = Tasks.create_task(%{project_id: project.id, title: "No planner"})

      for task <- [assigned, orphan] do
        {:ok, _} =
          ToolSurface.execute(
            "stack_add",
            %{"stack_id" => stack_id, "task_id" => task.id},
            %{}
          )
      end

      # Anti-vacuity: the orphan really has nothing to resolve from —
      # nil per-phase entry, nil top-level assignee, and no stack-level
      # planning default (stack_add must not have percolated one).
      orphan = Tasks.get_task_record(orphan.id)
      stack = Platform.Tasks.Stacks.get_stack(stack_id)
      assert get_in(orphan.phase_assignees || %{}, ["planning"]) == nil
      assert orphan.assignee_id == nil
      assert get_in(stack.metadata || %{}, ["phase_assignees", "planning"]) == nil
      assert Platform.Tasks.Stacks.resolve_planning_assignee(orphan, stack) == {nil, nil}
      # ...and the assigned member really does resolve, so a change that
      # refuses everything cannot pass this test.
      assert Platform.Tasks.Stacks.dispatchable_planning_assignee?(
               Tasks.get_task_record(assigned.id),
               stack
             )

      {:ok, result} =
        ToolSurface.execute("stack_start_planning", %{"stack_id" => stack_id}, %{})

      planning_ids = Enum.map(result.planning, & &1.id)
      unassigned_ids = Enum.map(result.unassigned, & &1.id)

      # Exactly one member each side, and the orphan is nowhere in `planning`.
      assert planning_ids == [assigned.id]
      assert unassigned_ids == [orphan.id]
      refute orphan.id in planning_ids

      [planning_entry] = result.planning
      assert planning_entry.status == "planning"
      assert planning_entry.assignee_id == planner_id
      assert planning_entry.assignee_type == "agent"

      [unassigned_entry] = result.unassigned
      assert unassigned_entry.status == "backlog"
      assert unassigned_entry.assignee_id == nil

      # DB agrees with the envelope: the orphan was not moved.
      assert Tasks.get_task_record(orphan.id).status == "backlog"
      assert Tasks.get_task_record(assigned.id).status == "planning"
    end

    # Control for the key contract: an all-assigned stack still carries
    # `unassigned`, as `[]`, so a caller can distinguish "none unassigned"
    # from an older server that never emitted the key.
    test "all-assigned stack returns `unassigned: []` with the key present" do
      project = create_project()

      %{stack_id: stack_id} =
        create_stack_via_tool(project.id, unique_slug("e2e-all-assigned"), "All Assigned")

      pa = %{
        "planning" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
      }

      {:ok, m1} =
        Tasks.create_task(%{project_id: project.id, title: "A1", phase_assignees: pa})

      {:ok, m2} =
        Tasks.create_task(%{project_id: project.id, title: "A2", phase_assignees: pa})

      for task <- [m1, m2] do
        {:ok, _} =
          ToolSurface.execute(
            "stack_add",
            %{"stack_id" => stack_id, "task_id" => task.id},
            %{}
          )
      end

      {:ok, result} =
        ToolSurface.execute("stack_start_planning", %{"stack_id" => stack_id}, %{})

      assert Map.has_key?(result, :unassigned)
      assert result.unassigned == []
      assert result.planning |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([m1.id, m2.id])
    end
  end

  describe "stack_add_dependency / stack_remove_dependency after start (defect C)" do
    # Started stack: in_progress, every member with an approved plan, P at
    # in_progress, DEP parked at stack_pending behind P.
    defp seed_started_stack_via_tool do
      project = create_project()
      %{stack_id: stack_id} = create_stack_via_tool(project.id, unique_slug("e2e-defect-c"))

      {:ok, p} = Tasks.create_task(%{project_id: project.id, title: "P"})
      {:ok, dep} = Tasks.create_task(%{project_id: project.id, title: "DEP"})

      for task <- [p, dep] do
        {:ok, _} =
          ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => task.id}, %{})

        {:ok, _} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      end

      {:ok, _} =
        ToolSurface.execute(
          "stack_add_dependency",
          %{"stack_id" => stack_id, "from_task_id" => dep.id, "to_task_id" => p.id},
          %{}
        )

      Platform.Tasks.Stack
      |> Repo.get!(stack_id)
      |> Ecto.Changeset.change(status: "in_progress")
      |> Repo.update!()

      Repo.get!(Task, p.id) |> Task.changeset(%{status: "in_progress"}) |> Repo.update!()
      Repo.get!(Task, dep.id) |> Task.changeset(%{status: "stack_pending"}) |> Repo.update!()

      %{stack_id: stack_id, p: p, dep: dep}
    end

    test "stack_add_dependency on an in_progress dependent returns a named envelope, not a crash" do
      %{stack_id: stack_id, p: p, dep: dep} = seed_started_stack_via_tool()

      assert {:error, envelope} =
               ToolSurface.execute(
                 "stack_add_dependency",
                 %{"stack_id" => stack_id, "from_task_id" => p.id, "to_task_id" => dep.id},
                 %{}
               )

      assert envelope.code == "dependent_already_started"
      assert envelope.task_id == p.id
      assert envelope.status == "in_progress"
      assert Tasks.dependency_task_ids(Repo.get!(Task, p.id)) == []
    end

    test "stack_remove_dependency names the member it promoted" do
      %{stack_id: stack_id, p: p, dep: dep} = seed_started_stack_via_tool()
      assert Repo.get!(Task, dep.id).status == "stack_pending"

      assert {:ok, result} =
               ToolSurface.execute(
                 "stack_remove_dependency",
                 %{"stack_id" => stack_id, "from_task_id" => dep.id, "to_task_id" => p.id},
                 %{}
               )

      assert result.promoted == [dep.id]
      assert Repo.get!(Task, dep.id).status == "in_progress"
    end
  end

  describe "stack_add after start parks the member and warns (defect A, part 1)" do
    alias Platform.Tasks.Stacks.CommencementGate

    # Started stack with an OPEN gate: one member with an approved plan,
    # stack and member at in_progress.
    defp seed_open_stack_via_tool do
      project = create_project()
      %{stack_id: stack_id} = create_stack_via_tool(project.id, unique_slug("e2e-defect-a"))

      {:ok, p} = Tasks.create_task(%{project_id: project.id, title: "P"})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => p.id}, %{})

      {:ok, _} = Tasks.create_plan(%{task_id: p.id, status: "approved"})

      Platform.Tasks.Stack
      |> Repo.get!(stack_id)
      |> Ecto.Changeset.change(status: "in_progress")
      |> Repo.update!()

      Repo.get!(Task, p.id) |> Task.changeset(%{status: "in_progress"}) |> Repo.update!()

      {:ok, newcomer} = Tasks.create_task(%{project_id: project.id, title: "Late joiner"})

      %{stack_id: stack_id, p: p, newcomer: newcomer}
    end

    test "stack_add on a started stack returns status, warning, gate_closed and waiting_on" do
      %{stack_id: stack_id, p: p, newcomer: newcomer} = seed_open_stack_via_tool()

      assert CommencementGate.open?(Repo.get!(Task, p.id))

      assert {:ok, result} =
               ToolSurface.execute(
                 "stack_add",
                 %{"stack_id" => stack_id, "task_id" => newcomer.id},
                 %{}
               )

      assert result.task_id == newcomer.id
      assert result.stack_id == stack_id
      assert result.status == "stack_pending"
      assert result.gate_closed == true
      assert result.waiting_on == [newcomer.id]
      assert result.warning =~ "commencement gate"
      assert result.warning =~ "CommencementGate.waiting_on/1"

      assert Repo.get!(Task, newcomer.id).status == "stack_pending"
      refute CommencementGate.open?(Repo.get!(Task, p.id))
    end

    test "stack_add on a forming stack carries no warning and gate_closed false" do
      project = create_project()
      %{stack_id: stack_id} = create_stack_via_tool(project.id, unique_slug("e2e-forming"))
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Early joiner"})

      assert {:ok, result} =
               ToolSurface.execute(
                 "stack_add",
                 %{"stack_id" => stack_id, "task_id" => task.id},
                 %{}
               )

      assert result.status == "backlog"
      assert result.warning == nil
      assert result.gate_closed == false
      assert result.waiting_on == []
    end

    test "stack_add on an abandoned stack returns the stack_terminal envelope" do
      %{stack_id: stack_id, newcomer: newcomer} = seed_open_stack_via_tool()

      Platform.Tasks.Stack
      |> Repo.get!(stack_id)
      |> Ecto.Changeset.change(status: "abandoned")
      |> Repo.update!()

      assert {:error, envelope} =
               ToolSurface.execute(
                 "stack_add",
                 %{"stack_id" => stack_id, "task_id" => newcomer.id},
                 %{}
               )

      assert envelope.code == "stack_terminal"
      assert envelope.stack_status == "abandoned"
      assert envelope.recoverable == false
      assert Repo.get!(Task, newcomer.id).stack_id == nil
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

  describe "stack_eject status handling" do
    # Fixture-only status write (Repo for setup, envelopes for outcomes).
    # `create_task/1` defaults to `backlog`; the excluded `stack_pending`
    # state is seeded explicitly and asserted before the eject so the
    # "no longer stack_pending" refute cannot pass vacuously.
    defp seed_member!(project, stack_id, status, position) do
      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Eject member #{status}"})

      {:ok, task} =
        Tasks.update_task(task, %{stack_id: stack_id, stack_position: position, status: status})

      assert task.status == status
      assert task.stack_id == stack_id
      task
    end

    setup do
      project = create_project()

      %{stack_id: stack_id} =
        create_stack_via_tool(project.id, unique_slug("e2e-eject-status"), "Eject Status")

      pending = seed_member!(project, stack_id, "stack_pending", 1)
      wip = seed_member!(project, stack_id, "in_progress", 2)

      %{project: project, stack_id: stack_id, pending: pending, wip: wip}
    end

    test "stack_eject returns a stack_pending member to backlog", ctx do
      {:ok, result} =
        ToolSurface.execute(
          "stack_eject",
          %{"stack_id" => ctx.stack_id, "task_id" => ctx.pending.id},
          %{}
        )

      assert result.task_id == ctx.pending.id

      ejected = Platform.Repo.get!(Platform.Tasks.Task, ctx.pending.id)
      assert ejected.status == "backlog"
      refute ejected.status == "stack_pending"
      assert ejected.stack_id == nil
    end

    test "control: stack_eject leaves an in_progress member at in_progress", ctx do
      {:ok, _result} =
        ToolSurface.execute(
          "stack_eject",
          %{"stack_id" => ctx.stack_id, "task_id" => ctx.wip.id},
          %{}
        )

      ejected = Platform.Repo.get!(Platform.Tasks.Task, ctx.wip.id)
      assert ejected.status == "in_progress"
      refute ejected.status == "backlog"
      assert ejected.stack_id == nil

      # Sibling untouched: still parked and still a member.
      sibling = Platform.Repo.get!(Platform.Tasks.Task, ctx.pending.id)
      assert sibling.status == "stack_pending"
      assert sibling.stack_id == ctx.stack_id
    end

    test "task_start succeeds on the ejected member", ctx do
      {:ok, _plan} = Tasks.create_plan(%{task_id: ctx.pending.id, status: "approved"})

      {:ok, _} =
        ToolSurface.execute(
          "stack_eject",
          %{"stack_id" => ctx.stack_id, "task_id" => ctx.pending.id},
          %{}
        )

      assert {:ok, started} =
               ToolSurface.execute("task_start", %{"task_id" => ctx.pending.id}, %{})

      assert started.status == "in_progress"
      refute Platform.Repo.get!(Platform.Tasks.Task, ctx.pending.id).status == "stack_pending"
    end
  end

  describe "terminal-transition refusals through the MCP surface" do
    # Fixture-only status write; the moduledoc rule stands (Repo for setup,
    # envelopes for outcomes).
    defp force_stack_status!(stack_id, status) do
      {:ok, stack} =
        stack_id
        |> Platform.Tasks.Stacks.get_stack()
        |> Platform.Tasks.Stacks.update_stack(%{status: status})

      stack
    end

    defp attach_member!(project, stack_id, status) do
      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Member #{status}", status: status})

      {:ok, task} = Tasks.update_task(task, %{stack_id: stack_id, stack_position: 1})
      task
    end

    test "stack_abandon on a done stack refuses, names stack_eject, and leaves the stack done" do
      project = create_project()

      %{stack_id: stack_id} =
        create_stack_via_tool(project.id, unique_slug("e2e-abandon-done"), "Already Shipped")

      member = attach_member!(project, stack_id, "in_progress")
      force_stack_status!(stack_id, "done")

      assert {:error, error} =
               ToolSurface.execute(
                 "stack_abandon",
                 %{"stack_id" => stack_id, "reason" => "too late"},
                 %{}
               )

      assert error.error ==
               "Stack #{stack_id} is already done; abandoning it would flip shipped work to abandoned. " <>
                 "Use stack_eject to detach an individual member."

      assert error.recoverable == false
      refute Map.has_key?(error, :suggestion)

      {:ok, after_refusal} = ToolSurface.execute("stack_get", %{"stack_id" => stack_id}, %{})
      assert after_refusal.stack.status == "done"
      # No description was set at create; a half-write would have put
      # "Abandoned: too late" here.
      assert is_nil(after_refusal.stack.description)
      # The member sweep did not run: the member is still attached.
      assert Enum.any?(after_refusal.members, &(&1.id == member.id))
    end

    test "control: stack_abandon on an in_progress stack still succeeds" do
      project = create_project()

      %{stack_id: stack_id} =
        create_stack_via_tool(project.id, unique_slug("e2e-abandon-wip"), "In Flight")

      force_stack_status!(stack_id, "in_progress")

      assert {:ok, result} =
               ToolSurface.execute(
                 "stack_abandon",
                 %{"stack_id" => stack_id, "reason" => "scope cut"},
                 %{}
               )

      assert result.status == "abandoned"
      {:ok, after_abandon} = ToolSurface.execute("stack_get", %{"stack_id" => stack_id}, %{})
      assert after_abandon.stack.status == "abandoned"
    end

    test "stack_complete on an abandoned stack refuses and leaves the stack abandoned" do
      project = create_project()

      %{stack_id: stack_id} =
        create_stack_via_tool(project.id, unique_slug("e2e-complete-abandoned"), "Dropped")

      # A done member: the members_not_done check alone would let this through.
      _member = attach_member!(project, stack_id, "done")
      force_stack_status!(stack_id, "abandoned")

      assert {:error, error} =
               ToolSurface.execute(
                 "stack_complete",
                 %{"stack_id" => stack_id, "note" => "sneaky"},
                 %{}
               )

      assert error.error == "Stack #{stack_id} is abandoned and cannot be completed."
      assert error.recoverable == false
      refute Map.has_key?(error, :code)
      refute Map.has_key?(error, :suggestion)

      {:ok, after_refusal} = ToolSurface.execute("stack_get", %{"stack_id" => stack_id}, %{})
      assert after_refusal.stack.status == "abandoned"
      # No description was set at create; a half-write would have put
      # "Completed: sneaky" here.
      assert is_nil(after_refusal.stack.description)
    end

    test "control: stack_complete on an in_review stack with all members done still succeeds" do
      project = create_project()

      %{stack_id: stack_id} =
        create_stack_via_tool(project.id, unique_slug("e2e-complete-review"), "Reviewed")

      _member = attach_member!(project, stack_id, "done")
      force_stack_status!(stack_id, "in_review")

      assert {:ok, result} =
               ToolSurface.execute(
                 "stack_complete",
                 %{"stack_id" => stack_id, "note" => "shipped"},
                 %{}
               )

      assert result.status == "done"
      {:ok, after_complete} = ToolSurface.execute("stack_get", %{"stack_id" => stack_id}, %{})
      assert after_complete.stack.status == "done"
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

  describe "looping error envelopes (task 01a05393 stage 4)" do
    # Every refusal here must name an action that is LEGAL for the status
    # the fixture is actually in, and must NOT carry the old text that
    # pointed at another refusal. Each refute is paired with a control
    # fixture that still produces the old wording, so a blanket string
    # swap cannot pass.

    # A fully-planned stack member parked at `stack_pending`, with the
    # stack row forced to `status`. Fixture-only writes (Repo/update for
    # setup, envelopes for outcomes): `abandon_stack/2` would clear the
    # membership we need the gate to see.
    defp parked_member_in_stack_at(status) do
      %{stack_id: stack_id, subject: subject} = gated_stack(plan_blocker?: true)
      {:ok, subject} = Tasks.update_task(subject, %{status: "stack_pending"})
      force_stack_status!(stack_id, status)
      %{stack_id: stack_id, subject: Tasks.get_task_record(subject.id)}
    end

    test "task_start on a stack_pending member of an abandoned stack names stack_eject and never stack_start" do
      %{stack_id: stack_id, subject: subject} = parked_member_in_stack_at("abandoned")
      assert subject.status == "stack_pending"

      {:error, error} = ToolSurface.execute("task_start", %{"task_id" => subject.id}, %{})

      assert error.recoverable == true
      assert error.error =~ "stack #{stack_id} is abandoned"
      assert error.suggestion =~ "stack_eject"
      assert error.suggestion =~ ~s(task_update status: "backlog")
      # The loop: the old head told every caller to run stack_start, which
      # refuses anything but `forming`. Check BOTH fields.
      refute error.error =~ "stack_start"
      refute error.suggestion =~ "stack_start"
      # (a): the transition-table wording must not surface for a status
      # whose refusal is the gate.
      refute error.error =~ "Must be backlog or planning"
      refute error.suggestion =~ "Must be backlog or planning"
      # The wording describes what abandon does on this branch, not more —
      # and per the ruling it must not claim membership is cleared on every
      # member: landed members keep theirs.
      assert error.error =~ "returns stack_pending members to backlog"
      assert error.error =~ "landed on the rollup keep their membership"
      refute error.error =~ "every member"
      refute error.error =~ "moved to blocked"
    end

    test "task_update(status: in_progress) on the same member gets the same abandoned envelope" do
      %{stack_id: stack_id, subject: subject} = parked_member_in_stack_at("abandoned")

      {:error, error} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => subject.id, "status" => "in_progress"},
          %{}
        )

      assert error.error =~ "stack #{stack_id} is abandoned"
      assert error.suggestion =~ "stack_eject"
      refute error.error =~ "stack_start"
      refute error.suggestion =~ "stack_start"
    end

    test "control: the same member in a forming stack is still told to call stack_start" do
      %{stack_id: stack_id, subject: subject} = parked_member_in_stack_at("forming")

      {:error, error} = ToolSurface.execute("task_start", %{"task_id" => subject.id}, %{})

      assert error.error =~ "stack #{stack_id} has not started yet"

      assert error.suggestion ==
               "Call stack_start with stack_id #{stack_id} to open the stack, then retry."

      refute error.error =~ "abandoned"
      refute error.suggestion =~ "stack_eject"
    end

    test "a blocked stack names the conflict and does not suggest stack_start" do
      %{stack_id: stack_id, subject: subject} = parked_member_in_stack_at("blocked")

      {:error, error} = ToolSurface.execute("task_start", %{"task_id" => subject.id}, %{})

      assert error.error =~ "stack #{stack_id} is blocked"
      assert error.error =~ "failed to merge into the rollup"
      assert error.suggestion =~ "stack_eject"
      refute error.error =~ "stack_start"
      refute error.suggestion =~ "stack_start"
    end

    test "a done stack says the status seen and points at stack_eject / stack_create" do
      %{stack_id: stack_id, subject: subject} = parked_member_in_stack_at("done")

      {:error, error} = ToolSurface.execute("task_start", %{"task_id" => subject.id}, %{})

      assert error.error =~ "stack #{stack_id} is done"
      assert error.suggestion =~ "stack_eject"
      assert error.suggestion =~ "stack_create"
      refute error.error =~ "stack_start"
      refute error.suggestion =~ "stack_start"
    end

    test "task_start :invalid_transition lists the sources read from the transition table" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Shipped"})
      {:ok, _} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, task} = Tasks.update_task(task, %{status: "done"})

      {:error, error} = ToolSurface.execute("task_start", %{"task_id" => task.id}, %{})

      # Pinned literal: this is what the table says today. If the table
      # widens or narrows, the envelope must follow it and this pin tells.
      assert error.error ==
               "Cannot start task from status done. in_progress is reachable from: " <>
                 "backlog, blocked, deploying, in_review, planning, stack_pending " <>
                 "(per ADR 0029, plan approval transitions to in_progress automatically)."

      refute error.error =~ "Must be backlog or planning"
      assert error.recoverable == true

      # Derivation check: the enumerated set is exactly the table's sources
      # for in_progress, so the literal above cannot drift from the table
      # without one of these two assertions going red.
      expected =
        Tasks.valid_task_transitions()
        |> Enum.filter(fn {_from, targets} -> "in_progress" in targets end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      assert expected == ~w(backlog blocked deploying in_review planning stack_pending)
    end

    test "stack_start on an abandoned stack names task_start / stack_create, not stack_get" do
      project = create_project()

      %{stack_id: stack_id} =
        create_stack_via_tool(project.id, unique_slug("e2e-start-abandoned"), "Dropped")

      force_stack_status!(stack_id, "abandoned")

      {:error, error} = ToolSurface.execute("stack_start", %{"stack_id" => stack_id}, %{})

      assert error.recoverable == false
      assert error.error =~ "This stack is abandoned"
      assert error.suggestion =~ "This stack is abandoned"
      assert error.suggestion =~ "task_start"
      assert error.suggestion =~ "stack_create"
      # The other half of the loop: a READ is not an action.
      refute error.error =~ "stack_get"
      refute error.suggestion =~ "stack_get"
      refute error.suggestion =~ "via stack_get"

      {:ok, after_refusal} = ToolSurface.execute("stack_get", %{"stack_id" => stack_id}, %{})
      assert after_refusal.stack.status == "abandoned"
    end

    test "stack_start refusal wording follows the status it saw" do
      project = create_project()

      for {status, phrase} <- [
            {"in_progress", "already in_progress; there is nothing to start"},
            {"done", "This stack is done; its work has shipped"},
            {"blocked", "blocked on a rollup merge conflict"},
            {"in_review", "This stack is in_review; its rollup is already landing"}
          ] do
        %{stack_id: stack_id} =
          create_stack_via_tool(
            project.id,
            unique_slug("e2e-start-#{String.replace(status, "_", "-")}"),
            "At #{status}"
          )

        force_stack_status!(stack_id, status)

        {:error, error} = ToolSurface.execute("stack_start", %{"stack_id" => stack_id}, %{})

        assert error.error =~ "This stack is #{status}."

        assert error.suggestion =~ phrase,
               "status #{status}: expected #{inspect(phrase)} in #{inspect(error.suggestion)}"

        refute error.suggestion =~ "via stack_get"
      end
    end

    test "control: stack_start on a forming stack with planned members still starts it" do
      %{stack_id: stack_id} = gated_stack(plan_blocker?: true)

      assert {:ok, started} = ToolSurface.execute("stack_start", %{"stack_id" => stack_id}, %{})
      assert started.status == "in_progress"
    end
  end

  # Task 01a05393 stage 3 (ADR 0045 decision 7): `task_update` surfaces the
  # shipped-stack refusal verbatim, `recoverable: false`, so the agent reads
  # where the work goes instead. Paired with the manual-ship lane control.
  describe "task_update on a member of a shipped stack" do
    alias Platform.Tasks.Stacks
    alias Platform.Tasks.Stacks.ShipState

    defp done_member_of_done_stack(stack_meta) do
      project = create_project()
      slug = unique_slug("shipped")

      %{stack_id: stack_id} = create_stack_via_tool(project.id, slug, "Shipped")

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Late Member"})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => task.id}, %{})

      member =
        task.id
        |> Tasks.get_task_record()
        |> Task.changeset(%{status: "done"})
        |> Repo.update!()

      {:ok, stack} =
        stack_id
        |> Stacks.get_stack!()
        |> Stacks.update_stack(%{status: "done", metadata: stack_meta})

      {stack, member}
    end

    test "refuses status: planning with the ADR-0045 message, recoverable: false" do
      {stack, member} =
        done_member_of_done_stack(%{
          "rollup_pr" => %{"number" => 91, "merged_at" => "2026-08-01T00:00:00Z"}
        })

      assert stack.status == "done"
      assert ShipState.shipped?(stack)
      assert member.status == "done"

      {:error, error} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => member.id, "status" => "planning"},
          %{}
        )

      assert error.recoverable == false
      assert error.error =~ "post-ship changes are new individual tasks"
      assert error.error =~ stack.slug
      assert error.error =~ "#91"
      assert error.suggestion =~ "task_create"
      refute error.error =~ "Invalid status transition"
      assert Tasks.get_task_record(member.id).status == "done"
    end

    test "still moves a member of a done stack whose PR was never opened (manual-ship lane)" do
      {stack, member} = done_member_of_done_stack(%{})

      assert stack.status == "done"
      refute ShipState.shipped?(stack)
      assert member.status == "done"

      assert {:ok, %{status: "planning"}} =
               ToolSurface.execute(
                 "task_update",
                 %{"task_id" => member.id, "status" => "planning"},
                 %{}
               )
    end
  end

  # Task 01a05393 stage 4: `stack_update` gains `clear_conflict: true`, the
  # only status exit on this surface for a stack halted at `blocked` on a
  # rollup-merge conflict. The blocked+conflict state is seeded directly
  # via `Stacks.update_stack/2` (the deployer's conflict arm is unreachable
  # under the `--ff-only` runner).
  describe "stack_update with clear_conflict" do
    alias Platform.Tasks.Stack
    alias Platform.Tasks.Stacks
    alias Platform.Tasks.Stacks.ShipState

    @conflict %{"member_task_id" => "m", "files" => ["lib/x.ex"], "at" => "2026-08-01T00:00:00Z"}

    # One member forced to `in_review` so the recomputed rollup is
    # `in_review` — distinguishable from the `forming` an empty stack
    # would recompute to, and from the seeded `blocked`.
    defp stack_with_in_review_member(stack_attrs) do
      project = create_project()
      %{stack_id: stack_id} = create_stack_via_tool(project.id, unique_slug("clr"), "Held")
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Member"})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => task.id}, %{})

      task.id
      |> Tasks.get_task_record()
      |> Task.changeset(%{status: "in_review"})
      |> Repo.update!()

      {:ok, stack} = stack_id |> Stacks.get_stack!() |> Stacks.update_stack(stack_attrs)
      stack
    end

    test "clears the conflict, recomputes the status, and reports conflict_cleared: true" do
      stack =
        stack_with_in_review_member(%{status: "blocked", metadata: %{"conflict" => @conflict}})

      assert stack.status == "blocked"
      assert ShipState.conflict_held?(stack)

      {:ok, env} =
        ToolSurface.execute(
          "stack_update",
          %{"stack_id" => stack.id, "clear_conflict" => true, "name" => "Released"},
          %{}
        )

      assert env.conflict_cleared == true
      assert env.status == "in_review"
      assert env.name == "Released"

      persisted = Stacks.get_stack!(stack.id)
      assert persisted.status == "in_review"
      refute Map.has_key?(persisted.metadata, "conflict")
    end

    test "returns a recoverable not_conflicted error and writes nothing when there is no conflict" do
      stack = stack_with_in_review_member(%{status: "in_review", metadata: %{}})
      refute ShipState.conflict_held?(stack)

      {:error, error} =
        ToolSurface.execute(
          "stack_update",
          %{"stack_id" => stack.id, "clear_conflict" => true, "name" => "Should Not Land"},
          %{}
        )

      assert error.code == "not_conflicted"
      assert error.recoverable == true
      assert error.error =~ stack.slug

      persisted = Stacks.get_stack!(stack.id)
      assert persisted.name == "Held"
      assert persisted.status == "in_review"
    end

    test "clear_conflict: false leaves a conflict-held stack blocked and adds no envelope key" do
      stack =
        stack_with_in_review_member(%{status: "blocked", metadata: %{"conflict" => @conflict}})

      {:ok, env} =
        ToolSurface.execute(
          "stack_update",
          %{"stack_id" => stack.id, "clear_conflict" => false, "description" => "still held"},
          %{}
        )

      refute Map.has_key?(env, :conflict_cleared)
      assert env.status == "blocked"
      assert env.description == "still held"
      assert ShipState.conflict_held?(Stacks.get_stack!(stack.id))
    end

    test "a free-form status arg is ignored — clear_conflict is the only status exit" do
      stack =
        stack_with_in_review_member(%{status: "blocked", metadata: %{"conflict" => @conflict}})

      {:ok, env} =
        ToolSurface.execute(
          "stack_update",
          %{"stack_id" => stack.id, "status" => "in_review"},
          %{}
        )

      assert env.status == "blocked"
      refute Map.has_key?(env, :conflict_cleared)
      assert %Stack{status: "blocked"} = Stacks.get_stack!(stack.id)
    end

    test "the tool schema documents clear_conflict" do
      %{parameters: params} =
        Enum.find(ToolSurface.tool_definitions(), &(&1.name == "stack_update"))

      assert %{type: "boolean", required: false} = params.clear_conflict
      assert params.clear_conflict.description =~ "not_conflicted"
      refute Map.has_key?(params, :status)
    end
  end

  # Task 01a05393 stage 6 (defect D): `task_update(status: "stack_pending")`
  # on a stackless task used to succeed and strand the task. The refusal
  # comes from `Tasks.require_stack_commencement_for/2`; this block pins
  # the MCP envelope for it, and — the direction where the rule LOSES —
  # that a stacked member is still parked, because that is the stack
  # machinery's own path.
  describe "task_update(status: stack_pending) requires a stack (defect D)" do
    defp planning_task!(project_id, title) do
      {:ok, task} = Tasks.create_task(%{project_id: project_id, title: title})
      task |> Task.changeset(%{status: "planning"}) |> Repo.update!()
    end

    test "a stackless task gets a recoverable envelope that points at stack_add" do
      project = create_project()
      task = planning_task!(project.id, "Loner")
      assert is_nil(task.stack_id)

      assert {:error, error} =
               ToolSurface.execute(
                 "task_update",
                 %{"task_id" => task.id, "status" => "stack_pending"},
                 %{}
               )

      assert error.recoverable == true
      assert error.error =~ "Cannot transition to 'stack_pending'"
      assert error.error =~ "not in a stack"
      assert error.error =~ task.id
      assert error.suggestion =~ "stack_add"
      # Distinguishing wording of the neighbouring arms must be absent:
      # this is neither the table refusal nor the commencement gate.
      refute error.error =~ "Invalid status transition"
      refute error.error =~ "missing an approved plan"
      refute error.error =~ "has not started yet"

      assert Tasks.get_task_record(task.id).status == "planning"
    end

    test "the rule loses: a stacked member is parked at stack_pending" do
      project = create_project()
      %{stack_id: stack_id} = create_stack_via_tool(project.id, unique_slug("e2e-park"), "Park")
      task = planning_task!(project.id, "Member")

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => task.id}, %{})

      member = Tasks.get_task_record(task.id)
      assert member.stack_id == stack_id
      # A forming stack leaves the newcomer's status alone.
      assert member.status == "planning"

      assert {:ok, result} =
               ToolSurface.execute(
                 "task_update",
                 %{"task_id" => task.id, "status" => "stack_pending"},
                 %{}
               )

      assert result.status == "stack_pending"
      assert Tasks.get_task_record(task.id).status == "stack_pending"
    end
  end

  defp all_phase_attrs(agent_id) do
    entry = %{"assignee_id" => agent_id, "assignee_type" => "agent"}
    %{"planning" => entry, "execution" => entry, "review" => entry}
  end

  # ── Task 01a05392 stage 1: stack_start now fails LOUDLY on a dead rollup ──
  defmodule FailingRollupRunner do
    @moduledoc false
    @behaviour Platform.Tasks.StackDeployer.GitRunner

    @impl true
    def ensure_rollup_branch(_args), do: {:error, {:git_exit, 128, "fatal: repository not found"}}

    @impl true
    def merge_member_into_rollup(_args), do: {:error, :not_reached}
    @impl true
    def open_stack_pr(_args), do: {:error, :not_reached}
    @impl true
    def diff_stat(_args), do: {:ok, ""}
    @impl true
    def revert_member_merge(_args), do: {:error, :not_reached}
    @impl true
    def close_stack_pr(_args), do: {:ok, :closed}
    @impl true
    def delete_rollup_branch(_args), do: {:ok, :deleted}
    @impl true
    def sha_reachable?(_args), do: {:ok, true}
  end

  describe "stack_start — rollup branch unavailable" do
    setup do
      prev = Application.get_env(:platform, :stack_deployer, [])

      Application.put_env(:platform, :stack_deployer,
        git_runner: FailingRollupRunner,
        async: false
      )

      on_exit(fn -> Application.put_env(:platform, :stack_deployer, prev) end)
      :ok
    end

    test "returns a RECOVERABLE envelope naming the rollup branch and the git reason" do
      # A project WITH a repo_url — the rollup path is live, and the runner
      # refuses. Nothing may start: a member cut from the default branch has
      # already lost the property the rollup exists for.
      project = create_project(%{repo_url: "https://github.com/test/dead-repo"})
      slug = unique_slug("rollup-dead")

      %{stack_id: stack_id} = create_stack_via_tool(project.id, slug, "Dead rollup")

      {:ok, member} = Tasks.create_task(%{project_id: project.id, title: "Member"})
      {:ok, _} = Tasks.create_plan(%{task_id: member.id, status: "approved"})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => member.id}, %{})

      assert {:error, error} =
               ToolSurface.execute("stack_start", %{"stack_id" => stack_id}, %{})

      # Recoverable: the stack is still `forming`, so the caller can fix the
      # remote and call again. A non-recoverable envelope would tell a
      # federated agent to give up on a transient git failure.
      assert error.recoverable == true
      # Names WHICH branch and WHY — "failed to start stack" alone is
      # unactionable from the other side of the MCP wire.
      assert error.error =~ "stack/#{slug}"
      assert error.error =~ "repository not found"
      assert error.error =~ "No members were started"
      assert error.suggestion =~ "stack_start"

      # And the surface agrees: nothing moved.
      {:ok, after_start} = ToolSurface.execute("stack_get", %{"stack_id" => stack_id}, %{})
      assert after_start.stack.status == "forming"
      assert Enum.all?(after_start.members, &(&1.status == "backlog"))
    end
  end

  # ── Task 01a05392 stage 3: pause state on the read tools + the named retry ──
  #
  # Before this stage `paused_reason` was read by nothing: `serialize_task/1`
  # emitted neither `metadata` nor `stack_id`, and `serialize_stack/1`
  # emitted no stamp. Every assertion here is PAIRED with its negative
  # (a clean sibling reads `nil`, a forming stack reads `nil`) so a change
  # that returns a constant map is red.

  describe "task_get / stack_get pause state (01a05392 stage 3)" do
    test "task_get returns the paused_reason map + stack_id for a diverged member and nil for a clean sibling" do
      project = create_project()
      %{stack_id: stack_id} = create_stack_via_tool(project.id, unique_slug("e2e-paused"))

      paused = member_in_stack!(project, stack_id, position: 1)
      clean = member_in_stack!(project, stack_id, position: 2)
      {:ok, lone} = Tasks.create_task(%{project_id: project.id, title: "Lone"})

      stamp = %{
        "kind" => "rollup_diverged",
        "member_sha" => "aaaa1111",
        "rollup_sha" => "bbbb2222",
        "at" => "2026-08-30T00:00:00Z"
      }

      {:ok, _} = Tasks.update_task(paused, %{metadata: %{"paused_reason" => stamp}})

      {:ok, paused_view} = ToolSurface.execute("task_get", %{"task_id" => paused.id}, %{})
      assert paused_view.stack_id == stack_id
      assert paused_view.paused_reason == stamp
      assert paused_view.paused_reason["kind"] == "rollup_diverged"
      assert paused_view.paused_reason["member_sha"] == "aaaa1111"
      assert paused_view.paused_reason["rollup_sha"] == "bbbb2222"
      # The stamp, not the blob: no `metadata` key on the wire.
      refute Map.has_key?(paused_view, :metadata)

      {:ok, clean_view} = ToolSurface.execute("task_get", %{"task_id" => clean.id}, %{})
      assert clean_view.stack_id == stack_id
      assert is_nil(clean_view.paused_reason)

      {:ok, lone_view} = ToolSurface.execute("task_get", %{"task_id" => lone.id}, %{})
      assert is_nil(lone_view.stack_id)
      assert is_nil(lone_view.paused_reason)
    end

    test "stack_get exposes rollup_branch_ready on a started stack, nil on a forming one, and per-member paused_reason" do
      project =
        create_project(%{repo_url: "https://github.com/test/e2e-ready-#{unique_slug("r")}"})

      %{stack_id: started_id} = create_stack_via_tool(project.id, unique_slug("e2e-ready"))

      # `handle_stack_created/1` creates (and stamps) the rollup at creation
      # time whenever the project has a repo_url, so "rollup never created"
      # is a stack on a project WITHOUT one: creation logs `:no_repo_url`
      # and writes no stamp.
      no_repo = create_project()
      %{stack_id: forming_id} = create_stack_via_tool(no_repo.id, unique_slug("e2e-forming"))

      {:ok, root} = Tasks.create_task(%{project_id: project.id, title: "Root"})
      {:ok, _} = Tasks.create_plan(%{task_id: root.id, status: "approved"})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => started_id, "task_id" => root.id}, %{})

      # The default NoopRunner answers `already_exists`, which the deployer
      # still stamps — stage 1 made that stamp synchronous inside
      # `start_stack/1`, so it is present the moment the tool returns.
      {:ok, _} = ToolSurface.execute("stack_start", %{"stack_id" => started_id}, %{})

      {:ok, started} = ToolSurface.execute("stack_get", %{"stack_id" => started_id}, %{})
      assert %{"at" => at} = started.stack.rollup_branch_ready
      assert is_binary(at)
      refute Map.has_key?(started.stack, :metadata)

      {:ok, forming} = ToolSurface.execute("stack_get", %{"stack_id" => forming_id}, %{})
      assert forming.stack.status == "forming"
      assert is_nil(forming.stack.rollup_branch_ready)

      # Members: one paused, one clean, on the same stack_get call.
      paused = member_in_stack!(no_repo, forming_id, position: 1)
      clean = member_in_stack!(no_repo, forming_id, position: 2)
      stamp = %{"kind" => "rollup_diverged", "member_sha" => "m", "rollup_sha" => "r"}
      {:ok, _} = Tasks.update_task(paused, %{metadata: %{"paused_reason" => stamp}})

      {:ok, view} = ToolSurface.execute("stack_get", %{"stack_id" => forming_id}, %{})
      assert Enum.find(view.members, &(&1.id == paused.id)).paused_reason == stamp
      assert is_nil(Enum.find(view.members, &(&1.id == clean.id)).paused_reason)
    end
  end

  describe "stack_retry_member_merge (01a05392 stage 3)" do
    alias Platform.Federation.ToolArguments
    alias Platform.Tasks.StackDeployer
    alias Platform.Tasks.StackDeployer.GitShellRunner

    test "is registered under the exact name with task_id required (declaration and executor both present)" do
      names = ToolSurface.list_tools(["task"]) |> Enum.map(& &1.name)
      assert "stack_retry_member_merge" in names

      assert ToolArguments.required_params("stack_retry_member_merge") ==
               [%{key: "task_id", aliases: []}]

      # Executor present: a declaration with no handler would fall through
      # to the unknown-tool clause, which does not know `:not_in_stack`.
      {:ok, lone} = Tasks.create_task(%{project_id: create_project().id, title: "Lone"})

      assert {:error, %{code: :not_in_stack}} =
               ToolSurface.execute("stack_retry_member_merge", %{"task_id" => lone.id}, %{})
    end

    test "a task with no stack_id is refused with a NON-recoverable envelope" do
      {:ok, lone} = Tasks.create_task(%{project_id: create_project().id, title: "Lone"})

      assert {:error, error} =
               ToolSurface.execute("stack_retry_member_merge", %{"task_id" => lone.id}, %{})

      assert error.code == :not_in_stack
      assert error.recoverable == false
      assert error.error =~ lone.id
    end

    test "an unknown task id is non-recoverable; a missing task_id is refused" do
      assert {:error, %{code: :task_not_found, recoverable: false}} =
               ToolSurface.execute(
                 "stack_retry_member_merge",
                 %{"task_id" => Ecto.UUID.generate()},
                 %{}
               )

      assert {:error, %{recoverable: true, error: msg}} =
               ToolSurface.execute("stack_retry_member_merge", %{}, %{})

      assert msg =~ "task_id"
    end

    test "a member the deployer will not merge yet is refused RECOVERABLY, naming the prior step" do
      project = create_project(%{repo_url: "https://github.com/test/e2e-notready"})
      %{stack_id: stack_id} = create_stack_via_tool(project.id, unique_slug("e2e-notready"))
      member = member_in_stack!(project, stack_id, position: 1, status: "in_progress")

      assert {:error, error} =
               ToolSurface.execute("stack_retry_member_merge", %{"task_id" => member.id}, %{})

      assert error.code == :member_not_ready
      assert error.outcome == "not_ready"
      assert error.recoverable == true
      assert error.reason == %{kind: "member_not_in_review"}
      assert error.error =~ "in_progress"
      assert error.suggestion =~ "in_review"
    end

    test "a still-diverged member returns still_diverged naming the rollup branch, both SHAs, and the rebase" do
      slug = unique_slug("e2e-still-diverged")
      origin = real_origin_with_rollup!(slug)
      sibling_sha = push_sibling_commit_to_rollup!(origin, slug)

      project = create_project(%{repo_url: origin.bare})
      %{stack_id: stack_id} = create_stack_via_tool(project.id, slug)
      member = review_ready_member!(project, stack_id)

      # Cut from origin/main, not rollup HEAD — the dispatcher's manufactured
      # divergence.
      member_sha =
        push_member_branch!(origin, StackDeployer.member_branch_for(member), origin.main_sha)

      assert {:error, error} =
               ToolSurface.execute("stack_retry_member_merge", %{"task_id" => member.id}, %{})

      assert error.code == :rollup_diverged
      assert error.outcome == "still_diverged"
      assert error.recoverable == true
      assert error.error =~ "stack/#{slug}"
      assert error.rollup_branch == "stack/#{slug}"
      assert error.rollup_sha == sibling_sha
      assert error.member_sha == member_sha
      assert error.suggestion =~ "git rebase origin/stack/#{slug}"

      # The pause is now readable through task_get — the stage's whole point.
      {:ok, view} = ToolSurface.execute("task_get", %{"task_id" => member.id}, %{})
      assert view.paused_reason["kind"] == "rollup_diverged"
      assert view.paused_reason["rollup_sha"] == sibling_sha
      assert view.paused_reason["member_sha"] == member_sha
    end

    test "a diverged member that has since been rebased onto rollup HEAD merges; the reload has the stamp and no paused_reason; a second call is already_merged" do
      slug = unique_slug("e2e-retry-merged")
      origin = real_origin_with_rollup!(slug)
      sibling_sha = push_sibling_commit_to_rollup!(origin, slug)

      project = create_project(%{repo_url: origin.bare})
      %{stack_id: stack_id} = create_stack_via_tool(project.id, slug)
      # A second, unmerged member keeps the stack-PR gate closed so no
      # `gh pr create` runs against the stand-in origin after the merge.
      _unmerged = member_in_stack!(project, stack_id, position: 2, status: "in_progress")
      member = review_ready_member!(project, stack_id)
      branch = StackDeployer.member_branch_for(member)

      _stale_sha = push_member_branch!(origin, branch, origin.main_sha)

      assert {:error, %{outcome: "still_diverged"}} =
               ToolSurface.execute("stack_retry_member_merge", %{"task_id" => member.id}, %{})

      assert Tasks.get_task_record(member.id).metadata["paused_reason"]["kind"] ==
               "rollup_diverged"

      # The agent's remediation: rebase onto rollup HEAD and force-push. Here
      # that is a fresh commit cut from the sibling's SHA, force-pushed to
      # the same member branch.
      rebased_sha = push_member_branch!(origin, branch, sibling_sha, force: true)

      assert {:ok, result} =
               ToolSurface.execute("stack_retry_member_merge", %{"task_id" => member.id}, %{})

      assert result.outcome == "merged"
      assert result.merge_sha == rebased_sha
      assert result.task_id == member.id
      assert result.stack_id == stack_id
      assert result.rollup_branch == "stack/#{slug}"
      assert is_nil(result.task.paused_reason)
      assert result.task.stack_id == stack_id

      reloaded = Tasks.get_task_record(member.id)
      assert reloaded.metadata["merged_into_rollup_at"]["sha"] == rebased_sha
      refute Map.has_key?(reloaded.metadata, "paused_reason")

      # Idempotent: the second call is a successful no-op that echoes the
      # existing stamp, and the origin is untouched.
      assert {:ok, again} =
               ToolSurface.execute("stack_retry_member_merge", %{"task_id" => member.id}, %{})

      assert again.outcome == "already_merged"
      assert again.merged_into_rollup_at["sha"] == rebased_sha
      assert is_nil(again.task.paused_reason)
    end

    # ── Fixtures ────────────────────────────────────────────────────────

    # A real bare origin with one commit on `main` and `stack/<slug>` at
    # that same commit; the deployer is switched to the REAL
    # `GitShellRunner` with a scratch clone root. Mirrors the stage 2
    # fixture in `stack_deployer_test.exs`.
    defp real_origin_with_rollup!(slug) do
      root = Platform.TestTemp.mkdir!("ts-retry")
      prev = Application.get_env(:platform, :stack_deployer, [])

      Application.put_env(
        :platform,
        :stack_deployer,
        Keyword.merge(prev,
          git_runner: GitShellRunner,
          async: false,
          repo_root: Path.join(root, "clones")
        )
      )

      on_exit(fn ->
        Application.put_env(:platform, :stack_deployer, prev)
        File.rm_rf(root)
      end)

      bare = Path.join(root, "origin.git")
      work = Path.join(root, "seed")

      git!(["init", "--quiet", "--bare", "--initial-branch=main", bare])
      git!(["init", "--quiet", "--initial-branch=main", work])
      git!(["config", "user.email", "test@example.com"], work)
      git!(["config", "user.name", "Test"], work)
      File.write!(Path.join(work, "README.md"), "seed\n")
      git!(["add", "README.md"], work)
      git!(["commit", "--quiet", "-m", "seed"], work)
      git!(["remote", "add", "origin", bare], work)
      git!(["push", "--quiet", "origin", "main"], work)
      git!(["push", "--quiet", "origin", "main:refs/heads/stack/#{slug}"], work)

      %{bare: bare, work: work, main_sha: git!(["rev-parse", "HEAD"], work)}
    end

    defp push_sibling_commit_to_rollup!(origin, slug) do
      local = "sibling-#{System.unique_integer([:positive])}"
      git!(["checkout", "--quiet", "-b", local, origin.main_sha], origin.work)
      File.write!(Path.join(origin.work, "#{local}.txt"), "sibling\n")
      git!(["add", "#{local}.txt"], origin.work)
      git!(["commit", "--quiet", "-m", "sibling"], origin.work)
      git!(["push", "--quiet", "origin", "#{local}:refs/heads/stack/#{slug}"], origin.work)
      git!(["rev-parse", "HEAD"], origin.work)
    end

    defp push_member_branch!(origin, branch, base_sha, opts \\ []) do
      local = "local-#{System.unique_integer([:positive])}"
      git!(["checkout", "--quiet", "-b", local, base_sha], origin.work)
      File.write!(Path.join(origin.work, "#{local}.txt"), "member\n")
      git!(["add", "#{local}.txt"], origin.work)
      git!(["commit", "--quiet", "-m", "member"], origin.work)
      force = if Keyword.get(opts, :force, false), do: ["--force"], else: []

      git!(
        ["push", "--quiet"] ++ force ++ ["origin", "#{local}:refs/heads/#{branch}"],
        origin.work
      )

      git!(["rev-parse", "HEAD"], origin.work)
    end

    defp git!(args, cd \\ nil) do
      opts = [stderr_to_stdout: true] ++ if(cd, do: [cd: cd], else: [])

      case System.cmd("git", args, opts) do
        {out, 0} -> String.trim(out)
        {out, code} -> flunk("git #{Enum.join(args, " ")} exited #{code}: #{out}")
      end
    end

    # A member at `in_review` whose one review stage has every validation
    # `passed` — exactly what `StackDeployer.review_readiness/1` merges.
    defp review_ready_member!(project, stack_id) do
      task = member_in_stack!(project, stack_id, position: 1, status: "in_review")
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Task-level review",
          status: "passed"
        })

      {:ok, _} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "lint_pass", status: "passed"})

      {:ok, _} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass", status: "passed"})

      Tasks.get_task_record(task.id)
    end
  end

  # Shared by both stage-3 describes: a task placed directly into a stack
  # (bypassing `stack_add`'s status cascade so the fixture controls status).
  # ── Task 01a05394-8300 stage 1: task_get exposes stack_position + a curated
  # `stack` sub-map (landed_at / blocked_reason / blocked_reason_at) ──
  #
  # Every positive is PAIRED with a negative on a sibling in the same stack
  # (stamped vs unstamped, blocked vs clean), plus a third, distinct
  # non-member case where the sub-map itself is `nil`. The unstamped member
  # asserts the KEY IS PRESENT with a nil value — `refute Map.has_key?`
  # would be green under a serializer that dropped the key entirely.

  describe "task_get stack sub-map (01a05394-8300 stage 1)" do
    test "a stamped member reads landed_at = the stamp; an unstamped sibling reads the key as nil; a non-member reads stack: nil" do
      project = create_project()
      %{stack_id: stack_id} = create_stack_via_tool(project.id, unique_slug("e2e-landed"))

      landed = member_in_stack!(project, stack_id, position: 1)
      pending = member_in_stack!(project, stack_id, position: 2)
      {:ok, lone} = Tasks.create_task(%{project_id: project.id, title: "Lone"})

      stamp = %{"sha" => "abc1234", "at" => "2026-08-30T12:00:00Z"}
      {:ok, _} = Tasks.update_task(landed, %{metadata: %{"merged_into_rollup_at" => stamp}})

      {:ok, landed_view} = ToolSurface.execute("task_get", %{"task_id" => landed.id}, %{})
      assert landed_view.stack_id == stack_id
      assert landed_view.stack_position == 1
      assert %{} = landed_view.stack
      assert landed_view.stack.landed_at == stamp
      assert landed_view.stack.landed_at["sha"] == "abc1234"
      # Curated keys only — no raw metadata anywhere on the wire.
      refute Map.has_key?(landed_view, :metadata)

      assert Map.keys(landed_view.stack) |> Enum.sort() ==
               [:blocked_reason, :blocked_reason_at, :landed_at]

      {:ok, pending_view} = ToolSurface.execute("task_get", %{"task_id" => pending.id}, %{})
      assert pending_view.stack_id == stack_id
      assert pending_view.stack_position == 2
      assert Map.has_key?(pending_view.stack, :landed_at) and pending_view.stack.landed_at == nil

      {:ok, lone_view} = ToolSurface.execute("task_get", %{"task_id" => lone.id}, %{})
      assert Map.has_key?(lone_view, :stack) and lone_view.stack == nil
      assert Map.has_key?(lone_view, :stack_position) and lone_view.stack_position == nil
    end

    test "blocked_reason + blocked_reason_at are the plain strings from stamp_blocked_reason/2; a clean sibling reads both as nil" do
      project = create_project()
      %{stack_id: stack_id} = create_stack_via_tool(project.id, unique_slug("e2e-blocked"))

      blocked = member_in_stack!(project, stack_id, position: 1, status: "in_progress")
      clean = member_in_stack!(project, stack_id, position: 2)

      {:ok, _} = Tasks.stamp_blocked_reason(blocked, "Waiting on predecessor #1 to land.")

      {:ok, blocked_view} = ToolSurface.execute("task_get", %{"task_id" => blocked.id}, %{})
      assert blocked_view.stack.blocked_reason == "Waiting on predecessor #1 to land."
      assert is_binary(blocked_view.stack.blocked_reason_at)
      assert {:ok, _, _} = DateTime.from_iso8601(blocked_view.stack.blocked_reason_at)
      # Blocked but not landed: the two stamps are independent.
      assert Map.has_key?(blocked_view.stack, :landed_at) and blocked_view.stack.landed_at == nil

      {:ok, clean_view} = ToolSurface.execute("task_get", %{"task_id" => clean.id}, %{})

      assert Map.has_key?(clean_view.stack, :blocked_reason) and
               clean_view.stack.blocked_reason == nil

      assert Map.has_key?(clean_view.stack, :blocked_reason_at) and
               clean_view.stack.blocked_reason_at == nil
    end

    test "a member whose metadata column is NULL (old row) serializes without raising" do
      project = create_project()
      %{stack_id: stack_id} = create_stack_via_tool(project.id, unique_slug("e2e-nilmeta"))
      member = member_in_stack!(project, stack_id, position: 1)

      import Ecto.Query, only: [from: 2]
      {1, _} = Repo.update_all(from(t in Task, where: t.id == ^member.id), set: [metadata: nil])
      assert is_nil(Tasks.get_task_record(member.id).metadata)

      {:ok, view} = ToolSurface.execute("task_get", %{"task_id" => member.id}, %{})
      assert view.stack_id == stack_id
      assert view.stack_position == 1

      assert view.stack == %{landed_at: nil, blocked_reason: nil, blocked_reason_at: nil}
      assert is_nil(view.paused_reason)
    end
  end

  describe "stack_get member fields + status-aware executable_now (01a05394-8300 stage 2)" do
    setup do
      project = create_project()
      %{stack_id: stack_id} = create_stack_via_tool(project.id, unique_slug("e2e-s2"))
      %{project: project, stack_id: stack_id}
    end

    defp set_status!(%Task{} = task, status) do
      Repo.get!(Task, task.id) |> Task.changeset(%{status: status}) |> Repo.update!()
    end

    defp stamp_landed!(%Task{} = task, sha) do
      {:ok, _} =
        Tasks.update_task(Repo.get!(Task, task.id), %{
          metadata: %{"merged_into_rollup_at" => %{"sha" => sha, "at" => "2026-08-30T12:00:00Z"}}
        })

      task
    end

    defp add_dep!(%Task{} = task, %Task{} = dep) do
      {:ok, _} =
        Tasks.update_task(Repo.get!(Task, task.id), %{
          dependencies: [%{"task_id" => dep.id, "kind" => "blocks"}]
        })

      task
    end

    defp get_stack!(stack_id) do
      {:ok, result} = ToolSurface.execute("stack_get", %{"stack_id" => stack_id}, %{})
      result
    end

    defp member_entry(result, %Task{id: id}), do: Enum.find(result.members, &(&1.id == id))

    test "landed_at: a stamped member reads the stamp; an unstamped sibling reads explicit nil",
         %{project: project, stack_id: stack_id} do
      landed = member_in_stack!(project, stack_id, position: 1) |> stamp_landed!("abc1234")
      pending = member_in_stack!(project, stack_id, position: 2)

      result = get_stack!(stack_id)

      assert member_entry(result, landed).landed_at ==
               %{"sha" => "abc1234", "at" => "2026-08-30T12:00:00Z"}

      entry = member_entry(result, pending)
      assert Map.has_key?(entry, :landed_at) and entry.landed_at == nil
      # Curated keys only — the raw metadata map never crosses the wire.
      refute Enum.any?(result.members, &Map.has_key?(&1, :metadata))
      refute Map.has_key?(result.stack, :metadata)
    end

    test "rollup_pr: never-opened → nil; mid-open placeholder → number nil without raising; merged shape exposes number/url/merged_at",
         %{project: project, stack_id: stack_id} do
      _member = member_in_stack!(project, stack_id, position: 1)

      never = get_stack!(stack_id)
      assert Map.has_key?(never.stack, :rollup_pr) and never.stack.rollup_pr == nil

      # The deployer's lock placeholder: the FIRST write has no number/url.
      {:ok, _} =
        Platform.Tasks.Stacks.update_stack(Platform.Tasks.Stacks.get_stack(stack_id), %{
          metadata: %{"rollup_pr" => %{"status" => "opening", "at" => "2026-08-30T12:00:00Z"}}
        })

      opening = get_stack!(stack_id)
      assert opening.stack.rollup_pr.status == "opening"

      assert Map.has_key?(opening.stack.rollup_pr, :number) and
               opening.stack.rollup_pr.number == nil

      assert opening.stack.rollup_pr.url == nil
      assert opening.stack.rollup_pr.merged_at == nil

      {:ok, _} =
        Platform.Tasks.Stacks.update_stack(Platform.Tasks.Stacks.get_stack(stack_id), %{
          metadata: %{
            "rollup_pr" => %{
              "number" => 42,
              "url" => "https://github.com/example/core/pull/42",
              "opened_at" => "2026-08-30T12:01:00Z",
              "auto_merge_armed" => true,
              "merged_at" => "2026-08-30T12:30:00Z"
            }
          }
        })

      merged = get_stack!(stack_id)

      assert merged.stack.rollup_pr == %{
               status: nil,
               number: 42,
               url: "https://github.com/example/core/pull/42",
               merged_at: "2026-08-30T12:30:00Z",
               auto_merge_armed: true
             }
    end

    test "plan_status: approved → \"approved\", pending_review → \"pending_review\", no plan → nil; the LATEST plan wins",
         %{project: project, stack_id: stack_id} do
      approved = member_in_stack!(project, stack_id, position: 1)
      reviewing = member_in_stack!(project, stack_id, position: 2)
      planless = member_in_stack!(project, stack_id, position: 3)

      # v1 approved then superseded by a v2 that is now approved: the
      # highest version's status must be the one reported.
      {:ok, v1} = Tasks.create_plan(%{task_id: approved.id, status: "rejected"})
      {:ok, _v2} = Tasks.create_plan(%{task_id: approved.id, status: "approved"})
      assert v1.version == 1
      {:ok, _} = Tasks.create_plan(%{task_id: reviewing.id, status: "pending_review"})

      result = get_stack!(stack_id)
      assert member_entry(result, approved).plan_status == "approved"
      assert member_entry(result, reviewing).plan_status == "pending_review"
      entry = member_entry(result, planless)
      assert Map.has_key?(entry, :plan_status) and entry.plan_status == nil
    end

    test "blocked_by: an unlanded in-stack predecessor is listed; once it lands (in_review + stamp) the list is [] — not nil, not absent",
         %{project: project, stack_id: stack_id} do
      root = member_in_stack!(project, stack_id, position: 1, status: "in_progress")
      child = member_in_stack!(project, stack_id, position: 2) |> add_dep!(root)

      before = get_stack!(stack_id)
      assert member_entry(before, child).blocked_by == [root.id]
      assert member_entry(before, root).blocked_by == []

      # A stamp alone is not "landed" for the engine — status must clear too.
      stamp_landed!(root, "def5678")
      stamped_only = get_stack!(stack_id)
      assert member_entry(stamped_only, child).blocked_by == [root.id]

      set_status!(root, "in_review")
      after_land = get_stack!(stack_id)
      entry = member_entry(after_land, child)
      assert Map.has_key?(entry, :blocked_by) and entry.blocked_by == []
    end

    test "executable_now is status-aware: a done root is NOT listed, an in_progress root IS; blocked_now holds the rest; every member is in exactly one bucket",
         %{project: project, stack_id: stack_id} do
      done_root = member_in_stack!(project, stack_id, position: 1, status: "in_progress")
      live_root = member_in_stack!(project, stack_id, position: 2, status: "in_progress")
      set_status!(done_root, "done")

      # Deps all landed but still parked at stack_pending — the promotion
      # sweep has not run. Must be VISIBLE in blocked_now with blocked_by [].
      parked =
        member_in_stack!(project, stack_id, position: 3, status: "in_progress")
        |> add_dep!(live_root)

      set_status!(parked, "stack_pending")
      stamp_landed!(live_root, "0a1b2c3")
      # live_root: in_progress + stamped. For the engine a dep is only
      # satisfied at in_review|deploying|done, so flip it — it stays
      # runnable (in_review is in the dispatcher's live set).
      set_status!(live_root, "in_review")

      # A promoted non-root whose only dep has landed IS runnable now.
      promoted =
        member_in_stack!(project, stack_id, position: 4, status: "in_progress")
        |> add_dep!(live_root)

      # A non-root still waiting on an unlanded dep.
      waiting =
        member_in_stack!(project, stack_id, position: 5, status: "in_progress")
        |> add_dep!(parked)

      result = get_stack!(stack_id)

      refute done_root.id in result.executable_now
      assert live_root.id in result.executable_now
      assert promoted.id in result.executable_now
      refute parked.id in result.executable_now
      refute waiting.id in result.executable_now

      assert done_root.id in result.blocked_now
      assert parked.id in result.blocked_now
      assert member_entry(result, parked).blocked_by == []
      assert member_entry(result, parked).status == "stack_pending"
      assert waiting.id in result.blocked_now
      assert member_entry(result, waiting).blocked_by == [parked.id]

      # Partition: union covers ALL members, intersection empty.
      all_ids = result.members |> Enum.map(& &1.id) |> Enum.sort()
      assert length(result.members) == 5
      assert Enum.sort(result.executable_now ++ result.blocked_now) == all_ids
      assert result.executable_now -- result.blocked_now == result.executable_now
      assert result.blocked_now -- result.executable_now == result.blocked_now
    end
  end

  defp member_in_stack!(project, stack_id, opts) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Member #{System.unique_integer([:positive])}",
        status: Keyword.get(opts, :status, "backlog")
      })

    {:ok, task} =
      Tasks.update_task(task, %{
        stack_id: stack_id,
        stack_position: Keyword.get(opts, :position, 1)
      })

    Tasks.get_task_record(task.id)
  end
end
