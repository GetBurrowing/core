defmodule Platform.Federation.ToolSurfaceTest do
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Chat

  alias Platform.Tasks
  alias Platform.Federation.ToolSurface
  alias Platform.Repo

  defp create_space(attrs \\ %{}) do
    default = %{name: "Test", slug: unique_slug(), kind: "channel"}
    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  defp create_participant(space_id, attrs \\ %{}) do
    default = %{
      participant_type: "user",
      participant_id: Ecto.UUID.generate(),
      display_name: "Alice",
      joined_at: DateTime.utc_now()
    }

    {:ok, participant} = Chat.add_participant(space_id, Map.merge(default, attrs))
    participant
  end

  defp create_project(attrs \\ %{}) do
    default = %{name: "Test Project #{System.unique_integer([:positive])}"}
    {:ok, project} = Tasks.create_project(Map.merge(default, attrs))
    project
  end

  defp unique_slug, do: "test-#{System.unique_integer([:positive])}"

  # Insert a bare user row for sponsor-round-trip tests (ADR 0042).
  # Bypasses the `Platform.Accounts.User.changeset/2` name requirement
  # so tests don't need to plumb an OIDC identity fixture. Mirrors the
  # `insert_sponsor_user/1` helper in `task_test.exs`.
  defp insert_user_for_sponsor(opts \\ []) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: Keyword.get(opts, :name, "Sponsor #{n}"),
      email: Keyword.get(opts, :email, "sponsor-#{n}@example.com"),
      oidc_sub: "sub-sponsor-#{n}"
    })
  end

  describe "tool_definitions/0" do
    test "returns all 82 tools with required components" do
      tools = ToolSurface.tool_definitions()
      assert length(tools) == 82

      tool_names = Enum.map(tools, & &1.name)
      assert "send_media" in tool_names
      assert "react" in tool_names
      assert "canvas.versions" in tool_names
      assert "canvas.restore" in tool_names
      assert "space_list" in tool_names
      assert "space_list_agents" in tool_names
      assert "space_leave" in tool_names
      assert "canvas.create" in tool_names
      assert "canvas.patch" in tool_names
      assert "canvas.describe" in tool_names
      assert "canvas.list_kinds" in tool_names
      assert "canvas.template" in tool_names
      assert "skill.list" in tool_names
      assert "skill.get" in tool_names
      assert "skill.upsert" in tool_names
      assert "project_list" in tool_names
      assert "project_update" in tool_names
      assert "epic_list" in tool_names
      assert "epic_create" in tool_names
      assert "task_create" in tool_names
      assert "task_get" in tool_names
      assert "task_list" in tool_names
      assert "task_update" in tool_names
      assert "task_start" in tool_names
      assert "task_complete" in tool_names
      assert "task_dependencies" in tool_names
      assert "task_attach_canvas" in tool_names
      assert "task_detach_canvas" in tool_names
      assert "task_list_canvases" in tool_names
      assert "stack_create" in tool_names
      assert "stack_update" in tool_names
      assert "stack_get" in tool_names
      assert "stack_list" in tool_names
      assert "stack_add" in tool_names
      assert "stack_add_dependency" in tool_names
      assert "stack_remove_dependency" in tool_names
      assert "stack_eject" in tool_names
      assert "stack_abandon" in tool_names
      assert "stack_complete" in tool_names
      assert "stack_start" in tool_names
      assert "stack_start_planning" in tool_names
      assert "stack_assign_agents" in tool_names
      assert "meeting_create" in tool_names
      assert "plan_create" in tool_names
      assert "plan_get" in tool_names
      assert "plan_submit" in tool_names
      assert "stage_start" in tool_names
      assert "stage_list" in tool_names
      assert "validation_evaluate" in tool_names
      assert "validation_pass" in tool_names
      assert "stage_complete" in tool_names
      assert "report_blocker" in tool_names
      assert "validation_list" in tool_names
      assert "review_request_create" in tool_names
      assert "prompt_template_list" in tool_names
      assert "prompt_template_update" in tool_names
      assert "federation_status" in tool_names
      # Context read tools
      assert "space_get_context" in tool_names
      assert "space_search_messages" in tool_names
      assert "space_get_messages" in tool_names
      assert "canvas_list" in tool_names
      assert "canvas_get" in tool_names
      assert "principal_search" in tool_names
      assert "attachment.upload_inline" in tool_names
      assert "attachment.upload_start" in tool_names
      assert "attachment.get_inline" in tool_names
      # Files MCP bundle — six file_* tools (file_list + file_get_text predate this
      # task; file_get_metadata, file_search, file_add, file_delete landed via
      # task 019efba0 stages 1-4). Keep this set in sync with the registered
      # bundle in tool_surface.ex.
      assert "file_list" in tool_names
      assert "file_get_text" in tool_names
      assert "file_get_metadata" in tool_names
      assert "file_search" in tool_names
      assert "file_add" in tool_names
      assert "file_delete" in tool_names

      for tool <- tools do
        assert Map.has_key?(tool, :name)
        assert Map.has_key?(tool, :description)
        assert Map.has_key?(tool, :parameters)
        assert Map.has_key?(tool, :returns)
        assert Map.has_key?(tool, :limitations)
        assert Map.has_key?(tool, :when_to_use)
        assert Map.has_key?(tool, :bundle)
        assert tool.bundle in ToolSurface.all_bundles()
      end
    end
  end

  describe "list_tools/1" do
    test "scopes the surface to the requested bundles" do
      tools = ToolSurface.list_tools(["task"])
      names = Enum.map(tools, & &1.name)

      assert "task_create" in names
      assert "task_list" in names
      refute "canvas_create" in names
      refute "plan_create" in names
      assert Enum.all?(tools, &(&1.bundle == "task"))
    end

    test "returns the union when multiple bundles are requested" do
      tools = ToolSurface.list_tools(["federation", "messaging"])
      bundles = tools |> Enum.map(& &1.bundle) |> Enum.uniq() |> Enum.sort()

      assert bundles == ["federation", "messaging"]
      assert "federation_status" in Enum.map(tools, & &1.name)
      assert "send_media" in Enum.map(tools, & &1.name)
    end

    test "silently skips unknown bundle names" do
      known = ToolSurface.list_tools(["task"])
      mixed = ToolSurface.list_tools(["task", "does_not_exist"])

      assert known == mixed
    end

    test "returns an empty list for no bundles" do
      assert ToolSurface.list_tools([]) == []
    end

    test "matches tool_definitions/0 when all bundles are requested" do
      scoped = ToolSurface.list_tools(ToolSurface.all_bundles())
      full = ToolSurface.tool_definitions()

      assert Enum.map(scoped, & &1.name) |> Enum.sort() ==
               Enum.map(full, & &1.name) |> Enum.sort()
    end
  end

  describe "execute/3" do
    test "canvas_create creates a canvas and returns structured result" do
      space = create_space()
      participant = create_participant(space.id)

      context = %{
        space_id: space.id,
        agent_participant_id: participant.id
      }

      document = %{
        "version" => 1,
        "revision" => 1,
        "root" => %{
          "id" => "root",
          "type" => "stack",
          "props" => %{"gap" => 12},
          "children" => [
            %{
              "id" => "t",
              "type" => "table",
              "props" => %{
                "columns" => ["Name", "Owner"],
                "rows" => [%{"Name" => "One", "Owner" => "You"}]
              },
              "children" => []
            }
          ]
        },
        "theme" => %{},
        "bindings" => %{},
        "meta" => %{}
      }

      {:ok, result} =
        ToolSurface.execute(
          "canvas_create",
          %{
            "title" => "Test Table",
            "document" => document
          },
          context
        )

      assert result.kind == "stack"
      assert result.title == "Test Table"
      assert is_binary(result.id)
    end

    test "task_create creates a task with project_id" do
      project = create_project()

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Fix bug",
            "description" => "Something is broken"
          },
          %{}
        )

      assert result.title == "Fix bug"
      assert result.project_id == project.id
      assert result.status == "backlog"
      assert is_binary(result.id)
    end

    test "task_create without project_id returns error" do
      {:error, error} =
        ToolSurface.execute(
          "task_create",
          %{"title" => "No project"},
          %{}
        )

      assert error.error =~ "project_id"
      assert error.recoverable == true
    end

    # ── epic_create ──────────────────────────────────────────────────────

    test "epic_create creates an epic with project_id and name" do
      project = create_project()

      {:ok, result} =
        ToolSurface.execute(
          "epic_create",
          %{
            "project_id" => project.id,
            "name" => "Reskin Q3",
            "description" => "Quarter-three reskin work",
            "target_branch" => "feat/reskin",
            "deploy_target" => "exp"
          },
          %{}
        )

      assert result.name == "Reskin Q3"
      assert result.description == "Quarter-three reskin work"
      assert result.project_id == project.id
      assert result.status == "open"
      assert result.target_branch == "feat/reskin"
      assert result.deploy_target == "exp"
      assert is_binary(result.id)
    end

    test "epic_create without project_id returns error" do
      {:error, error} =
        ToolSurface.execute(
          "epic_create",
          %{"name" => "Orphan epic"},
          %{}
        )

      assert error.error =~ "project_id"
      assert error.recoverable == true
      assert error.suggestion =~ "project_id"
    end

    test "epic_create without name returns error" do
      project = create_project()

      {:error, error} =
        ToolSurface.execute(
          "epic_create",
          %{"project_id" => project.id},
          %{}
        )

      assert error.error =~ "name"
      assert error.recoverable == true
    end

    test "epic_create lands on epic_list for the project" do
      project = create_project()

      {:ok, created} =
        ToolSurface.execute(
          "epic_create",
          %{"project_id" => project.id, "name" => "Round-trip Epic"},
          %{}
        )

      {:ok, listed} =
        ToolSurface.execute(
          "epic_list",
          %{"project_id" => project.id},
          %{}
        )

      assert Enum.any?(listed, fn e -> e.id == created.id and e.name == "Round-trip Epic" end)
    end

    # ── meeting_create ───────────────────────────────────────────────────

    test "meeting_create creates a meeting and returns the meeting map" do
      project = create_project()

      {:ok, result} =
        ToolSurface.execute(
          "meeting_create",
          %{"project_id" => project.id, "name" => "Kickoff"},
          %{}
        )

      assert result.name == "Kickoff"
      assert result.slug == "kickoff"
      assert result.project_id == project.id
      assert result.status == "scheduled"
      assert is_binary(result.id)
      assert is_binary(result.chat_space_id)
      assert is_binary(result.livekit_room_name)
    end

    test "meeting_create defaults host_participant_id to the calling agent's principal participant" do
      project = create_project()
      agent = create_agent()

      {:ok, result} =
        ToolSurface.execute(
          "meeting_create",
          %{"project_id" => project.id, "name" => "Sync"},
          %{agent_id: agent.id}
        )

      assert is_binary(result.host_participant_id)

      participant = Chat.get_agent_participant(result.chat_space_id, agent.id)
      assert participant.id == result.host_participant_id
      assert participant.role == "principal"
    end

    test "meeting_create honors an explicit host_participant_id" do
      project = create_project()
      space = create_space()
      host = create_participant(space.id)

      {:ok, result} =
        ToolSurface.execute(
          "meeting_create",
          %{
            "project_id" => project.id,
            "name" => "Planning",
            "host_participant_id" => host.id
          },
          %{}
        )

      assert result.host_participant_id == host.id
    end

    test "meeting_create without project_id returns a recoverable error" do
      {:error, error} =
        ToolSurface.execute("meeting_create", %{"name" => "No project"}, %{})

      assert error.error =~ "project_id"
      assert error.recoverable == true
    end

    test "meeting_create with a colliding explicit slug returns a changeset error, not a crash" do
      project = create_project()

      {:ok, _first} =
        ToolSurface.execute(
          "meeting_create",
          %{"project_id" => project.id, "name" => "Retro", "slug" => "retro"},
          %{}
        )

      {:error, error} =
        ToolSurface.execute(
          "meeting_create",
          %{"project_id" => project.id, "name" => "Another Retro", "slug" => "retro"},
          %{}
        )

      assert error.error =~ "meeting"
      assert error.recoverable == true
    end

    test "task_get returns task details" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Test task"})

      {:ok, result} =
        ToolSurface.execute("task_get", %{"task_id" => task.id}, %{})

      assert result.id == task.id
      assert result.title == "Test task"
    end

    test "task_list returns tasks filtered by project" do
      project = create_project()
      {:ok, _} = Tasks.create_task(%{project_id: project.id, title: "Task A"})
      {:ok, _} = Tasks.create_task(%{project_id: project.id, title: "Task B"})

      {:ok, results} =
        ToolSurface.execute("task_list", %{"project_id" => project.id}, %{})

      assert length(results) == 2
    end

    test "task_list with project_id AND status composes filters — zero false positives (task 019e24ac)" do
      project = create_project()

      {:ok, _p1} =
        Tasks.create_task(%{project_id: project.id, title: "Planning 1", status: "planning"})

      {:ok, _p2} =
        Tasks.create_task(%{project_id: project.id, title: "Planning 2", status: "planning"})

      for n <- 1..4 do
        {:ok, _} =
          Tasks.create_task(%{project_id: project.id, title: "Done #{n}", status: "done"})
      end

      {:ok, results} =
        ToolSurface.execute(
          "task_list",
          %{"project_id" => project.id, "status" => "planning"},
          %{}
        )

      # The old mutually-exclusive `cond` dropped the status filter and
      # returned all 6 tasks. The composed query returns only the 2 planning.
      assert length(results) == 2
      assert Enum.all?(results, &(&1.status == "planning"))
      assert Enum.all?(results, &(&1.project_id == project.id))
    end

    test "task_list with epic_id AND status composes filters" do
      project = create_project()
      {:ok, epic} = Tasks.create_epic(%{project_id: project.id, name: "Epic E"})

      {:ok, _} =
        Tasks.create_task(%{
          project_id: project.id,
          epic_id: epic.id,
          title: "Planning",
          status: "planning"
        })

      {:ok, _} =
        Tasks.create_task(%{
          project_id: project.id,
          epic_id: epic.id,
          title: "Done",
          status: "done"
        })

      {:ok, results} =
        ToolSurface.execute(
          "task_list",
          %{"epic_id" => epic.id, "status" => "done"},
          %{}
        )

      assert length(results) == 1
      assert Enum.all?(results, &(&1.status == "done"))
    end

    test "task_list with no filters returns all non-deleted tasks" do
      project = create_project()
      {:ok, _} = Tasks.create_task(%{project_id: project.id, title: "Task A"})
      {:ok, deleted} = Tasks.create_task(%{project_id: project.id, title: "Deleted"})
      {:ok, _} = Tasks.soft_delete_task(deleted)

      {:ok, results} = ToolSurface.execute("task_list", %{}, %{})

      refute Enum.any?(results, &(&1.id == deleted.id))
      assert Enum.any?(results, &(&1.project_id == project.id))
    end

    test "task_update changes task fields" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Old title"})

      {:ok, result} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "title" => "New title", "priority" => "high"},
          %{}
        )

      assert result.title == "New title"
      assert result.priority == "high"
    end

    test "project_list returns projects" do
      _project = create_project(%{name: "Unique Project"})

      {:ok, results} = ToolSurface.execute("project_list", %{}, %{})

      assert is_list(results)
      assert Enum.any?(results, fn p -> p.name == "Unique Project" end)
    end

    test "task_update to cancelled succeeds from in_progress (task 019e24ac stage 3)" do
      # Regression: pre-stage-3 the agent-facing task_update returned
      # "Invalid status transition from 'in_progress' to 'cancelled'" because
      # `cancelled` was neither a valid Task.@statuses value nor a target in
      # @valid_task_transitions. Stage 3 made it the agent-reachable terminal
      # for fold/supersede; this test pins that the wire path actually flips.
      project = create_project()

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Doomed", status: "in_progress"})

      {:ok, result} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "status" => "cancelled"},
          %{}
        )

      assert result.status == "cancelled"
      assert Tasks.get_task_record(task.id).status == "cancelled"
    end

    test "task_update to cancelled succeeds from planning (the ghost-task path)" do
      project = create_project()

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Never approved", status: "planning"})

      {:ok, result} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "status" => "cancelled"},
          %{}
        )

      assert result.status == "cancelled"
    end

    test "task_update from cancelled to anything else returns invalid-transition error" do
      project = create_project()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Already retired",
          status: "cancelled"
        })

      {:error, error} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "status" => "in_progress"},
          %{}
        )

      assert error.recoverable == true
      assert error.error =~ "Invalid status transition from 'cancelled' to 'in_progress'"
    end

    test "task_update transitioning to deploying without a resolved target returns friendly envelope" do
      # v2 regression guard: pre-fix the `:no_deploy_target_resolved` atom
      # fell through to the changeset catch-all, whose inspect_errors/1
      # called Ecto.Changeset.traverse_errors/2 on an atom → runtime
      # crash. The dedicated branch turns that into a structured
      # error envelope callers can act on.
      # `deploy_config` defaults to %{} on the schema — no explicit set needed.
      project = create_project()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "No target anywhere",
          status: "in_review"
        })

      # `require_approved_plan_for/2` must not fire first and mask the
      # deploy-target guard we're testing.
      {:ok, _plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

      {:error, error} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "status" => "deploying"},
          %{}
        )

      assert error.error == "unresolved_deploy_target"
      assert error.recoverable == true
      assert is_binary(error.suggestion)
      assert error.suggestion =~ ~r/project_update|task_update/

      # Task did NOT transition.
      assert Tasks.get_task_record(task.id).status == "in_review"
    end

    test "task_list with status: 'cancelled' surfaces only cancelled tasks (stage 6 round-trip)" do
      # Stage 3 made `cancelled` an agent-reachable terminal status; this
      # asserts the tool-surface reverse direction — once a task is in
      # `cancelled`, the wire-level task_list can find it by status. Without
      # this an agent has no way to enumerate the cancelled (folded /
      # superseded) tasks it just retired, which would push them off the
      # list-tools surface entirely.
      project = create_project()

      {:ok, _live} =
        Tasks.create_task(%{project_id: project.id, title: "Live", status: "in_progress"})

      {:ok, cancelled1} =
        Tasks.create_task(%{project_id: project.id, title: "Folded 1", status: "cancelled"})

      {:ok, cancelled2} =
        Tasks.create_task(%{project_id: project.id, title: "Folded 2", status: "cancelled"})

      {:ok, results} =
        ToolSurface.execute(
          "task_list",
          %{"project_id" => project.id, "status" => "cancelled"},
          %{}
        )

      assert length(results) == 2
      assert Enum.all?(results, &(&1.status == "cancelled"))
      result_ids = Enum.map(results, & &1.id) |> MapSet.new()
      assert MapSet.equal?(result_ids, MapSet.new([cancelled1.id, cancelled2.id]))
    end

    test "task_list composes project_id + epic_id + status as a three-way AND (stage 6 lock-in)" do
      # Stage 2 fixed the two-filter `cond`; stage 6 pins the three-way
      # composition at the MCP boundary so a future refactor of the
      # tool_surface arg-stitching can't silently drop one of the three
      # filters. We seed deliberate near-misses for each axis.
      project = create_project()
      other_project = create_project()

      {:ok, epic} = Tasks.create_epic(%{project_id: project.id, name: "Target Epic"})
      {:ok, other_epic} = Tasks.create_epic(%{project_id: project.id, name: "Other Epic"})

      # The one row that matches all three filters.
      {:ok, target} =
        Tasks.create_task(%{
          project_id: project.id,
          epic_id: epic.id,
          title: "Target",
          status: "planning"
        })

      # Same epic, same project, wrong status.
      {:ok, _wrong_status} =
        Tasks.create_task(%{
          project_id: project.id,
          epic_id: epic.id,
          title: "Wrong status",
          status: "done"
        })

      # Same project, same status, wrong epic.
      {:ok, _wrong_epic} =
        Tasks.create_task(%{
          project_id: project.id,
          epic_id: other_epic.id,
          title: "Wrong epic",
          status: "planning"
        })

      # Same epic id is project-scoped, so a cross-project leak via epic_id
      # alone isn't really possible — but a row in the wrong project with
      # the same status is, and we want to make sure project_id holds.
      {:ok, _wrong_project} =
        Tasks.create_task(%{
          project_id: other_project.id,
          title: "Wrong project",
          status: "planning"
        })

      {:ok, results} =
        ToolSurface.execute(
          "task_list",
          %{
            "project_id" => project.id,
            "epic_id" => epic.id,
            "status" => "planning"
          },
          %{}
        )

      assert length(results) == 1
      [only] = results
      assert only.id == target.id
      assert only.status == "planning"
      assert only.epic_id == epic.id
      assert only.project_id == project.id
    end

    test "task_update sets deploy_target so the deploying-phase dispatch can pin a target" do
      # Regression: deploy_target was castable on the schema but not exposed
      # by task_update, leaving any task that auto-advanced to `deploying`
      # without a target stuck waiting for a UI/psql change.
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Deploy me"})

      {:ok, result} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "deploy_target" => "production"},
          %{}
        )

      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.deploy_target == "production"
      # The result map mirrors the existing task_update return shape; we
      # don't expand it here because the existing test above guards that
      # surface — only assert the new field round-trips through the DB.
      assert is_map(result)
    end

    # ── Sponsor (ADR 0042 — human shepherd) round-trip through MCP ────
    #
    # These tests pin the MCP wire contract for `sponsor_user_id` and,
    # importantly, the explicit-null-unset semantic in `task_update`. If
    # someone re-introduces a blanket `Map.reject(fn {_k, v} -> is_nil(v)
    # end)` in the `task_update` execute, the "unset" case here will go
    # red — that is the guard the stage-2 write-up calls out.

    test "task_create with sponsor_user_id round-trips through task_get" do
      project = create_project()
      user = insert_user_for_sponsor(name: "Sally Sponsor", email: "sally@example.com")

      {:ok, created} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Sponsored via MCP",
            "sponsor_user_id" => user.id
          },
          %{}
        )

      # Response envelope carries the sponsor shape immediately.
      assert created.sponsor == %{id: user.id, name: "Sally Sponsor", email: "sally@example.com"}

      # And a follow-up task_get sees the same shape.
      {:ok, fetched} =
        ToolSurface.execute("task_get", %{"task_id" => created.id}, %{})

      assert fetched.sponsor == %{
               id: user.id,
               name: "Sally Sponsor",
               email: "sally@example.com"
             }
    end

    test "task_create without sponsor_user_id yields sponsor: nil in the envelope" do
      project = create_project()

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{"project_id" => project.id, "title" => "Unsponsored"},
          %{}
        )

      assert Map.has_key?(result, :sponsor)
      assert result.sponsor == nil
    end

    test "task_get returns sponsor: nil for a task with no sponsor" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Bare task"})

      {:ok, result} = ToolSurface.execute("task_get", %{"task_id" => task.id}, %{})

      assert result.sponsor == nil
    end

    test "task_list includes sponsor per row (preloaded, no N+1)" do
      project = create_project()
      user = insert_user_for_sponsor(name: "Listy", email: "listy@example.com")

      {:ok, sponsored} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Has sponsor",
          sponsor_user_id: user.id
        })

      {:ok, _unsponsored} =
        Tasks.create_task(%{project_id: project.id, title: "No sponsor"})

      {:ok, results} =
        ToolSurface.execute("task_list", %{"project_id" => project.id}, %{})

      # Every row exposes the sponsor key (present-and-nil is part of
      # the contract, not just present-when-set).
      assert Enum.all?(results, &Map.has_key?(&1, :sponsor))

      by_id = Map.new(results, &{&1.id, &1})

      assert by_id[sponsored.id].sponsor == %{
               id: user.id,
               name: "Listy",
               email: "listy@example.com"
             }

      # The unsponsored task shows sponsor: nil, not a NotLoaded atom or
      # a missing key.
      other = Enum.find(results, &(&1.id != sponsored.id))
      assert other.sponsor == nil
    end

    test "task_update sets sponsor_user_id on an unsponsored task" do
      project = create_project()
      user = insert_user_for_sponsor(name: "Late Arrival")

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Add sponsor later"})
      assert task.sponsor_user_id == nil

      {:ok, result} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "sponsor_user_id" => user.id},
          %{}
        )

      assert result.sponsor.id == user.id
      assert result.sponsor.name == "Late Arrival"
      assert Tasks.get_task_record(task.id).sponsor_user_id == user.id
    end

    test "task_update with sponsor_user_id: nil CLEARS the sponsor — explicit-null-unset contract" do
      # THIS is the landmine test. Pre-stage-2 the `task_update` execute
      # ran `Map.reject(fn {_k, v} -> is_nil(v) end)` on the take'd
      # attrs, which silently dropped an explicit `sponsor_user_id:
      # nil`. That meant an agent had NO wire-level way to unset the
      # sponsor — you'd have to psql-poke the row. The stage-2 fix keeps
      # nil for keys in the explicitly-nilable allow-list. If a future
      # PR re-adds the blanket reject, THIS test goes red.
      project = create_project()
      user = insert_user_for_sponsor()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Sponsored, then cleared",
          sponsor_user_id: user.id
        })

      assert task.sponsor_user_id == user.id

      {:ok, result} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "sponsor_user_id" => nil},
          %{}
        )

      # Response envelope shows the cleared state.
      assert result.sponsor == nil

      # DB reflects the clear too — not just the envelope.
      assert Tasks.get_task_record(task.id).sponsor_user_id == nil
    end

    test "task_update without sponsor_user_id in args leaves sponsor untouched" do
      # The other half of the explicit-null-unset contract: "key absent"
      # is NOT the same as "key present with null". Omission means
      # "don't touch", null means "clear". If someone naively read the
      # value with `Map.get(args, \"sponsor_user_id\")` and treated the
      # returned nil as an unset request, an unrelated field update
      # would clobber an existing sponsor.
      project = create_project()
      user = insert_user_for_sponsor()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Sponsored, untouched by title change",
          sponsor_user_id: user.id
        })

      {:ok, result} =
        ToolSurface.execute(
          "task_update",
          # Note: no sponsor_user_id key here — we're only bumping the title.
          %{"task_id" => task.id, "title" => "New title"},
          %{}
        )

      assert result.title == "New title"
      assert result.sponsor.id == user.id
      assert Tasks.get_task_record(task.id).sponsor_user_id == user.id
    end

    test "task_update rejects an unknown sponsor_user_id with a recoverable FK error" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Bad sponsor pointer"})

      bogus_user_id = Ecto.UUID.generate()

      {:error, error} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "sponsor_user_id" => bogus_user_id},
          %{}
        )

      assert error.recoverable == true
      assert error.error =~ "sponsor_user_id" or error.error =~ "does not exist"
      # DB state unchanged.
      assert Tasks.get_task_record(task.id).sponsor_user_id == nil
    end

    test "task_create with an unknown sponsor_user_id returns a recoverable error" do
      project = create_project()
      bogus_user_id = Ecto.UUID.generate()

      {:error, error} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Bad sponsor at create time",
            "sponsor_user_id" => bogus_user_id
          },
          %{}
        )

      assert error.recoverable == true
      assert error.error =~ "sponsor_user_id" or error.error =~ "does not exist"
    end

    test "task_update swaps sponsor from one user to another" do
      project = create_project()
      first = insert_user_for_sponsor(name: "First")
      second = insert_user_for_sponsor(name: "Second")

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Swap sponsor",
          sponsor_user_id: first.id
        })

      {:ok, result} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "sponsor_user_id" => second.id},
          %{}
        )

      assert result.sponsor.id == second.id
      assert result.sponsor.name == "Second"
      assert Tasks.get_task_record(task.id).sponsor_user_id == second.id
    end

    test "tool definitions expose sponsor_user_id on task_create and task_update" do
      # Pin the wire contract so an accidental parameter-map refactor
      # doesn't silently drop the sponsor field. The MCP surface is the
      # only contract downstream tools inspect.
      tools = ToolSurface.tool_definitions()

      task_create = Enum.find(tools, &(&1.name == "task_create"))
      task_update = Enum.find(tools, &(&1.name == "task_update"))

      assert Map.has_key?(task_create.parameters, :sponsor_user_id)
      assert task_create.parameters.sponsor_user_id.required == false

      assert Map.has_key?(task_update.parameters, :sponsor_user_id)
      assert task_update.parameters.sponsor_user_id.required == false
    end

    # ── ADR 0044: deploy_target + phase_assignees canonical shape ────
    #
    # Stage 2 of task 019f42fd consolidates task_create + task_update
    # through `Platform.Federation.TaskAttrs.build_task_attrs/3`. These
    # tests pin the new MCP wire contract:
    #
    #   * `deploy_target` on task_create (parity with task_update).
    #   * `phase_assignees` on both, as the granular per-phase writer.
    #   * Flat `assignee_id + assignee_type` auto-routing into
    #     `phase_assignees[current_phase(task)]` on both create and
    #     update — the "silent-clobber-on-phase-transition" fix.
    #
    # If a future PR bypasses the shared helper on either handler, these
    # tests will go red.

    test "tool definitions expose deploy_target + phase_assignees on task_create" do
      tools = ToolSurface.tool_definitions()
      task_create = Enum.find(tools, &(&1.name == "task_create"))

      assert Map.has_key?(task_create.parameters, :deploy_target)
      assert task_create.parameters.deploy_target.type == "string"
      assert task_create.parameters.deploy_target.required == false

      assert Map.has_key?(task_create.parameters, :phase_assignees)
      assert task_create.parameters.phase_assignees.type == "object"
      assert task_create.parameters.phase_assignees.required == false
    end

    test "tool definitions expose phase_assignees on task_update" do
      tools = ToolSurface.tool_definitions()
      task_update = Enum.find(tools, &(&1.name == "task_update"))

      assert Map.has_key?(task_update.parameters, :phase_assignees)
      assert task_update.parameters.phase_assignees.type == "object"
      assert task_update.parameters.phase_assignees.required == false
    end

    test "task_create with deploy_target persists the field" do
      # Parity gap fix: previously deploy_target was only writable via
      # task_update, forcing agents into a two-call dance to author a
      # task destined for a specific target.
      project = create_project()

      {:ok, created} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Ships to exp",
            "deploy_target" => "exp"
          },
          %{}
        )

      # Response envelope doesn't currently expose deploy_target
      # (serialize_task doesn't include it), but the DB record must.
      assert Tasks.get_task_record(created.id).deploy_target == "exp"
    end

    test "task_create with empty deploy_target drops the value (empty-string clears)" do
      # `TaskAttrs.emptystring_clears` normalizes "" → nil; in :create
      # mode nil is dropped so the DB default (nil) applies.
      project = create_project()

      {:ok, created} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "No target",
            "deploy_target" => ""
          },
          %{}
        )

      assert Tasks.get_task_record(created.id).deploy_target == nil
    end

    test "task_create with phase_assignees only writes into the phase_assignees jsonb" do
      # Structured phase_assignees is the canonical writer. When no
      # flat assignee is present, the derived flat pointer stays nil
      # unless the current phase (planning for new tasks) has an entry.
      project = create_project()
      agent = create_agent()

      {:ok, created} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Granular phase assignment",
            "phase_assignees" => %{
              "execution" => %{
                "assignee_id" => agent.id,
                "assignee_type" => "agent"
              }
            }
          },
          %{}
        )

      reloaded = Tasks.get_task_record(created.id)

      assert reloaded.phase_assignees == %{
               "execution" => %{
                 "assignee_id" => agent.id,
                 "assignee_type" => "agent"
               }
             }

      # Current phase for a fresh task is "planning" (status
      # defaults to "backlog"), which has no phase_assignees entry —
      # so the derived flat pointer is nil.
      assert reloaded.assignee_id == nil
      assert reloaded.assignee_type == nil
    end

    test "task_create with only flat assignee auto-routes into phase_assignees[\"planning\"]" do
      # THIS is the silent-clobber fix. Pre-stage-2, a flat
      # `assignee_id + assignee_type` on task_create wrote straight to
      # the top-level columns — which then got clobbered on the first
      # phase transition because `derive_assignee_from_phase_assignees`
      # only saw an empty phase_assignees map. After stage 2, the flat
      # pair is lifted into `phase_assignees["planning"]` so the
      # derivation stays correct across transitions.
      project = create_project()
      agent = create_agent()

      {:ok, created} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Flat assignee auto-routes",
            "assignee_id" => agent.id,
            "assignee_type" => "agent"
          },
          %{}
        )

      reloaded = Tasks.get_task_record(created.id)

      # phase_assignees now carries the planning slot ─ the fix.
      assert reloaded.phase_assignees == %{
               "planning" => %{
                 "assignee_id" => agent.id,
                 "assignee_type" => "agent"
               }
             }

      # Flat pointer is re-derived by `set_phase_assignees/2` from the
      # current phase (planning). Same value; source of truth is now
      # the phase-map.
      assert reloaded.assignee_id == agent.id
      assert reloaded.assignee_type == "agent"
    end

    test "task_update with phase_assignees writes only the supplied slot" do
      # Merge (not replace) semantics — set_phase_assignees does a
      # Map.merge onto the existing map so callers can target one slot
      # without disturbing others.
      project = create_project()
      planner = create_agent(%{slug: "planner-#{System.unique_integer([:positive])}"})
      reviewer = create_agent(%{slug: "reviewer-#{System.unique_integer([:positive])}"})

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "phase merge"})

      {:ok, task} =
        Tasks.set_phase_assignees(task, %{
          "planning" => %{"assignee_id" => planner.id, "assignee_type" => "agent"}
        })

      # Sanity: planning slot present before update.
      assert task.phase_assignees["planning"]["assignee_id"] == planner.id

      {:ok, _result} =
        ToolSurface.execute(
          "task_update",
          %{
            "task_id" => task.id,
            "phase_assignees" => %{
              "review" => %{"assignee_id" => reviewer.id, "assignee_type" => "agent"}
            }
          },
          %{}
        )

      reloaded = Tasks.get_task_record(task.id)

      # Both slots present; the planning slot survived the review write.
      assert reloaded.phase_assignees["planning"]["assignee_id"] == planner.id
      assert reloaded.phase_assignees["review"]["assignee_id"] == reviewer.id
    end

    test "task_update flat assignee on in_progress task auto-routes to execution slot" do
      # Current-phase resolution: a task at status in_progress has
      # current_phase "execution", so a flat assignee write on
      # task_update lifts into phase_assignees["execution"].
      project = create_project()
      executor = create_agent()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "In progress reassignment",
          status: "in_progress"
        })

      assert task.status == "in_progress"

      {:ok, _result} =
        ToolSurface.execute(
          "task_update",
          %{
            "task_id" => task.id,
            "assignee_id" => executor.id,
            "assignee_type" => "agent"
          },
          %{}
        )

      reloaded = Tasks.get_task_record(task.id)

      # Executor lifted into the execution slot (matches current_phase).
      assert reloaded.phase_assignees == %{
               "execution" => %{
                 "assignee_id" => executor.id,
                 "assignee_type" => "agent"
               }
             }

      # Derived flat pointer picks up the execution slot.
      assert reloaded.assignee_id == executor.id
      assert reloaded.assignee_type == "agent"
    end

    test "task_update with both flat and phase_assignees — phase_assignees wins" do
      # ADR 0044 tie-breaker: structured wins, flat is silently dropped.
      # Same contract as build_task_attrs (verified by TaskAttrsTest);
      # this pins the same contract at the MCP boundary.
      project = create_project()
      flat_agent = create_agent()
      granular_agent = create_agent()

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Tie-breaker"})

      {:ok, _result} =
        ToolSurface.execute(
          "task_update",
          %{
            "task_id" => task.id,
            "assignee_id" => flat_agent.id,
            "assignee_type" => "agent",
            "phase_assignees" => %{
              "planning" => %{
                "assignee_id" => granular_agent.id,
                "assignee_type" => "agent"
              }
            }
          },
          %{}
        )

      reloaded = Tasks.get_task_record(task.id)

      # Structured input wins; the flat pair was silently dropped.
      assert reloaded.phase_assignees == %{
               "planning" => %{
                 "assignee_id" => granular_agent.id,
                 "assignee_type" => "agent"
               }
             }

      assert reloaded.assignee_id == granular_agent.id
    end

    test "task_update with unknown phase_assignees key returns a recoverable error" do
      # The helper validates phase names; the handler surfaces the
      # error as a recoverable envelope rather than an Ecto changeset.
      project = create_project()
      agent = create_agent()

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Bad phase"})

      {:error, error} =
        ToolSurface.execute(
          "task_update",
          %{
            "task_id" => task.id,
            "phase_assignees" => %{
              "shipping" => %{"assignee_id" => agent.id, "assignee_type" => "agent"}
            }
          },
          %{}
        )

      assert error.recoverable == true
      assert error.error =~ "phase_assignees"
      # DB unchanged.
      assert Tasks.get_task_record(task.id).phase_assignees in [nil, %{}]
    end

    test "task_create with unknown phase_assignees key returns a recoverable error" do
      project = create_project()
      agent = create_agent()

      {:error, error} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Bad phase at create",
            "phase_assignees" => %{
              "shipping" => %{"assignee_id" => agent.id, "assignee_type" => "agent"}
            }
          },
          %{}
        )

      assert error.recoverable == true
      assert error.error =~ "phase_assignees"
    end

    test "task_update with only title untouched leaves phase_assignees alone" do
      # Regression: title-only updates must not clobber phase_assignees.
      # (`Map.take/2` at the helper strips unknown keys, and `phase_attrs`
      # falls through as `nil` when the caller didn't supply either flat
      # or structured assignee input.)
      project = create_project()
      agent = create_agent()

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Original"})

      {:ok, task} =
        Tasks.set_phase_assignees(task, %{
          "execution" => %{"assignee_id" => agent.id, "assignee_type" => "agent"}
        })

      original_phase_assignees = task.phase_assignees

      {:ok, result} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "title" => "Renamed"},
          %{}
        )

      reloaded = Tasks.get_task_record(task.id)
      assert result.title == "Renamed"
      assert reloaded.phase_assignees == original_phase_assignees
    end

    # ── auto_approve_plan (task 019f25f2) — MCP wire contract ──────────
    #
    # Pins the MCP-side plumbing for the auto-approve-plan opt-in flag:
    # the parameter is exposed on task_create, the value round-trips
    # through the returned envelope, and omission normalizes to false so
    # the DB default matches. Stage-4 UI + stage-5 serializer both rely
    # on the returned map exposing the field.

    test "task_create with auto_approve_plan: true persists and returns the flag" do
      project = create_project()
      agent = create_agent()

      # Task 019f5145 hardened the precondition: auto_approve_plan: true
      # requires agent-typed assignees on BOTH execution + review phases
      # (flat assignee_id only auto-routes to planning per ADR 0044).
      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Auto-approved",
            "auto_approve_plan" => true,
            "phase_assignees" => %{
              "planning" => %{"assignee_id" => agent.id, "assignee_type" => "agent"},
              "execution" => %{"assignee_id" => agent.id, "assignee_type" => "agent"},
              "review" => %{"assignee_id" => agent.id, "assignee_type" => "agent"}
            }
          },
          %{}
        )

      assert result.auto_approve_plan == true
      assert Tasks.get_task_record(result.id).auto_approve_plan == true
    end

    # Guards the tool-surface contract added 2026-07-08 and hardened
    # 2026-07-11 (task 019f5145): setting auto_approve_plan without an
    # agent assignee on BOTH execution + review silently stalled the
    # plan-engine downstream of planning (plan flips to approved but no
    # planner picks it up for the next phase).
    test "task_create with auto_approve_plan: true and no assignee is refused" do
      project = create_project()

      assert {:error, envelope} =
               ToolSurface.execute(
                 "task_create",
                 %{
                   "project_id" => project.id,
                   "title" => "Auto-approved no assignee",
                   "auto_approve_plan" => true
                 },
                 %{}
               )

      assert envelope.code == :auto_approve_precondition_missing
      assert envelope.missing_phases == ["execution", "review"]
      assert envelope.recoverable == true
      assert envelope.error =~ "execution"
      assert envelope.error =~ "review"
    end

    test "task_create with auto_approve_plan: true and a user (non-agent) assignee is refused" do
      project = create_project()
      user = insert_user_for_sponsor()

      assert {:error, envelope} =
               ToolSurface.execute(
                 "task_create",
                 %{
                   "project_id" => project.id,
                   "title" => "Auto-approved user assignee",
                   "auto_approve_plan" => true,
                   "assignee_id" => user.id,
                   "assignee_type" => "user"
                 },
                 %{}
               )

      # Flat assignee_id + assignee_type auto-routes into planning only
      # (per ADR 0044), so execution + review remain absent regardless of
      # whether the flat pair was user- or agent-typed.
      assert envelope.code == :auto_approve_precondition_missing
      assert envelope.missing_phases == ["execution", "review"]
      assert envelope.recoverable == true
    end

    test "task_create without auto_approve_plan defaults to false in the envelope" do
      project = create_project()

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{"project_id" => project.id, "title" => "Default flag"},
          %{}
        )

      assert Map.has_key?(result, :auto_approve_plan)
      assert result.auto_approve_plan == false
      assert Tasks.get_task_record(result.id).auto_approve_plan == false
    end

    test "task_create with auto_approve_plan: false explicit yields false" do
      project = create_project()

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Explicit false",
            "auto_approve_plan" => false
          },
          %{}
        )

      assert result.auto_approve_plan == false
      assert Tasks.get_task_record(result.id).auto_approve_plan == false
    end

    test "tool definitions expose auto_approve_plan on task_create" do
      # Pin the wire contract so an accidental parameter-map refactor
      # doesn't silently drop the flag — parity with the sponsor pin
      # above.
      tools = ToolSurface.tool_definitions()
      task_create = Enum.find(tools, &(&1.name == "task_create"))

      assert Map.has_key?(task_create.parameters, :auto_approve_plan)
      assert task_create.parameters.auto_approve_plan.type == "boolean"
      assert task_create.parameters.auto_approve_plan.required == false
    end

    test "task_get exposes auto_approve_plan on the read envelope (task 019f25f2 stage 5)" do
      # Stage 3 threaded the flag through the `task_create` response
      # envelope; stage 5 threads it through the shared `serialize_task/1`
      # helper so downstream reads (`task_get`, `task_list`) see the same
      # flag. Pin both the flag-on and flag-off shapes so an accidental
      # drop from the serializer surfaces here.
      project = create_project()

      {:ok, on_task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Auto-approve task",
          auto_approve_plan: true
        })

      {:ok, off_task} =
        Tasks.create_task(%{project_id: project.id, title: "Manual-approve task"})

      {:ok, on_result} =
        ToolSurface.execute("task_get", %{"task_id" => on_task.id}, %{})

      {:ok, off_result} =
        ToolSurface.execute("task_get", %{"task_id" => off_task.id}, %{})

      assert Map.has_key?(on_result, :auto_approve_plan)
      assert on_result.auto_approve_plan == true
      assert off_result.auto_approve_plan == false
    end

    test "task_list carries auto_approve_plan per row (task 019f25f2 stage 5)" do
      # `task_list` streams tasks through the same `serialize_task/1`
      # helper as `task_get`, so any dashboard/inbox that renders the flag
      # inline (rather than round-tripping to `task_get`) gets it for free.
      project = create_project()

      {:ok, _on} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Auto on",
          auto_approve_plan: true
        })

      {:ok, _off} = Tasks.create_task(%{project_id: project.id, title: "Auto off"})

      {:ok, results} =
        ToolSurface.execute("task_list", %{"project_id" => project.id}, %{})

      assert length(results) == 2
      assert Enum.all?(results, &Map.has_key?(&1, :auto_approve_plan))
      assert Enum.any?(results, &(&1.auto_approve_plan == true))
      assert Enum.any?(results, &(&1.auto_approve_plan == false))
    end

    test "plan_get exposes auto_approved_at on the read envelope (task 019f25f2 stage 5)" do
      # Manually-approved plans land `approved_at` but leave
      # `auto_approved_at` nil — the timestamp is only stamped when the
      # `auto_approve_plan` flag routes through `approve_plan(_, _,
      # auto: true)`. Pin both shapes so operators can tell a system
      # approval from a human one on the wire.
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Manual-approve plan"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.submit_plan_for_review(plan)
      {:ok, _plan} = Tasks.approve_plan(plan, "00000000-0000-0000-0000-000000000001")

      {:ok, result} =
        ToolSurface.execute("plan_get", %{"task_id" => task.id}, %{})

      assert Map.has_key?(result, :auto_approved_at)
      assert result.auto_approved_at == nil
      refute is_nil(result.approved_at)
    end

    # ── auto_approve_plan hardened precondition (task 019f5145) ────────
    #
    # Task 019f5145 stage 1 lifted the check into
    # `Platform.Federation.TaskAttrs.check_auto_approve_preconditions/4`
    # and now hard-rejects any auto_approve_plan=true write when either
    # the execution OR review phase slot does not resolve to a live
    # agent. Pin the tool-surface envelope + persistence behavior on both
    # `task_create` and `task_update`.

    test "task_create with phase_assignees for all three phases persists successfully" do
      project = create_project()
      planner = create_agent(%{slug: "planner-#{System.unique_integer([:positive])}"})
      executor = create_agent(%{slug: "executor-#{System.unique_integer([:positive])}"})
      reviewer = create_agent(%{slug: "reviewer-#{System.unique_integer([:positive])}"})

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Fully-staffed auto-approve",
            "auto_approve_plan" => true,
            "phase_assignees" => %{
              "planning" => %{"assignee_id" => planner.id, "assignee_type" => "agent"},
              "execution" => %{"assignee_id" => executor.id, "assignee_type" => "agent"},
              "review" => %{"assignee_id" => reviewer.id, "assignee_type" => "agent"}
            }
          },
          %{}
        )

      assert result.auto_approve_plan == true

      reloaded = Tasks.get_task_record(result.id)
      assert reloaded.auto_approve_plan == true
      assert reloaded.phase_assignees["planning"]["assignee_id"] == planner.id
      assert reloaded.phase_assignees["execution"]["assignee_id"] == executor.id
      assert reloaded.phase_assignees["review"]["assignee_id"] == reviewer.id
    end

    test "task_create with flat assignee_id only + auto_approve_plan: true rejects" do
      # Flat pair auto-routes into planning (per ADR 0044) — execution
      # and review stay absent, so the precondition fires and nothing
      # is written to the DB.
      project = create_project()
      agent = create_agent()

      assert {:error, envelope} =
               ToolSurface.execute(
                 "task_create",
                 %{
                   "project_id" => project.id,
                   "title" => "Flat-only auto-approve",
                   "auto_approve_plan" => true,
                   "assignee_id" => agent.id,
                   "assignee_type" => "agent"
                 },
                 %{}
               )

      assert envelope.code == :auto_approve_precondition_missing
      assert envelope.missing_phases == ["execution", "review"]
      assert envelope.recoverable == true

      # DB unchanged — precondition fires before `Tasks.create_task/1`.
      assert Tasks.list_tasks(project_id: project.id) == []
    end

    test "task_create with planning+execution but missing review rejects with review-only" do
      project = create_project()
      planner = create_agent(%{slug: "planner-#{System.unique_integer([:positive])}"})
      executor = create_agent(%{slug: "executor-#{System.unique_integer([:positive])}"})

      assert {:error, envelope} =
               ToolSurface.execute(
                 "task_create",
                 %{
                   "project_id" => project.id,
                   "title" => "Missing reviewer",
                   "auto_approve_plan" => true,
                   "phase_assignees" => %{
                     "planning" => %{"assignee_id" => planner.id, "assignee_type" => "agent"},
                     "execution" => %{"assignee_id" => executor.id, "assignee_type" => "agent"}
                   }
                 },
                 %{}
               )

      assert envelope.code == :auto_approve_precondition_missing
      assert envelope.missing_phases == ["review"]
      assert Tasks.list_tasks(project_id: project.id) == []
    end

    test "task_create with user-typed execution slot rejects execution missing" do
      # Users NEVER satisfy the precondition — even a valid user id in
      # the execution slot resolves to :non_agent_type.
      project = create_project()
      user = insert_user_for_sponsor()
      planner = create_agent(%{slug: "planner-#{System.unique_integer([:positive])}"})
      reviewer = create_agent(%{slug: "reviewer-#{System.unique_integer([:positive])}"})

      assert {:error, envelope} =
               ToolSurface.execute(
                 "task_create",
                 %{
                   "project_id" => project.id,
                   "title" => "User executor",
                   "auto_approve_plan" => true,
                   "phase_assignees" => %{
                     "planning" => %{"assignee_id" => planner.id, "assignee_type" => "agent"},
                     "execution" => %{"assignee_id" => user.id, "assignee_type" => "user"},
                     "review" => %{"assignee_id" => reviewer.id, "assignee_type" => "agent"}
                   }
                 },
                 %{}
               )

      assert envelope.code == :auto_approve_precondition_missing
      assert envelope.missing_phases == ["execution"]
      assert Tasks.list_tasks(project_id: project.id) == []
    end

    test "task_update flipping auto_approve_plan on with no phase_assignees rejects" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Flip on"})
      assert task.auto_approve_plan == false

      assert {:error, envelope} =
               ToolSurface.execute(
                 "task_update",
                 %{"task_id" => task.id, "auto_approve_plan" => true},
                 %{}
               )

      assert envelope.code == :auto_approve_precondition_missing
      assert envelope.missing_phases == ["execution", "review"]
      assert envelope.recoverable == true

      # Task unchanged — the changeset writer never ran.
      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.auto_approve_plan == false
    end

    test "task_update title-only on a fully-staffed auto-approve task succeeds" do
      # Regression: no toggle, no phase_attrs → gate stays closed.
      # `task_update(title: "Renamed")` on a task already satisfying the
      # invariant must NOT re-run the check.
      project = create_project()
      planner = create_agent(%{slug: "planner-#{System.unique_integer([:positive])}"})
      executor = create_agent(%{slug: "executor-#{System.unique_integer([:positive])}"})
      reviewer = create_agent(%{slug: "reviewer-#{System.unique_integer([:positive])}"})

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Original",
          auto_approve_plan: true
        })

      {:ok, task} =
        Tasks.set_phase_assignees(task, %{
          "planning" => %{"assignee_id" => planner.id, "assignee_type" => "agent"},
          "execution" => %{"assignee_id" => executor.id, "assignee_type" => "agent"},
          "review" => %{"assignee_id" => reviewer.id, "assignee_type" => "agent"}
        })

      original_phase_assignees = task.phase_assignees

      {:ok, result} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "title" => "Renamed"},
          %{}
        )

      assert result.title == "Renamed"

      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.auto_approve_plan == true
      assert reloaded.phase_assignees == original_phase_assignees
    end

    test "task_update explicit auto_approve_plan: false on a partial-phase task succeeds" do
      # Explicit-false always skips the precondition — this is the
      # unwind path for a task previously configured for auto-approve.
      project = create_project()
      planner = create_agent(%{slug: "planner-#{System.unique_integer([:positive])}"})

      # Seed a task with auto_approve_plan already true (bypassing the
      # tool surface via the direct writer) so we can flip it OFF.
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Turn it off",
          auto_approve_plan: true
        })

      {:ok, _task} =
        Tasks.set_phase_assignees(task, %{
          "planning" => %{"assignee_id" => planner.id, "assignee_type" => "agent"}
        })

      {:ok, _result} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "auto_approve_plan" => false},
          %{}
        )

      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.auto_approve_plan == false
      # Phase_assignees preserved through the toggle.
      assert reloaded.phase_assignees["planning"]["assignee_id"] == planner.id
    end

    test "plan_get stamps auto_approved_at when the plan was auto-approved (task 019f25f2 stage 5)" do
      # End-to-end: create an auto-approve task with the assignees the
      # precondition requires, submit a plan with a stage, and confirm
      # the `plan_get` envelope carries the auto-approval timestamp.
      project = create_project()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Auto-approve plan flow",
          auto_approve_plan: true,
          assignee_type: "agent",
          assignee_id: "00000000-0000-0000-0000-000000000001"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

      {:ok, _stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          name: "Execute",
          description: "Do the thing",
          position: 1
        })

      {:ok, plan} = Tasks.submit_plan_for_review(plan)

      assert plan.status == "approved",
             "precondition should route submit → auto-approve; got #{plan.status}"

      {:ok, result} =
        ToolSurface.execute("plan_get", %{"task_id" => task.id}, %{})

      assert result.status == "approved"
      refute is_nil(result.auto_approved_at)
      assert is_binary(result.auto_approved_at)
    end

    test "project_update sets deploy_config.default_strategy" do
      project = create_project(%{name: "Default-strategy project"})

      {:ok, result} =
        ToolSurface.execute(
          "project_update",
          %{
            "project_id" => project.id,
            "deploy_config" => %{"default_strategy" => %{"type" => "pr_merge"}}
          },
          %{}
        )

      assert result.deploy_config["default_strategy"] == %{"type" => "pr_merge"}

      reloaded = Tasks.get_project(project.id)
      assert reloaded.deploy_config["default_strategy"] == %{"type" => "pr_merge"}
    end

    test "project_update rejects unknown deploy strategy types with a recoverable error" do
      project = create_project()

      {:error, error} =
        ToolSurface.execute(
          "project_update",
          %{
            "project_id" => project.id,
            "deploy_config" => %{"default_strategy" => %{"type" => "definitely-not-a-strategy"}}
          },
          %{}
        )

      assert error.recoverable == true
      assert error.error =~ "unknown strategy type"
    end

    test "project_update returns not-found error for unknown project_id" do
      {:error, error} =
        ToolSurface.execute("project_update", %{"project_id" => Ecto.UUID.generate()}, %{})

      assert error.recoverable == false
      assert error.error =~ "Project not found"
    end

    test "unknown tool returns structured error" do
      {:error, error} = ToolSurface.execute("nonexistent", %{}, %{})
      assert error.error =~ "Unknown tool"
      assert error.recoverable == false
    end

    # ── Plan tools ──────────────────────────────────────────────────────

    test "plan_create creates a plan with stages and validations" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Plan task"})

      {:ok, result} =
        ToolSurface.execute(
          "plan_create",
          %{
            "task_id" => task.id,
            "stages" => [
              %{
                "name" => "Build",
                "description" => "Build the thing",
                "position" => 1,
                "validations" => [%{"kind" => "ci_check"}, %{"kind" => "test_pass"}]
              },
              %{
                "name" => "Review",
                "description" => "Review the thing",
                "position" => 2,
                "validations" => [%{"kind" => "code_review"}]
              }
            ]
          },
          %{}
        )

      assert result.task_id == task.id
      assert result.status == "draft"
      assert length(result.stages) == 2

      build_stage = Enum.find(result.stages, &(&1.name == "Build"))
      assert length(build_stage.validations) == 2
      assert Enum.any?(build_stage.validations, &(&1.kind == "ci_check"))

      review_stage = Enum.find(result.stages, &(&1.name == "Review"))
      assert length(review_stage.validations) == 1
    end

    test "plan_create without task_id returns error" do
      {:error, error} =
        ToolSurface.execute("plan_create", %{"stages" => []}, %{})

      assert error.recoverable == true
    end

    test "plan_get returns current approved plan" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Plan task"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.submit_plan_for_review(plan)
      {:ok, _plan} = Tasks.approve_plan(plan, "00000000-0000-0000-0000-000000000001")

      {:ok, result} =
        ToolSurface.execute("plan_get", %{"task_id" => task.id}, %{})

      assert result.task_id == task.id
      assert result.status == "approved"
    end

    test "plan_get with no approved plan returns error" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "No plan"})

      {:error, error} =
        ToolSurface.execute("plan_get", %{"task_id" => task.id}, %{})

      assert error.error =~ "No approved plan"
      assert error.recoverable == false
    end

    test "plan_submit transitions draft to pending_review" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Submit task"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

      {:ok, result} =
        ToolSurface.execute("plan_submit", %{"plan_id" => plan.id}, %{})

      assert result.status == "pending_review"
    end

    test "plan_submit on non-draft plan returns error" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Submit task"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.submit_plan_for_review(plan)

      {:error, error} =
        ToolSurface.execute("plan_submit", %{"plan_id" => plan.id}, %{})

      assert error.error =~ "draft"
    end

    test "plan_submit with unknown plan_id returns error" do
      {:error, error} =
        ToolSurface.execute("plan_submit", %{"plan_id" => Ecto.UUID.generate()}, %{})

      assert error.error =~ "Plan not found"
    end

    # ── Stage tools ─────────────────────────────────────────────────────

    test "stage_list returns stages with validations" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Stage task"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, name: "Build", position: 1})
      {:ok, _val} = Tasks.create_validation(%{stage_id: stage.id, kind: "ci_check"})

      {:ok, results} =
        ToolSurface.execute("stage_list", %{"plan_id" => plan.id}, %{})

      assert length(results) == 1
      assert hd(results).name == "Build"
      assert length(hd(results).validations) == 1
    end

    test "stage_start transitions pending to running" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Start task"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, name: "Build", position: 1})

      {:ok, result} =
        ToolSurface.execute("stage_start", %{"stage_id" => stage.id}, %{})

      assert result.status == "running"
      assert result.name == "Build"
    end

    # ── Validation tools ────────────────────────────────────────────────

    test "validation_list returns validations for a stage" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Val task"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, name: "Build", position: 1})
      {:ok, _} = Tasks.create_validation(%{stage_id: stage.id, kind: "ci_check"})
      {:ok, _} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

      {:ok, results} =
        ToolSurface.execute("validation_list", %{"stage_id" => stage.id}, %{})

      assert length(results) == 2
    end

    test "validation_evaluate records passed result" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Eval task"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, name: "Build", position: 1})
      # Start the stage so validations can be evaluated
      {:ok, _} = Platform.Tasks.PlanEngine.start_stage(stage.id)
      {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "ci_check"})

      {:ok, result} =
        ToolSurface.execute(
          "validation_evaluate",
          %{
            "validation_id" => validation.id,
            "status" => "passed",
            "evidence" => %{"ci_url" => "https://ci.example.com/123"},
            "evaluated_by" => "ci_bot"
          },
          %{}
        )

      assert result.status == "passed"
      assert result.kind == "ci_check"
      assert result.evaluated_by == "ci_bot"
      assert result.evidence["ci_url"] == "https://ci.example.com/123"
    end

    test "validation_evaluate with invalid status returns error" do
      {:error, error} =
        ToolSurface.execute(
          "validation_evaluate",
          %{"validation_id" => Ecto.UUID.generate(), "status" => "invalid"},
          %{}
        )

      assert error.error =~ "Invalid status"
      assert error.recoverable == true
    end

    test "validation_pass is an alias for passing a validation" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Alias task"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, name: "Build", position: 1})
      {:ok, _} = Platform.Tasks.PlanEngine.start_stage(stage.id)
      {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

      {:ok, result} =
        ToolSurface.execute(
          "validation_pass",
          %{"validation_id" => validation.id, "evidence" => %{"tests" => "green"}},
          %{}
        )

      assert result.status == "passed"
      assert result.evidence["tests"] == "green"
    end

    test "stage_complete advances a validation-free running stage" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Complete task"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, name: "Build", position: 1})
      {:ok, _} = Platform.Tasks.PlanEngine.start_stage(stage.id)

      {:ok, result} = ToolSurface.execute("stage_complete", %{"stage_id" => stage.id}, %{})

      assert result.stage_id == stage.id
      assert result.plan_id == plan.id
      assert result.plan_status in ["completed", "draft"]
    end

    test "stage_complete refuses when the parent plan is superseded (019f42dc stage 2)" do
      # Return-to-planning kills in-flight execution. If the executor tries to
      # advance a stage after the plan has been superseded, the guard must
      # short-circuit with a non-recoverable stop signal so retry loops bail.
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Supersede task"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, name: "Build", position: 1})
      {:ok, _} = Platform.Tasks.PlanEngine.start_stage(stage.id)

      plan
      |> Platform.Tasks.Plan.changeset(%{status: "superseded"})
      |> Repo.update!()

      {:error, error} = ToolSurface.execute("stage_complete", %{"stage_id" => stage.id}, %{})

      assert error.error == "plan_superseded"
      assert error.recoverable == false
      assert error.suggestion =~ "superseded"
    end

    test "stage_complete superseded guard short-circuits before :pending_validations (019f42dc stage 2)" do
      # Precedence lock: even if validations are still pending, the superseded
      # check must fire first — otherwise executors would spin retrying
      # validation_pass on a dead plan.
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Precedence task"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, name: "Build", position: 1})
      {:ok, _} = Platform.Tasks.PlanEngine.start_stage(stage.id)
      # Pending validation attached — under normal precedence this would
      # produce :pending_validations. With the superseded plan, it must not.
      {:ok, _val} = Tasks.create_validation(%{stage_id: stage.id, kind: "ci_check"})

      plan
      |> Platform.Tasks.Plan.changeset(%{status: "superseded"})
      |> Repo.update!()

      {:error, error} = ToolSurface.execute("stage_complete", %{"stage_id" => stage.id}, %{})

      assert error.error == "plan_superseded"
      assert error.recoverable == false
    end

    test "report_blocker records a structured runtime blocker" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Blocked task"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, name: "Build", position: 1})

      {:ok, result} =
        ToolSurface.execute(
          "report_blocker",
          %{
            "task_id" => task.id,
            "stage_id" => stage.id,
            "description" => "Missing deploy credentials",
            "needs_human" => true
          },
          %{runtime_id: "runtime:test", agent_id: "agent:test"}
        )

      assert result.blocked == true
      assert result.task_id == task.id
      assert is_binary(result.event_id)
    end

    # ── task_complete ────────────────────────────────────────────────────

    test "task_complete marks a task as done" do
      project = create_project()

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Finish me", status: "in_progress"})

      {:ok, result} =
        ToolSurface.execute("task_complete", %{"task_id" => task.id}, %{})

      assert result.task_id == task.id
      assert result.status == "done"
    end

    test "task_complete on non-existent task returns error" do
      {:error, error} =
        ToolSurface.execute("task_complete", %{"task_id" => Ecto.UUID.generate()}, %{})

      assert error.error =~ "Task not found"
      assert error.recoverable == false
    end

    test "task_complete on task that cannot transition to done returns error" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Backlog task"})

      {:error, error} =
        ToolSurface.execute("task_complete", %{"task_id" => task.id}, %{})

      assert error.error =~ "Cannot transition"
    end

    # ── task_dependencies ────────────────────────────────────────────────

    test "task_dependencies returns deps, unmet, and dependents for a task with both" do
      project = create_project()
      {:ok, dep_done} = Tasks.create_task(%{project_id: project.id, title: "Dep Done"})
      {:ok, dep_done} = Tasks.transition_task_status(dep_done, "in_progress")
      {:ok, dep_done} = Tasks.transition_task_status(dep_done, "done")

      {:ok, dep_in_progress} =
        Tasks.create_task(%{project_id: project.id, title: "Dep In Progress"})

      {:ok, dep_in_progress} = Tasks.transition_task_status(dep_in_progress, "in_progress")

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Has deps",
          dependencies: [
            %{"task_id" => dep_done.id, "kind" => "blocks"},
            %{"task_id" => dep_in_progress.id, "kind" => "blocks"}
          ]
        })

      {:ok, dependent} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Listed-by",
          dependencies: [%{"task_id" => task.id, "kind" => "blocks"}]
        })

      {:ok, result} =
        ToolSurface.execute("task_dependencies", %{"task_id" => task.id}, %{})

      assert length(result.deps) == 2
      assert result.unmet == [dep_in_progress.id]

      assert result.dependents == [
               %{task_id: dependent.id, title: "Listed-by", status: "backlog"}
             ]
    end

    test "task_dependencies preserves authored order of deps" do
      project = create_project()
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "Alpha"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "Bravo"})
      {:ok, c} = Tasks.create_task(%{project_id: project.id, title: "Charlie"})

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Ordered deps",
          dependencies: [
            %{"task_id" => c.id, "kind" => "blocks"},
            %{"task_id" => a.id, "kind" => "blocks"},
            %{"task_id" => b.id, "kind" => "blocks"}
          ]
        })

      {:ok, result} =
        ToolSurface.execute("task_dependencies", %{"task_id" => task.id}, %{})

      assert Enum.map(result.deps, & &1.task_id) == [c.id, a.id, b.id]
      assert Enum.map(result.deps, & &1.kind) == ["blocks", "blocks", "blocks"]
    end

    test "task_dependencies returns empty arrays for a task with neither deps nor dependents" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Lonely"})

      {:ok, result} =
        ToolSurface.execute("task_dependencies", %{"task_id" => task.id}, %{})

      assert result == %{deps: [], unmet: [], dependents: []}
    end

    test "task_dependencies returns nil title/status for missing dep ids but keeps task_id + kind" do
      project = create_project()
      missing_id = Ecto.UUID.generate()
      {:ok, real} = Tasks.create_task(%{project_id: project.id, title: "Real"})

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Mixed deps",
          dependencies: [
            %{"task_id" => missing_id, "kind" => "blocks"},
            %{"task_id" => real.id, "kind" => "blocks"}
          ]
        })

      {:ok, result} =
        ToolSurface.execute("task_dependencies", %{"task_id" => task.id}, %{})

      [first, second] = result.deps
      assert first == %{task_id: missing_id, title: nil, kind: "blocks", status: nil}
      assert second.task_id == real.id
      assert second.title == "Real"
      assert second.kind == "blocks"
      assert second.status == "backlog"
    end

    test "task_dependencies returns not-found error for unknown task_id" do
      {:error, error} =
        ToolSurface.execute(
          "task_dependencies",
          %{"task_id" => Ecto.UUID.generate()},
          %{}
        )

      assert error.error =~ "Task not found"
      assert error.recoverable == false
    end

    # ── space_list ───────────────────────────────────────────────────────

    test "space_list returns spaces the agent is a member of" do
      agent = create_agent()
      space = create_space(%{name: "Agent Space"})

      create_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent.id,
        display_name: agent.name
      })

      {:ok, results} =
        ToolSurface.execute("space_list", %{}, %{agent_id: agent.id})

      assert is_list(results)
      assert Enum.any?(results, fn s -> s.id == space.id end)
      space_result = Enum.find(results, &(&1.id == space.id))
      assert space_result.name == "Agent Space"
      assert space_result.kind == "channel"
    end

    test "space_list filters by kind" do
      agent = create_agent()
      channel = create_space(%{name: "Channel", kind: "channel"})
      dm = create_space(%{name: "DM", kind: "dm", slug: unique_slug()})

      for s <- [channel, dm] do
        create_participant(s.id, %{
          participant_type: "agent",
          participant_id: agent.id,
          display_name: agent.name
        })
      end

      {:ok, results} =
        ToolSurface.execute("space_list", %{"kind" => "dm"}, %{agent_id: agent.id})

      assert length(results) == 1
      assert hd(results).name == "DM"
    end

    # ── space_list_agents ────────────────────────────────────────────────

    test "space_list_agents returns active agent participants enriched with slug + name" do
      higgins = create_agent(%{name: "Higgins"})
      geordi = create_agent(%{name: "Geordi"})
      space = create_space(%{name: "Engineering"})

      {:ok, higgins_p} =
        Chat.add_agent_participant(space.id, higgins, display_name: "Higgins")

      {:ok, _geordi_p} =
        Chat.add_agent_participant(space.id, geordi, display_name: "Geordi")

      {:ok, rows} = ToolSurface.execute("space_list_agents", %{"space_id" => space.id}, %{})

      assert length(rows) == 2
      higgins_row = Enum.find(rows, &(&1.agent_id == higgins.id))
      assert higgins_row.slug == higgins.slug
      assert higgins_row.name == "Higgins"
      assert higgins_row.display_name == "Higgins"
      assert higgins_row.participant_id == higgins_p.id
      assert %DateTime{} = higgins_row.joined_at
    end

    test "space_list_agents excludes human participants and left agents" do
      higgins = create_agent(%{name: "Higgins"})
      geordi = create_agent(%{name: "Geordi"})
      space = create_space(%{name: "Mixed"})

      {:ok, _} = Chat.add_agent_participant(space.id, higgins, display_name: "Higgins")
      {:ok, geordi_p} = Chat.add_agent_participant(space.id, geordi, display_name: "Geordi")

      # Human participant — uses a raw UUID, no corresponding agent row.
      human_user_id = Ecto.UUID.generate()

      create_participant(space.id, %{
        participant_type: "user",
        participant_id: human_user_id,
        display_name: "Human"
      })

      # Geordi leaves.
      {:ok, _} = Chat.remove_participant(geordi_p)

      {:ok, rows} = ToolSurface.execute("space_list_agents", %{"space_id" => space.id}, %{})

      agent_ids = Enum.map(rows, & &1.agent_id)
      assert higgins.id in agent_ids
      refute geordi.id in agent_ids
      refute human_user_id in agent_ids
    end

    test "space_list_agents returns an error when space_id is missing" do
      assert {:error, err} = ToolSurface.execute("space_list_agents", %{}, %{})
      assert err.error =~ "space_id is required"
    end

    # ── space_leave ──────────────────────────────────────────────────────

    test "space_leave removes the calling agent from the space (self-leave)" do
      ensure_active_agent_store()

      agent = create_agent()
      space = create_space(%{name: "DM Stuck", kind: "dm", slug: unique_slug()})

      {:ok, participant} =
        Chat.add_agent_participant(space.id, agent, display_name: agent.name)

      {:ok, result} =
        ToolSurface.execute("space_leave", %{"space_id" => space.id}, %{agent_id: agent.id})

      assert result.space_id == space.id
      assert result.agent_id == agent.id
      assert result.participant_id == participant.id
      assert result.removed == true
      assert result.self_removed == true
      assert %DateTime{} = result.removed_at

      # Hard-delete (ADR 0038): the row is gone.
      assert Chat.get_agent_participant(space.id, agent.id) == nil
    end

    test "space_leave removes a different agent when agent_id is provided" do
      ensure_active_agent_store()

      higgins = create_agent(%{name: "Higgins"})
      geordi = create_agent(%{name: "Geordi"})
      space = create_space(%{name: "Engineering"})

      {:ok, _higgins_p} =
        Chat.add_agent_participant(space.id, higgins, display_name: "Higgins")

      {:ok, geordi_p} =
        Chat.add_agent_participant(space.id, geordi, display_name: "Geordi")

      {:ok, result} =
        ToolSurface.execute(
          "space_leave",
          %{"space_id" => space.id, "agent_id" => geordi.id},
          %{agent_id: higgins.id}
        )

      assert result.agent_id == geordi.id
      assert result.participant_id == geordi_p.id
      assert result.self_removed == false

      assert Chat.get_agent_participant(space.id, geordi.id) == nil
      # Caller stays put.
      refute Chat.list_participants(space.id) |> Enum.any?(&(&1.participant_id == geordi.id))
      assert Chat.list_participants(space.id) |> Enum.any?(&(&1.participant_id == higgins.id))
    end

    test "space_leave returns an error when the target agent is not in the space" do
      ensure_active_agent_store()

      agent = create_agent()
      space = create_space()

      assert {:error, error} =
               ToolSurface.execute(
                 "space_leave",
                 %{"space_id" => space.id},
                 %{agent_id: agent.id}
               )

      assert error.error =~ "not an active participant"
      assert error.recoverable == false
    end

    test "space_leave refuses to remove human participants (agent-only tool)" do
      ensure_active_agent_store()

      caller = create_agent()
      space = create_space()
      human = create_participant(space.id, %{display_name: "Rowan"})

      # Try to target the human's participant_id — the helper filters on
      # participant_type="agent", so this should come back with not-found
      # rather than actually removing the human.
      {:error, error} =
        ToolSurface.execute(
          "space_leave",
          %{"space_id" => space.id, "agent_id" => human.participant_id},
          %{agent_id: caller.id}
        )

      assert error.error =~ "not an active participant"
      # Human is still a participant.
      assert Repo.reload!(human)
    end

    test "space_leave is idempotent — already-left participants return not-found" do
      ensure_active_agent_store()

      agent = create_agent()
      space = create_space()

      {:ok, _participant} =
        Chat.add_agent_participant(space.id, agent, display_name: agent.name)

      # First call removes cleanly.
      {:ok, _} =
        ToolSurface.execute("space_leave", %{"space_id" => space.id}, %{agent_id: agent.id})

      assert Chat.get_agent_participant(space.id, agent.id) == nil

      # Second call: the participant row is gone, so the lookup returns nil
      # and the tool surfaces a clear error.
      {:error, error} =
        ToolSurface.execute("space_leave", %{"space_id" => space.id}, %{agent_id: agent.id})

      assert error.error =~ "not an active participant"
    end

    test "space_leave clears the active-agent mutex if the leaver was holding it" do
      ensure_active_agent_store()

      agent = create_agent()
      space = create_space()

      {:ok, participant} =
        Chat.add_agent_participant(space.id, agent, display_name: agent.name)

      Platform.Chat.ActiveAgentStore.set_active(space.id, participant.id)
      assert Platform.Chat.ActiveAgentStore.get_active(space.id) == participant.id

      {:ok, _} =
        ToolSurface.execute("space_leave", %{"space_id" => space.id}, %{agent_id: agent.id})

      assert Platform.Chat.ActiveAgentStore.get_active(space.id) == nil
    end

    test "space_leave requires space_id" do
      agent = create_agent()

      assert {:error, error} =
               ToolSurface.execute("space_leave", %{}, %{agent_id: agent.id})

      assert error.error =~ "space_id is required"
    end

    test "space_leave requires an identifiable caller when agent_id arg is omitted" do
      space = create_space()

      assert {:error, error} =
               ToolSurface.execute("space_leave", %{"space_id" => space.id}, %{})

      assert error.error =~ "identity unresolved"
    end

    # ── send_media ───────────────────────────────────────────────────────

    test "send_media posts a message with single file attachment" do
      space = create_space()
      participant = create_participant(space.id)

      # Use a writable temp path for uploads in test
      test_uploads = Path.join(System.tmp_dir!(), "platform_test_uploads_#{Ecto.UUID.generate()}")
      prev = Application.get_env(:platform, :chat_attachments_root)
      Application.put_env(:platform, :chat_attachments_root, test_uploads)

      # Create a temp file for testing
      tmp_path = Path.join(System.tmp_dir!(), "test-upload-#{Ecto.UUID.generate()}.txt")
      File.write!(tmp_path, "hello world")

      context = %{
        space_id: space.id,
        agent_participant_id: participant.id
      }

      try do
        {:ok, result} =
          ToolSurface.execute(
            "send_media",
            %{
              "space_id" => space.id,
              "file_path" => tmp_path,
              "content" => "Here is the file",
              "filename" => "test.txt"
            },
            context
          )

        assert is_binary(result.message_id)
        assert result.space_id == space.id
        assert result.attachment_count == 1
      after
        Application.put_env(:platform, :chat_attachments_root, prev)
        File.rm(tmp_path)
        File.rm_rf(test_uploads)
      end
    end

    test "send_media posts a message with file_paths attachments" do
      space = create_space()
      participant = create_participant(space.id)

      test_uploads = Path.join(System.tmp_dir!(), "platform_test_uploads_#{Ecto.UUID.generate()}")
      prev = Application.get_env(:platform, :chat_attachments_root)
      Application.put_env(:platform, :chat_attachments_root, test_uploads)

      tmp_path_1 = Path.join(System.tmp_dir!(), "test-upload-#{Ecto.UUID.generate()}.txt")
      tmp_path_2 = Path.join(System.tmp_dir!(), "test-upload-#{Ecto.UUID.generate()}.md")
      File.write!(tmp_path_1, "hello world")
      File.write!(tmp_path_2, "# hello")

      context = %{
        space_id: space.id,
        agent_participant_id: participant.id
      }

      try do
        {:ok, result} =
          ToolSurface.execute(
            "send_media",
            %{
              "space_id" => space.id,
              "file_paths" => [tmp_path_1, tmp_path_2],
              "content" => "Here are the files"
            },
            context
          )

        assert is_binary(result.message_id)
        assert result.space_id == space.id
        assert result.attachment_count == 2
      after
        Application.put_env(:platform, :chat_attachments_root, prev)
        File.rm(tmp_path_1)
        File.rm(tmp_path_2)
        File.rm_rf(test_uploads)
      end
    end

    test "send_media with non-existent file returns error" do
      space = create_space()
      participant = create_participant(space.id)

      context = %{
        space_id: space.id,
        agent_participant_id: participant.id
      }

      {:error, error} =
        ToolSurface.execute(
          "send_media",
          %{
            "space_id" => space.id,
            "file_path" => "/tmp/nonexistent-file-#{Ecto.UUID.generate()}.txt"
          },
          context
        )

      assert error.error =~ "Failed to send media"
    end

    # ── react ───────────────────────────────────────────────────────────

    test "react adds an emoji reaction to a message" do
      space = create_space()
      author = create_participant(space.id)
      agent_participant = create_participant(space.id, %{display_name: "Agent"})

      {:ok, message} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "hello"
        })

      {:ok, result} =
        ToolSurface.execute(
          "react",
          %{
            "space_id" => space.id,
            "message_id" => message.id,
            "emoji" => "👍"
          },
          %{space_id: space.id, agent_participant_id: agent_participant.id}
        )

      assert result.message_id == message.id
      assert result.space_id == space.id
      assert result.emoji == "👍"
      assert result.status == "added"

      assert [%{emoji: "👍"}] = Chat.list_reactions(message.id)
    end

    test "react is idempotent — second call returns already_reacted" do
      space = create_space()
      author = create_participant(space.id)
      agent_participant = create_participant(space.id, %{display_name: "Agent"})

      {:ok, message} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "hello"
        })

      context = %{space_id: space.id, agent_participant_id: agent_participant.id}
      args = %{"space_id" => space.id, "message_id" => message.id, "emoji" => "🎉"}

      {:ok, first} = ToolSurface.execute("react", args, context)
      {:ok, second} = ToolSurface.execute("react", args, context)

      assert first.status == "added"
      assert second.status == "already_reacted"
      assert length(Chat.list_reactions(message.id)) == 1
    end

    test "react rejects a message from a different space" do
      space_a = create_space()
      space_b = create_space()
      author = create_participant(space_a.id)
      agent_participant = create_participant(space_b.id, %{display_name: "Agent"})

      {:ok, message} =
        Chat.post_message(%{
          space_id: space_a.id,
          participant_id: author.id,
          content_type: "text",
          content: "hello"
        })

      {:error, error} =
        ToolSurface.execute(
          "react",
          %{
            "space_id" => space_b.id,
            "message_id" => message.id,
            "emoji" => "👍"
          },
          %{space_id: space_b.id, agent_participant_id: agent_participant.id}
        )

      assert error.error =~ "does not belong to space"
      assert Chat.list_reactions(message.id) == []
    end

    test "react returns error for non-existent message" do
      space = create_space()
      participant = create_participant(space.id, %{display_name: "Agent"})

      {:error, error} =
        ToolSurface.execute(
          "react",
          %{
            "space_id" => space.id,
            "message_id" => Ecto.UUID.generate(),
            "emoji" => "👍"
          },
          %{space_id: space.id, agent_participant_id: participant.id}
        )

      assert error.error =~ "not found"
    end

    test "react rejects missing emoji" do
      space = create_space()
      participant = create_participant(space.id, %{display_name: "Agent"})

      {:error, error} =
        ToolSurface.execute(
          "react",
          %{"space_id" => space.id, "message_id" => Ecto.UUID.generate(), "emoji" => ""},
          %{space_id: space.id, agent_participant_id: participant.id}
        )

      assert error.error =~ "emoji is required"
    end

    # ── Stack tools (ADR 0041) ────────────────────────────────────────

    test "stack_create creates a stack and returns stack_id + rollup_branch" do
      project = create_project()
      slug = "shim-create-#{System.unique_integer([:positive])}"

      {:ok, result} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Shim Create"},
          %{}
        )

      assert is_binary(result.stack_id)
      assert result.rollup_branch == "stack/#{slug}"
    end

    test "stack_create returns slug_taken envelope on duplicate slug within project" do
      project = create_project()
      slug = "shim-dup-#{System.unique_integer([:positive])}"

      {:ok, _} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "First"},
          %{}
        )

      {:error, error} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Second"},
          %{}
        )

      assert error.code == "slug_taken"
      assert error.recoverable == true
    end

    test "stack_create with invalid slug returns a clean error envelope" do
      project = create_project()

      {:error, error} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => "Bad Slug!", "name" => "Bad"},
          %{}
        )

      refute Map.get(error, :code) == "slug_taken"
      assert error.recoverable == true
      assert error.error =~ "Failed to create stack"
    end

    test "stack_get returns stack, members, edges, executable_now, cross_stack_deps" do
      project = create_project()
      slug = "shim-get-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Shim Get"},
          %{}
        )

      {:ok, t1} = Tasks.create_task(%{project_id: project.id, title: "Root"})

      {:ok, t2} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => t1.id, "kind" => "blocks"}]
        })

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => t1.id}, %{})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => t2.id}, %{})

      {:ok, result} = ToolSurface.execute("stack_get", %{"stack_id" => stack_id}, %{})

      assert result.stack.id == stack_id
      assert result.stack.slug == slug
      assert length(result.members) == 2
      assert Enum.any?(result.edges, &(&1.from_task_id == t2.id and &1.to_task_id == t1.id))
      assert t1.id in result.executable_now
      refute t2.id in result.executable_now
      assert result.cross_stack_deps == []
    end

    test "stack_get returns not-found envelope when stack missing" do
      {:error, error} =
        ToolSurface.execute("stack_get", %{"stack_id" => Ecto.UUID.generate()}, %{})

      assert error.error =~ "Stack not found"
      assert error.recoverable == false
    end

    test "stack_list filters by project_id" do
      project_a = create_project()
      project_b = create_project()

      slug_a = "list-a-#{System.unique_integer([:positive])}"
      slug_b = "list-b-#{System.unique_integer([:positive])}"

      {:ok, _} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project_a.id, "slug" => slug_a, "name" => "A"},
          %{}
        )

      {:ok, _} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project_b.id, "slug" => slug_b, "name" => "B"},
          %{}
        )

      {:ok, results} =
        ToolSurface.execute("stack_list", %{"project_id" => project_a.id}, %{})

      slugs = Enum.map(results, & &1.slug)
      assert slug_a in slugs
      refute slug_b in slugs
    end

    test "stack_add returns task_id + stack_id + stack_position on success" do
      project = create_project()
      slug = "shim-add-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Shim Add"},
          %{}
        )

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "T"})

      {:ok, result} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => task.id}, %{})

      assert result.task_id == task.id
      assert result.stack_id == stack_id
      assert result.stack_position == 1
    end

    test "stack_add returns already_in_stack envelope when task is already a member" do
      project = create_project()
      slug = "shim-add-dup-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Dup Add"},
          %{}
        )

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "T"})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => task.id}, %{})

      {:error, error} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => task.id}, %{})

      assert error.code == "already_in_stack"
    end

    test "stack_eject returns task_id + stack_id on success" do
      project = create_project()
      slug = "shim-eject-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Eject"},
          %{}
        )

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Ejectable"})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => task.id}, %{})

      {:ok, result} =
        ToolSurface.execute("stack_eject", %{"stack_id" => stack_id, "task_id" => task.id}, %{})

      assert result.task_id == task.id
      assert result.stack_id == stack_id
    end

    test "stack_eject returns not_in_stack envelope when task isn't a member" do
      project = create_project()
      slug = "shim-eject-miss-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Eject Miss"},
          %{}
        )

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Floating"})

      {:error, error} =
        ToolSurface.execute("stack_eject", %{"stack_id" => stack_id, "task_id" => task.id}, %{})

      assert error.code == "not_in_stack"
    end

    test "stack_eject returns has_dependents envelope with dependents payload" do
      project = create_project()
      slug = "shim-eject-deps-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Eject Deps"},
          %{}
        )

      {:ok, root} = Tasks.create_task(%{project_id: project.id, title: "Root"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => root.id, "kind" => "blocks"}]
        })

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => root.id}, %{})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => child.id}, %{})

      {:error, error} =
        ToolSurface.execute("stack_eject", %{"stack_id" => stack_id, "task_id" => root.id}, %{})

      assert error.code == "has_dependents"
      assert Enum.any?(error.dependents, &(&1.id == child.id))
    end

    test "stack_add_dependency wires an edge between two members and reports executable_now" do
      project = create_project()
      slug = "shim-dep-add-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Dep Add"},
          %{}
        )

      {:ok, root} = Tasks.create_task(%{project_id: project.id, title: "Root"})
      {:ok, child} = Tasks.create_task(%{project_id: project.id, title: "Child"})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => root.id}, %{})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => child.id}, %{})

      {:ok, result} =
        ToolSurface.execute(
          "stack_add_dependency",
          %{
            "stack_id" => stack_id,
            "from_task_id" => child.id,
            "to_task_id" => root.id
          },
          %{}
        )

      assert result.from_task_id == child.id
      assert result.to_task_id == root.id
      assert result.kind == "blocks"
      # `child` now blocks on `root` — only `root` is executable_now.
      assert result.executable_now == [root.id]
    end

    test "stack_add_dependency returns self_edge envelope for from == to" do
      project = create_project()
      slug = "shim-dep-self-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Dep Self"},
          %{}
        )

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Solo"})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => task.id}, %{})

      {:error, error} =
        ToolSurface.execute(
          "stack_add_dependency",
          %{
            "stack_id" => stack_id,
            "from_task_id" => task.id,
            "to_task_id" => task.id
          },
          %{}
        )

      assert error.code == "self_edge"
    end

    test "stack_remove_dependency drops an edge and reports executable_now" do
      project = create_project()
      slug = "shim-dep-rm-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Dep Rm"},
          %{}
        )

      {:ok, root} = Tasks.create_task(%{project_id: project.id, title: "Root"})
      {:ok, child} = Tasks.create_task(%{project_id: project.id, title: "Child"})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => root.id}, %{})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => child.id}, %{})

      {:ok, _} =
        ToolSurface.execute(
          "stack_add_dependency",
          %{
            "stack_id" => stack_id,
            "from_task_id" => child.id,
            "to_task_id" => root.id
          },
          %{}
        )

      {:ok, result} =
        ToolSurface.execute(
          "stack_remove_dependency",
          %{
            "stack_id" => stack_id,
            "from_task_id" => child.id,
            "to_task_id" => root.id
          },
          %{}
        )

      assert result.from_task_id == child.id
      assert result.to_task_id == root.id
      # With the edge dropped, both members are executable.
      assert Enum.sort(result.executable_now) == Enum.sort([root.id, child.id])
    end

    test "stack_remove_dependency returns not_an_edge envelope when no such edge exists" do
      project = create_project()
      slug = "shim-dep-rm-miss-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Dep Rm Miss"},
          %{}
        )

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => a.id}, %{})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => b.id}, %{})

      {:error, error} =
        ToolSurface.execute(
          "stack_remove_dependency",
          %{
            "stack_id" => stack_id,
            "from_task_id" => a.id,
            "to_task_id" => b.id
          },
          %{}
        )

      assert error.code == "not_an_edge"
    end

    test "stack_add_dependency returns cycle envelope with path when the edge would close a cycle" do
      project = create_project()
      slug = "shim-dep-cycle-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Dep Cycle"},
          %{}
        )

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => a.id}, %{})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => b.id}, %{})

      # First edge B → A is fine.
      {:ok, _} =
        ToolSurface.execute(
          "stack_add_dependency",
          %{
            "stack_id" => stack_id,
            "from_task_id" => b.id,
            "to_task_id" => a.id
          },
          %{}
        )

      # A → B would close the cycle.
      {:error, error} =
        ToolSurface.execute(
          "stack_add_dependency",
          %{
            "stack_id" => stack_id,
            "from_task_id" => a.id,
            "to_task_id" => b.id
          },
          %{}
        )

      assert error.code == "cycle"
      assert is_list(error.path)
      assert a.id in error.path
      assert b.id in error.path

      # Cycle-creating dep on A was rolled back.
      reloaded_a = Repo.get(Platform.Tasks.Task, a.id)
      assert Tasks.dependency_task_ids(reloaded_a) == []
    end

    test "stack_add_dependency returns duplicate_edge envelope when the edge already exists" do
      project = create_project()
      slug = "shim-dep-dup-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Dep Dup"},
          %{}
        )

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => a.id}, %{})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => b.id}, %{})

      {:ok, _} =
        ToolSurface.execute(
          "stack_add_dependency",
          %{
            "stack_id" => stack_id,
            "from_task_id" => b.id,
            "to_task_id" => a.id
          },
          %{}
        )

      # Re-adding the same edge surfaces duplicate_edge.
      {:error, error} =
        ToolSurface.execute(
          "stack_add_dependency",
          %{
            "stack_id" => stack_id,
            "from_task_id" => b.id,
            "to_task_id" => a.id
          },
          %{}
        )

      assert error.code == "duplicate_edge"

      # No double-write — still exactly one dep on B.
      reloaded_b = Repo.get(Platform.Tasks.Task, b.id)
      assert Tasks.dependency_task_ids(reloaded_b) == [a.id]
    end

    test "stack_add_dependency returns not_in_stack envelope for a non-member endpoint" do
      project = create_project()
      slug = "shim-dep-nonmember-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Dep Non Member"},
          %{}
        )

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, free} = Tasks.create_task(%{project_id: project.id, title: "Free"})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => a.id}, %{})

      # `free` is not a member of any stack.
      {:error, error} =
        ToolSurface.execute(
          "stack_add_dependency",
          %{
            "stack_id" => stack_id,
            "from_task_id" => a.id,
            "to_task_id" => free.id
          },
          %{}
        )

      assert error.code == "not_in_stack"
      # The envelope must NAME the offending endpoint so callers can
      # render an actionable message without a follow-up lookup.
      assert error.offending_task_id == free.id
      assert error.error =~ free.id

      # No write happened.
      reloaded_a = Repo.get(Platform.Tasks.Task, a.id)
      assert Tasks.dependency_task_ids(reloaded_a) == []
    end

    test "stack_add_dependency returns not_in_stack envelope when target lives in a different stack" do
      project = create_project()
      slug_a = "shim-dep-cross-a-#{System.unique_integer([:positive])}"
      slug_b = "shim-dep-cross-b-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_a_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug_a, "name" => "Dep Cross A"},
          %{}
        )

      {:ok, %{stack_id: stack_b_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug_b, "name" => "Dep Cross B"},
          %{}
        )

      {:ok, a1} = Tasks.create_task(%{project_id: project.id, title: "A1"})
      {:ok, b1} = Tasks.create_task(%{project_id: project.id, title: "B1"})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_a_id, "task_id" => a1.id}, %{})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_b_id, "task_id" => b1.id}, %{})

      # a1 in stack_a, b1 in stack_b — wrapper rejects with :not_in_stack
      # before the cross-stack-DAG check ever runs, and names b1 as the
      # offender (the endpoint that doesn't belong to the supplied stack).
      {:error, error} =
        ToolSurface.execute(
          "stack_add_dependency",
          %{
            "stack_id" => stack_a_id,
            "from_task_id" => a1.id,
            "to_task_id" => b1.id
          },
          %{}
        )

      assert error.code == "not_in_stack"
      assert error.offending_task_id == b1.id
      assert error.error =~ b1.id

      # No write happened.
      reloaded_a1 = Repo.get(Platform.Tasks.Task, a1.id)
      assert Tasks.dependency_task_ids(reloaded_a1) == []
    end

    test "stack_abandon flips status to abandoned and records reason" do
      project = create_project()
      slug = "shim-abandon-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Abandon Me"},
          %{}
        )

      {:ok, result} =
        ToolSurface.execute(
          "stack_abandon",
          %{"stack_id" => stack_id, "reason" => "scope change"},
          %{}
        )

      assert result.status == "abandoned"
      assert result.description =~ "scope change"
    end

    test "stack_complete refuses with members_not_done when a member isn't done" do
      project = create_project()
      slug = "shim-complete-refuse-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Refuse Complete"},
          %{}
        )

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "still cooking"})
      {:ok, _} = Tasks.update_task(task, %{stack_id: stack_id, stack_position: 1})

      assert {:error, error} =
               ToolSurface.execute(
                 "stack_complete",
                 %{"stack_id" => stack_id, "note" => "early"},
                 %{}
               )

      assert error.code == "members_not_done"
      assert [%{id: pending_id}] = error.pending
      assert pending_id == task.id
    end

    test "stack_complete flips status to done when every member is done" do
      project = create_project()
      slug = "shim-complete-ok-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Complete Me"},
          %{}
        )

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "shipped"})

      {:ok, attached} = Tasks.update_task(task, %{stack_id: stack_id, stack_position: 1})

      attached
      |> Platform.Tasks.Task.changeset(%{status: "done"})
      |> Platform.Repo.update!()

      {:ok, result} =
        ToolSurface.execute(
          "stack_complete",
          %{"stack_id" => stack_id, "note" => "manual ship lane"},
          %{}
        )

      assert result.status == "done"
      assert result.description =~ "manual ship lane"
    end

    test "stack_start transitions a forming stack to in_progress" do
      project = create_project()
      slug = "shim-start-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Start Me"},
          %{}
        )

      {:ok, result} =
        ToolSurface.execute("stack_start", %{"stack_id" => stack_id}, %{})

      assert result.status == "in_progress"
    end

    test "stack_start_planning cascades backlog members to planning and lists them" do
      project = create_project()
      slug = "shim-start-planning-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Plan Me"},
          %{}
        )

      {:ok, m1} = Tasks.create_task(%{project_id: project.id, title: "Member 1"})
      {:ok, m2} = Tasks.create_task(%{project_id: project.id, title: "Member 2"})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => m1.id}, %{})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => m2.id}, %{})

      {:ok, result} =
        ToolSurface.execute("stack_start_planning", %{"stack_id" => stack_id}, %{})

      # Payload carries the serialized stack plus a `planning` list of the
      # members moved out of `backlog`.
      assert result.id == stack_id
      # An all-`planning` stack rolls up to `forming`.
      assert result.status == "forming"
      planning_ids = result.planning |> Enum.map(& &1.id) |> Enum.sort()
      assert planning_ids == Enum.sort([m1.id, m2.id])
      assert Enum.all?(result.planning, &(&1.status == "planning"))
      # No failures → no `cascade_errors` key on a clean cascade.
      refute Map.has_key?(result, :cascade_errors)
    end

    test "stack_start_planning on a stack with no backlog members returns an empty planning list" do
      project = create_project()
      slug = "shim-start-planning-empty-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Nothing To Plan"},
          %{}
        )

      {:ok, result} =
        ToolSurface.execute("stack_start_planning", %{"stack_id" => stack_id}, %{})

      assert result.id == stack_id
      assert result.planning == []
      refute Map.has_key?(result, :cascade_errors)
    end

    test "stack_start_planning returns a not-found envelope for a missing stack" do
      {:error, error} =
        ToolSurface.execute(
          "stack_start_planning",
          %{"stack_id" => Ecto.UUID.generate()},
          %{}
        )

      assert error.error =~ "Stack not found"
      assert error.recoverable == false
    end

    test "stack_start_planning maps a partial cascade into a cascade_errors payload" do
      project = create_project()
      slug = "shim-start-planning-partial-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Partial Plan"},
          %{}
        )

      {:ok, ok_member} = Tasks.create_task(%{project_id: project.id, title: "Healthy"})
      {:ok, bad_member} = Tasks.create_task(%{project_id: project.id, title: "Will Fail"})

      {:ok, _} =
        ToolSurface.execute(
          "stack_add",
          %{"stack_id" => stack_id, "task_id" => ok_member.id},
          %{}
        )

      {:ok, _} =
        ToolSurface.execute(
          "stack_add",
          %{"stack_id" => stack_id, "task_id" => bad_member.id},
          %{}
        )

      # Corrupt bad_member's title at the DB level (bypassing the
      # changeset) so the `backlog -> planning` transition changeset
      # fails `validate_required(:title)`. The cascade then yields
      # `{:partial, ...}`, which the tool maps into a `cascade_errors`
      # array on the payload.
      Ecto.Adapters.SQL.query!(
        Repo,
        "UPDATE tasks SET title = '' WHERE id = $1",
        [Ecto.UUID.dump!(bad_member.id)]
      )

      {:ok, result} =
        ToolSurface.execute("stack_start_planning", %{"stack_id" => stack_id}, %{})

      # Only the healthy member advanced.
      assert [planned] = result.planning
      assert planned.id == ok_member.id
      assert planned.status == "planning"

      # The failed member surfaces in `cascade_errors`.
      assert [%{task_id: failed_id, target_status: "planning"} | _] = result.cascade_errors
      assert failed_id == bad_member.id
    end

    test "stack_start_planning payload includes edges_authored:1 when inference writes an edge" do
      # Stage 4 (ADR 0045): confirm the MCP response envelope surfaces
      # `edges_authored` for the happy stub path. Uses the DepInference
      # StubAdapter to inject a single-edge canned response.
      alias Platform.Tasks.Stacks.DepInference.StubAdapter
      StubAdapter.reset_calls()

      project = create_project()
      slug = "shim-sp-edges-authored-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Infer Edges"},
          %{}
        )

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A creates types"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B consumes types"})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => a.id}, %{})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => b.id}, %{})

      Process.put(
        {:dep_inference_stub, :response},
        {:ok,
         Jason.encode!(%{
           "edges" => [
             %{"from_task_id" => b.id, "to_task_id" => a.id, "reason" => "B consumes A"}
           ]
         })}
      )

      {:ok, result} =
        ToolSurface.execute("stack_start_planning", %{"stack_id" => stack_id}, %{})

      assert result.id == stack_id
      assert result.edges_authored == 1
      # Happy path OMITS the reason key so the payload stays tight.
      refute Map.has_key?(result, :edges_skipped_reason)
    end

    test "stack_start_planning payload includes edges_authored:0 without reason when stub returns empty edges" do
      # Empty-edges is the "successful inference wrote zero edges" case
      # — it's still a successful inference, so no `edges_skipped_reason`
      # key on the payload.
      alias Platform.Tasks.Stacks.DepInference.StubAdapter
      StubAdapter.reset_calls()

      project = create_project()
      slug = "shim-sp-edges-empty-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Empty Edges"},
          %{}
        )

      {:ok, m1} = Tasks.create_task(%{project_id: project.id, title: "Independent 1"})
      {:ok, m2} = Tasks.create_task(%{project_id: project.id, title: "Independent 2"})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => m1.id}, %{})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => m2.id}, %{})

      Process.put({:dep_inference_stub, :response}, {:ok, ~s({"edges": []})})

      {:ok, result} =
        ToolSurface.execute("stack_start_planning", %{"stack_id" => stack_id}, %{})

      assert result.edges_authored == 0
      refute Map.has_key?(result, :edges_skipped_reason)
    end

    test "stack_start_planning payload includes edges_skipped_reason when inference is skipped" do
      # When a user has already authored an in-stack edge, inference is
      # short-circuited and the reason is surfaced on the payload so the
      # caller can distinguish "we skipped intentionally" from "we ran
      # cleanly with zero output".
      alias Platform.Tasks.Stacks.DepInference.StubAdapter
      alias Platform.Tasks.Stacks
      StubAdapter.reset_calls()

      project = create_project()
      slug = "shim-sp-edges-override-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Override"},
          %{}
        )

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => a.id}, %{})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => b.id}, %{})

      # Pre-author the in-stack edge B->A so idempotency kicks in.
      stack = Stacks.get_stack!(stack_id)
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)

      {:ok, result} =
        ToolSurface.execute("stack_start_planning", %{"stack_id" => stack_id}, %{})

      assert result.edges_authored == 0
      assert result.edges_skipped_reason == :user_override_present
    end

    test "task_create with stack_id attaches the new task to the stack" do
      project = create_project()
      slug = "shim-tc-stack-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "TC Stack"},
          %{}
        )

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Stacked task",
            "stack_id" => stack_id
          },
          %{}
        )

      assert result.stack_id == stack_id
      assert result.stack_position == 1
    end
  end

  # ── Context read tools ────────────────────────────────────────────

  describe "context read tools" do
    setup do
      agent = create_agent()
      space = create_space(%{name: "Read Space", description: "A test space"})

      participant =
        create_participant(space.id, %{
          participant_type: "agent",
          participant_id: agent.id,
          display_name: agent.name
        })

      context = %{agent_id: agent.id, agent_participant_id: participant.id}
      %{agent: agent, space: space, participant: participant, context: context}
    end

    # ── space_get_context ──────────────────────────────────────────

    test "space_get_context returns context bundle for a member space", ctx do
      {:ok, result} =
        ToolSurface.execute(
          "space_get_context",
          %{"space_id" => ctx.space.id},
          ctx.context
        )

      assert result.space.id == ctx.space.id
      assert result.space.name == "Read Space"
      assert is_list(result.active_canvases)
      assert is_binary(result.recent_activity_summary) or result.recent_activity_summary == ""
    end

    test "space_get_context denied for non-member agent", ctx do
      other_space = create_space(%{name: "Other"})

      {:error, error} =
        ToolSurface.execute(
          "space_get_context",
          %{"space_id" => other_space.id},
          ctx.context
        )

      assert error.error =~ "Access denied"
      assert error.recoverable == false
    end

    test "space_get_context with nil space_id returns error", ctx do
      {:error, error} =
        ToolSurface.execute("space_get_context", %{}, ctx.context)

      assert error.error =~ "space_id is required"
    end

    # ── space_get_messages ─────────────────────────────────────────

    test "space_get_messages returns recent messages", ctx do
      # Post some messages
      for i <- 1..3 do
        Chat.post_message(%{
          space_id: ctx.space.id,
          participant_id: ctx.participant.id,
          content_type: "text",
          content: "Message #{i}"
        })
      end

      {:ok, results} =
        ToolSurface.execute(
          "space_get_messages",
          %{"space_id" => ctx.space.id},
          ctx.context
        )

      assert length(results) == 3
      # Newest first
      assert hd(results).content == "Message 3"
      assert is_binary(hd(results).id)
      assert is_binary(hd(results).inserted_at)
      # Stage 1: every row carries an attachments array (empty when none).
      for row <- results, do: assert(row.attachments == [])
    end

    test "space_get_messages returns attachments for messages that have them", ctx do
      {:ok, msg_with_attachment} =
        Chat.post_message(%{
          space_id: ctx.space.id,
          participant_id: ctx.participant.id,
          content_type: "text",
          content: "with attachment"
        })

      {:ok, plain_msg} =
        Chat.post_message(%{
          space_id: ctx.space.id,
          participant_id: ctx.participant.id,
          content_type: "text",
          content: "no attachment"
        })

      {:ok, attachment} =
        Chat.create_attachment(%{
          space_id: ctx.space.id,
          message_id: msg_with_attachment.id,
          filename: "diagram.png",
          content_type: "image/png",
          byte_size: 9,
          storage_key: "chat/test/d-#{Ecto.UUID.generate()}.png",
          state: "ready"
        })

      {:ok, results} =
        ToolSurface.execute(
          "space_get_messages",
          %{"space_id" => ctx.space.id},
          ctx.context
        )

      attached_row = Enum.find(results, &(&1.id == msg_with_attachment.id))
      plain_row = Enum.find(results, &(&1.id == plain_msg.id))

      assert plain_row.attachments == []

      assert [
               %{
                 url: url,
                 content_type: "image/png",
                 byte_size: 9,
                 filename: "diagram.png"
               }
             ] = attached_row.attachments

      assert url == "/chat/attachments/#{attachment.id}"
    end

    test "space_get_messages caps at 20", ctx do
      for i <- 1..25 do
        Chat.post_message(%{
          space_id: ctx.space.id,
          participant_id: ctx.participant.id,
          content_type: "text",
          content: "Msg #{i}"
        })
      end

      {:ok, results} =
        ToolSurface.execute(
          "space_get_messages",
          %{"space_id" => ctx.space.id, "limit" => 50},
          ctx.context
        )

      assert length(results) == 20
    end

    test "space_get_messages denied for non-member", ctx do
      other_space = create_space(%{name: "Locked"})

      {:error, error} =
        ToolSurface.execute(
          "space_get_messages",
          %{"space_id" => other_space.id},
          ctx.context
        )

      assert error.error =~ "Access denied"
    end

    test "space_get_messages supports before_id cursor", ctx do
      {:ok, msg1} =
        Chat.post_message(%{
          space_id: ctx.space.id,
          participant_id: ctx.participant.id,
          content_type: "text",
          content: "First"
        })

      {:ok, _msg2} =
        Chat.post_message(%{
          space_id: ctx.space.id,
          participant_id: ctx.participant.id,
          content_type: "text",
          content: "Second"
        })

      {:ok, msg3} =
        Chat.post_message(%{
          space_id: ctx.space.id,
          participant_id: ctx.participant.id,
          content_type: "text",
          content: "Third"
        })

      {:ok, results} =
        ToolSurface.execute(
          "space_get_messages",
          %{"space_id" => ctx.space.id, "before_id" => msg3.id},
          ctx.context
        )

      ids = Enum.map(results, & &1.id)
      refute msg3.id in ids
      assert msg1.id in ids
    end

    test "space_get_messages returns full content for messages within cap", ctx do
      body = String.duplicate("a", 1_000)

      {:ok, posted} =
        Chat.post_message(%{
          space_id: ctx.space.id,
          participant_id: ctx.participant.id,
          content_type: "text",
          content: body
        })

      {:ok, results} =
        ToolSurface.execute(
          "space_get_messages",
          %{"space_id" => ctx.space.id},
          ctx.context
        )

      row = Enum.find(results, &(&1.id == posted.id))
      assert row.content == body
      assert row.content_truncated == false
    end

    test "space_get_messages truncates content over cap and flags it", ctx do
      body = String.duplicate("a", 64_001)

      {:ok, posted} =
        Chat.post_message(%{
          space_id: ctx.space.id,
          participant_id: ctx.participant.id,
          content_type: "text",
          content: body
        })

      {:ok, results} =
        ToolSurface.execute(
          "space_get_messages",
          %{"space_id" => ctx.space.id},
          ctx.context
        )

      row = Enum.find(results, &(&1.id == posted.id))
      assert String.length(row.content) == 64_000
      assert row.content_truncated == true
    end

    # ── space_search_messages ──────────────────────────────────────

    test "space_search_messages returns matching messages", ctx do
      Chat.post_message(%{
        space_id: ctx.space.id,
        participant_id: ctx.participant.id,
        content_type: "text",
        content: "The deployment pipeline is working great"
      })

      Chat.post_message(%{
        space_id: ctx.space.id,
        participant_id: ctx.participant.id,
        content_type: "text",
        content: "Unrelated conversation about lunch"
      })

      {:ok, results} =
        ToolSurface.execute(
          "space_search_messages",
          %{"space_id" => ctx.space.id, "query" => "deployment pipeline"},
          ctx.context
        )

      assert length(results) >= 1
      assert Enum.any?(results, fn r -> r.content =~ "deployment" end)
    end

    test "space_search_messages caps at 10", ctx do
      for i <- 1..15 do
        Chat.post_message(%{
          space_id: ctx.space.id,
          participant_id: ctx.participant.id,
          content_type: "text",
          content: "Search target keyword banana #{i}"
        })
      end

      {:ok, results} =
        ToolSurface.execute(
          "space_search_messages",
          %{"space_id" => ctx.space.id, "query" => "banana", "limit" => 50},
          ctx.context
        )

      assert length(results) <= 10
    end

    test "space_search_messages denied for non-member", ctx do
      other_space = create_space(%{name: "Private"})

      {:error, error} =
        ToolSurface.execute(
          "space_search_messages",
          %{"space_id" => other_space.id, "query" => "test"},
          ctx.context
        )

      assert error.error =~ "Access denied"
    end

    test "space_search_messages flags content_truncated for short and long hits", ctx do
      # Short hit — well under cap, should come back untouched.
      short_body = "watermelon harvest report"

      {:ok, short_msg} =
        Chat.post_message(%{
          space_id: ctx.space.id,
          participant_id: ctx.participant.id,
          content_type: "text",
          content: short_body
        })

      # Long hit — body contains the same query token but is over the cap.
      long_body = "watermelon " <> String.duplicate("z", 64_001)

      {:ok, long_msg} =
        Chat.post_message(%{
          space_id: ctx.space.id,
          participant_id: ctx.participant.id,
          content_type: "text",
          content: long_body
        })

      {:ok, results} =
        ToolSurface.execute(
          "space_search_messages",
          %{"space_id" => ctx.space.id, "query" => "watermelon"},
          ctx.context
        )

      short_row = Enum.find(results, &(&1.id == short_msg.id))
      long_row = Enum.find(results, &(&1.id == long_msg.id))

      assert short_row, "expected short message in search results"
      assert short_row.content == short_body
      assert short_row.content_truncated == false

      assert long_row, "expected long message in search results"
      assert String.length(long_row.content) == 64_000
      assert long_row.content_truncated == true
    end

    # ── canvas_list ────────────────────────────────────────────────

    test "canvas_list returns canvases in a space", ctx do
      {:ok, canvas, _msg} =
        Chat.create_canvas_with_message(ctx.space.id, ctx.participant.id, %{
          "title" => "Test Canvas"
        })

      {:ok, results} =
        ToolSurface.execute(
          "canvas_list",
          %{"space_id" => ctx.space.id},
          ctx.context
        )

      assert length(results) >= 1
      entry = Enum.find(results, &(&1.id == canvas.id))
      assert entry.title == "Test Canvas"
      assert entry.kind == "stack"
      assert is_binary(entry.inserted_at)
    end

    test "canvas_list denied for non-member", ctx do
      other_space = create_space(%{name: "No Access"})

      {:error, error} =
        ToolSurface.execute(
          "canvas_list",
          %{"space_id" => other_space.id},
          ctx.context
        )

      assert error.error =~ "Access denied"
    end

    # ── canvas_get ─────────────────────────────────────────────────

    test "canvas_get returns summary by default", ctx do
      {:ok, canvas, _msg} =
        Chat.create_canvas_with_message(ctx.space.id, ctx.participant.id, %{
          "title" => "My Code"
        })

      {:ok, result} =
        ToolSurface.execute(
          "canvas_get",
          %{"canvas_id" => canvas.id},
          ctx.context
        )

      assert result.id == canvas.id
      assert result.title == "My Code"
      assert result.kind == "stack"
      assert result.space_id == ctx.space.id
      refute Map.has_key?(result, :document)
    end

    test "canvas_get with mode=full includes the document", ctx do
      {:ok, canvas, _msg} =
        Chat.create_canvas_with_message(ctx.space.id, ctx.participant.id, %{
          "title" => "Data Table"
        })

      {:ok, result} =
        ToolSurface.execute(
          "canvas_get",
          %{"canvas_id" => canvas.id, "mode" => "full"},
          ctx.context
        )

      assert result.id == canvas.id
      assert is_map(result.document)
      assert result.document["root"]["type"] == "stack"
    end

    test "canvas_get with non-existent canvas returns error", ctx do
      {:error, error} =
        ToolSurface.execute(
          "canvas_get",
          %{"canvas_id" => Ecto.UUID.generate()},
          ctx.context
        )

      assert error.error =~ "Canvas not found"
    end

    test "canvas_get denied for canvas in non-member space", ctx do
      other_space = create_space(%{name: "Locked Space"})
      other_participant = create_participant(other_space.id)

      {:ok, canvas, _msg} =
        Chat.create_canvas_with_message(other_space.id, other_participant.id, %{
          "title" => "Secret Canvas"
        })

      {:error, error} =
        ToolSurface.execute(
          "canvas_get",
          %{"canvas_id" => canvas.id},
          ctx.context
        )

      assert error.error =~ "Access denied"
    end

    # ── principal_search ──────────────────────────────────────────

    test "principal_search resolves an exact email to a user row with correct shape" do
      user =
        Repo.insert!(%Platform.Accounts.User{
          name: "Grace Chen",
          email: "grace-#{System.unique_integer([:positive])}@example.com",
          oidc_sub: "sub-grace-#{System.unique_integer([:positive])}"
        })

      {:ok, %{results: results}} =
        ToolSurface.execute("principal_search", %{"query" => user.email}, %{})

      assert Enum.any?(results, fn row ->
               row.type == "user" and row.id == user.id and row.display_name == "Grace Chen" and
                 row.email == user.email
             end)

      user_row = Enum.find(results, &(&1.id == user.id))
      assert Map.has_key?(user_row, :avatar_url)
    end

    test "principal_search finds an agent by slug substring and returns classification" do
      slug = "hermione-#{System.unique_integer([:positive])}"
      _agent = create_agent(%{slug: slug, name: "Hermione"})

      {:ok, %{results: results}} =
        ToolSurface.execute("principal_search", %{"query" => "hermione"}, %{})

      agent_row = Enum.find(results, &(&1.type == "agent" and &1.slug == slug))
      assert agent_row != nil
      assert agent_row.display_name == "Hermione"
      assert agent_row.kind == "native"

      assert agent_row.classification in [
               "ext_single_responsibility",
               "fed_conversational",
               "loc_built_in"
             ]
    end

    test "principal_search returns empty results for queries under 2 characters" do
      assert {:ok, %{results: []}} =
               ToolSurface.execute("principal_search", %{"query" => "a"}, %{})
    end

    test "principal_search rejects an invalid type filter" do
      {:error, err} =
        ToolSurface.execute(
          "principal_search",
          %{"query" => "anything", "type" => "bogus"},
          %{}
        )

      assert err.error =~ "type"
      assert err.recoverable == true
    end

    test "principal_search with type=agent excludes user rows" do
      slug = "geordi-#{System.unique_integer([:positive])}"
      _agent = create_agent(%{slug: slug, name: "Geordi"})

      _user =
        Repo.insert!(%Platform.Accounts.User{
          name: "Geordi La Forge",
          email: "geordi-#{System.unique_integer([:positive])}@example.com",
          oidc_sub: "sub-geordi-#{System.unique_integer([:positive])}"
        })

      {:ok, %{results: results}} =
        ToolSurface.execute(
          "principal_search",
          %{"query" => "geordi", "type" => "agent"},
          %{}
        )

      assert Enum.all?(results, &(&1.type == "agent"))
      assert Enum.any?(results, &(&1.slug == slug))
    end

    # ── auth: missing agent_id ─────────────────────────────────────

    test "read tools fail without agent_id in context", ctx do
      no_agent_ctx = %{}

      {:error, error} =
        ToolSurface.execute(
          "space_get_messages",
          %{"space_id" => ctx.space.id},
          no_agent_ctx
        )

      assert error.error =~ "Agent identity required"
    end

    # ── attachment.get_inline ──────────────────────────────────────

    test "attachment.get_inline returns base64 bytes for in-space caller", ctx do
      root =
        Path.join(System.tmp_dir!(), "att-inline-test-#{Ecto.UUID.generate()}")

      prev = Application.get_env(:platform, :chat_attachments_root)
      Application.put_env(:platform, :chat_attachments_root, root)

      on_exit(fn ->
        File.rm_rf(root)

        if prev do
          Application.put_env(:platform, :chat_attachments_root, prev)
        else
          Application.delete_env(:platform, :chat_attachments_root)
        end
      end)

      bytes = "hello-bytes"
      storage_key = "chat/test/inline-#{Ecto.UUID.generate()}.bin"
      target = Path.join(root, storage_key)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, bytes)

      {:ok, attachment} =
        Chat.create_attachment(%{
          space_id: ctx.space.id,
          filename: "blob.bin",
          content_type: "application/octet-stream",
          byte_size: byte_size(bytes),
          storage_key: storage_key,
          state: "ready"
        })

      {:ok, result} =
        ToolSurface.execute(
          "attachment.get_inline",
          %{"attachment_id" => attachment.id},
          ctx.context
        )

      assert result.content_type == "application/octet-stream"
      assert result.byte_size == byte_size(bytes)
      assert result.filename == "blob.bin"
      assert {:ok, ^bytes} = Base.decode64(result.data_base64)
    end

    test "attachment.get_inline rejects payloads above the 25MB cap", ctx do
      {:ok, attachment} =
        Chat.create_attachment(%{
          space_id: ctx.space.id,
          filename: "huge.bin",
          content_type: "application/octet-stream",
          # 25MB + 1 byte
          byte_size: 25 * 1024 * 1024 + 1,
          storage_key: "chat/test/huge-#{Ecto.UUID.generate()}.bin",
          state: "ready"
        })

      {:error, error} =
        ToolSurface.execute(
          "attachment.get_inline",
          %{"attachment_id" => attachment.id},
          ctx.context
        )

      assert error.reason == :too_large
      assert error.error =~ "exceeds inline read cap"
    end

    test "attachment.get_inline denied for caller not in attachment's space", ctx do
      other_space = create_space(%{name: "Other"})

      {:ok, attachment} =
        Chat.create_attachment(%{
          space_id: other_space.id,
          filename: "secret.bin",
          content_type: "application/octet-stream",
          byte_size: 4,
          storage_key: "chat/test/s-#{Ecto.UUID.generate()}.bin",
          state: "ready"
        })

      {:error, error} =
        ToolSurface.execute(
          "attachment.get_inline",
          %{"attachment_id" => attachment.id},
          ctx.context
        )

      assert error.error =~ "not a participant"
    end

    test "attachment.get_inline 404 when attachment does not exist", ctx do
      {:error, error} =
        ToolSurface.execute(
          "attachment.get_inline",
          %{"attachment_id" => Ecto.UUID.generate()},
          ctx.context
        )

      assert error.error =~ "not found"
    end
  end

  # ── task_attach_canvas / task_detach_canvas / task_list_canvases ───────

  describe "task_attach_canvas / task_detach_canvas / task_list_canvases" do
    setup do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Attach me"})

      space = create_space()
      participant = create_participant(space.id)

      {:ok, canvas} =
        Chat.create_canvas(%{
          "space_id" => space.id,
          "created_by" => participant.id,
          "title" => "Evidence canvas"
        })

      agent_id = Ecto.UUID.generate()
      context = %{agent_id: agent_id, space_id: space.id, agent_participant_id: participant.id}

      %{
        project: project,
        task: task,
        space: space,
        participant: participant,
        canvas: canvas,
        agent_id: agent_id,
        context: context
      }
    end

    test "task_attach_canvas happy round-trip via ToolSurface.execute/3", ctx do
      {:ok, result} =
        ToolSurface.execute(
          "task_attach_canvas",
          %{
            "task_id" => ctx.task.id,
            "canvas_id" => ctx.canvas.id,
            "note" => "first attach"
          },
          ctx.context
        )

      assert is_binary(result.attachment_id)
      assert result.task_id == ctx.task.id
      assert result.canvas_id == ctx.canvas.id
      assert result.note == "first attach"
    end

    test "task_attach_canvas idempotent re-attach returns same id with updated note", ctx do
      {:ok, first} =
        ToolSurface.execute(
          "task_attach_canvas",
          %{
            "task_id" => ctx.task.id,
            "canvas_id" => ctx.canvas.id,
            "note" => "first"
          },
          ctx.context
        )

      {:ok, second} =
        ToolSurface.execute(
          "task_attach_canvas",
          %{
            "task_id" => ctx.task.id,
            "canvas_id" => ctx.canvas.id,
            "note" => "second"
          },
          ctx.context
        )

      assert second.attachment_id == first.attachment_id
      assert second.note == "second"
    end

    test "task_attach_canvas with missing task_id returns recoverable error", ctx do
      {:error, error} =
        ToolSurface.execute(
          "task_attach_canvas",
          %{"canvas_id" => ctx.canvas.id},
          ctx.context
        )

      assert error.error =~ "task_id"
      assert error.recoverable == true
    end

    test "task_attach_canvas with unknown task surfaces task_not_found", ctx do
      {:error, error} =
        ToolSurface.execute(
          "task_attach_canvas",
          %{
            "task_id" => Ecto.UUID.generate(),
            "canvas_id" => ctx.canvas.id
          },
          ctx.context
        )

      assert error.error =~ "Task not found"
      assert error.recoverable == false
    end

    test "task_attach_canvas with unknown canvas surfaces canvas_not_found", ctx do
      {:error, error} =
        ToolSurface.execute(
          "task_attach_canvas",
          %{
            "task_id" => ctx.task.id,
            "canvas_id" => Ecto.UUID.generate()
          },
          ctx.context
        )

      assert error.error =~ "Canvas not found"
      assert error.recoverable == false
    end

    test "task_list_canvases returns hydrated rows after attach", ctx do
      {:ok, _} =
        ToolSurface.execute(
          "task_attach_canvas",
          %{
            "task_id" => ctx.task.id,
            "canvas_id" => ctx.canvas.id,
            "note" => "listing test"
          },
          ctx.context
        )

      {:ok, %{canvases: canvases}} =
        ToolSurface.execute(
          "task_list_canvases",
          %{"task_id" => ctx.task.id},
          ctx.context
        )

      assert [row] = canvases
      assert row.canvas_id == ctx.canvas.id
      assert row.title == "Evidence canvas"
      assert row.note == "listing test"
      assert row.canvas_present == true
      assert is_binary(row.attached_at)
      assert is_binary(row.attachment_id)
    end

    test "task_list_canvases returns empty list for task with no attachments", ctx do
      {:ok, %{canvases: canvases}} =
        ToolSurface.execute(
          "task_list_canvases",
          %{"task_id" => ctx.task.id},
          ctx.context
        )

      assert canvases == []
    end

    test "task_detach_canvas removes the attachment and list returns empty", ctx do
      {:ok, _} =
        ToolSurface.execute(
          "task_attach_canvas",
          %{
            "task_id" => ctx.task.id,
            "canvas_id" => ctx.canvas.id
          },
          ctx.context
        )

      {:ok, detach_result} =
        ToolSurface.execute(
          "task_detach_canvas",
          %{
            "task_id" => ctx.task.id,
            "canvas_id" => ctx.canvas.id
          },
          ctx.context
        )

      assert detach_result == %{detached: true}

      {:ok, %{canvases: canvases}} =
        ToolSurface.execute(
          "task_list_canvases",
          %{"task_id" => ctx.task.id},
          ctx.context
        )

      assert canvases == []
    end

    test "task_detach_canvas returns not_found for unattached pair", ctx do
      {:error, error} =
        ToolSurface.execute(
          "task_detach_canvas",
          %{
            "task_id" => ctx.task.id,
            "canvas_id" => ctx.canvas.id
          },
          ctx.context
        )

      assert error.error =~ "No attachment found"
      assert error.recoverable == false
    end
  end

  # ── task_create similar_tasks (stage 4, task 019f3dbb) ────────────────
  #
  # Pins the advisory `similar_tasks` field the `task_create` MCP handler
  # attaches after a successful create. Plan reference:
  # https://suite/tasks/019f3dbb (stage 4 — `task_create` response body).
  #
  # The similarity search runs synchronously so the response envelope
  # carries the near-duplicate signal without a follow-up `memory_search`
  # round-trip. It never blocks the create — a Search failure surfaces
  # as `similar_tasks: []`. Project scope + self-match exclusion +
  # threshold (see `similar_tasks_for/1` in `tool_surface.ex` for the
  # rank-based confidence rationale) are the load-bearing invariants.

  describe "task_create similar_tasks (stage 4, task 019f3dbb)" do
    setup do
      # Force the Noop provider so tests don't touch an external memory
      # service. Lexical channel alone is enough to prove the similarity
      # plumbing — the semantic channel is exercised by the search_test
      # StubProvider fixtures at stage 3.
      prev = Application.get_env(:platform, :memory_service, [])

      Application.put_env(:platform, :memory_service, provider: Platform.Memory.Providers.Noop)

      on_exit(fn -> Application.put_env(:platform, :memory_service, prev) end)
      :ok
    end

    defmodule TS4ErrorProvider do
      @behaviour Platform.Memory.Provider

      @impl true
      def ingest(_entries, _config), do: {:ok, 0}

      @impl true
      def search(_query, _opts, _config), do: {:error, :simulated_outage}

      @impl true
      def delete(_ids, _config), do: {:ok, 0}

      @impl true
      def health(_c), do: {:error, :simulated_outage}
    end

    test "fresh create returns similar_tasks: [] when project has no other tasks" do
      project = create_project()

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{"project_id" => project.id, "title" => "Fresh solo task"},
          %{}
        )

      assert Map.has_key?(result, :similar_tasks)
      assert result.similar_tasks == []
    end

    test "similar_tasks: [] for a title that is deliberately orthogonal to seeded tasks" do
      project = create_project()

      {:ok, _seeded} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Fix summarizer memory leak",
          description: "Investigate the 20MB per meeting leak"
        })

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Migrate PostgreSQL 14 to 16 with pg_upgrade",
            "description" => "Detailed steps for the DB engine upgrade"
          },
          %{}
        )

      # Orthogonal content shares no lexical tokens with the seeded
      # task's title/description → no channel returns a hit → empty
      # array (not nil).
      assert result.similar_tasks == []
    end

    test "creating a near-duplicate returns the seeded task in similar_tasks" do
      project = create_project()

      {:ok, seeded} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Fix summarizer memory leak",
          description:
            "Investigate and fix the memory leak in the meeting summarizer that leaks 20MB per meeting",
          priority: "high"
        })

      # Move the seeded task to in_progress so the advisory `status` on
      # the hit surfaces the "already in flight" signal.
      {:ok, seeded} = Tasks.transition_task_status(seeded, "in_progress")

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "summarizer memory leak fix",
            "description" => "the summarizer leaks memory each meeting - fix it",
            "priority" => "medium"
          },
          %{}
        )

      # Task B was created successfully with the expected defaults.
      assert result.status == "backlog"
      assert is_binary(result.id)

      # Exactly the seeded task surfaces as a similar task, carrying
      # the advisory fields the agent uses to decide "in-flight" vs
      # "shipped-clean" vs "was-supposed-to-work".
      assert [entry] = result.similar_tasks
      assert entry.id == seeded.id
      assert entry.status == "in_progress"
      assert entry.priority == "high"
      assert entry.similarity_score >= 0.5
      assert entry.follow_up_task_ids == []
      assert entry.merged_pr_url == nil
      assert entry.cancellation_note == nil
      assert is_binary(entry.title)
      assert is_binary(entry.updated_at)
    end

    test "self-match is excluded from similar_tasks" do
      # The just-created task's own title/description will tsvector-match
      # itself at rank 1 — the handler must strip it from the results
      # before returning. Otherwise every create would return a
      # `similar_tasks` entry pointing at the newly-created task itself,
      # which is meaningless noise.
      project = create_project()

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Ship phantom flood dedupe fix",
            "description" => "Dedupe LiveKit webhooks by event id"
          },
          %{}
        )

      assert Enum.all?(result.similar_tasks, fn entry -> entry.id != result.id end)
    end

    test "similar_tasks never contains tasks from a different project" do
      project_a = create_project()
      project_b = create_project()

      {:ok, _in_b} =
        Tasks.create_task(%{
          project_id: project_b.id,
          title: "unique investigation topic alpha bravo",
          description: "body in project B"
        })

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project_a.id,
            "title" => "unique investigation topic alpha bravo",
            "description" => "body in project A"
          },
          %{}
        )

      # Byte-identical titles across projects must not leak — project
      # scope is enforced by the `project_id` filter passed to
      # `Search.search`. The response array shows only tasks in
      # project_a, and since project_a had no other tasks pre-create,
      # after self-exclusion the array is empty.
      assert result.similar_tasks == []
    end

    test "similar_tasks filters weak matches below the 0.5 confidence threshold" do
      # The rank-based confidence is `1.0 / min(semantic_rank, lexical_rank)`,
      # so rank-3 hits (confidence 0.33) fall below the 0.5 cutoff. Seed
      # three tsvector-matching tasks; the top-2 pass the threshold, the
      # third is filtered out.
      project = create_project()

      for i <- 1..3 do
        {:ok, _} =
          Tasks.create_task(%{
            project_id: project.id,
            title: "raspberry gizmo cluster candidate #{i}",
            description: "one of several near-matches"
          })
      end

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "raspberry gizmo cluster",
            "description" => "the definitive one"
          },
          %{}
        )

      assert length(result.similar_tasks) <= 2

      assert Enum.all?(result.similar_tasks, fn entry ->
               entry.similarity_score >= 0.5
             end)
    end

    test "similar_tasks: [] when the semantic provider is unavailable (advisory degrade)" do
      # Swap the provider for one whose search/3 returns `{:error, _}`.
      # `Search.search` degrades to lexical-only in that case, and with
      # no other tasks in the project, the response array is empty. The
      # important invariant: task_create still succeeds and the field is
      # present-and-empty, not missing. Same shape a memory-service
      # outage produces in prod.
      Application.put_env(:platform, :memory_service, provider: TS4ErrorProvider)

      on_exit(fn ->
        Application.put_env(:platform, :memory_service, provider: Platform.Memory.Providers.Noop)
      end)

      project = create_project()

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{"project_id" => project.id, "title" => "Provider errored — still create"},
          %{}
        )

      # Task was created successfully.
      assert is_binary(result.id)

      # The advisory field is present-and-empty, not missing.
      assert Map.has_key?(result, :similar_tasks)
      assert result.similar_tasks == []
    end

    test "similar_tasks: [] when the task has nil description (defensive query normalization)" do
      # `normalize_similarity_query/1` strips punctuation before handing
      # the query to `Search.search`. A task with only a title (no
      # description) still produces a well-formed query and never raises.
      project = create_project()

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{"project_id" => project.id, "title" => "Just a title, no body"},
          %{}
        )

      assert Map.has_key?(result, :similar_tasks)
      assert result.similar_tasks == []
    end

    test "tool_definitions/0 advertises similar_tasks in task_create's `returns`" do
      # Pin the wire-contract prose so a future refactor doesn't silently
      # drop the advisory field description from the tool catalog.
      tools = ToolSurface.tool_definitions()
      task_create = Enum.find(tools, &(&1.name == "task_create"))

      assert task_create.returns =~ "similar_tasks"
      assert task_create.returns =~ "similarity_score"
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  # `space_leave` calls ActiveAgentStore.clear_if_match/2 — start the GenServer
  # the first time a test needs it and allow the test process to share the
  # repo sandbox connection.
  defp ensure_active_agent_store do
    alias Ecto.Adapters.SQL.Sandbox
    alias Platform.Chat.ActiveAgentStore

    pid =
      case Process.whereis(ActiveAgentStore) do
        nil -> start_supervised!({ActiveAgentStore, []})
        existing -> existing
      end

    Sandbox.allow(Repo, self(), pid)
    :ok
  end

  defp create_agent(attrs \\ %{}) do
    defaults = %{
      slug: "agent-#{System.unique_integer([:positive])}",
      name: "TestAgent",
      status: "active",
      max_concurrent: 1,
      sandbox_mode: "off",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    }

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    agent
  end
end
