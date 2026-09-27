defmodule Platform.Federation.ToolSurfaceTest do
  use Platform.DataCase, async: false

  import Platform.SubmittablePlanFixtures

  alias Platform.Agents.Agent
  alias Platform.Chat

  alias Platform.Tasks
  alias Platform.Tasks.CanvasAttachments
  alias Platform.Tenancy
  alias Platform.Federation.ToolArguments
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

  # A planner-authored e2e_behavior case (task 01a006d1 stage 3).
  defp e2e_case(name) do
    %{
      "kind" => "e2e_behavior",
      "evaluation_payload" => %{
        "setup" => "seed a #{name}",
        "actions" => "open #{name}",
        "expected" => "#{name} renders"
      }
    }
  end

  # A live task in a fresh project with `canvas` attached to it — the relation
  # the `:task_agent` canvas grant reads (task 019fb01b stage 2).
  #
  # `:system` is the attaching actor because whether the ATTACHER was
  # authorized against the task is a separate open question, filed as task
  # 019fb581. What these tests need is only that the attachment row exists.
  defp task_with_attached_canvas!(canvas) do
    project = create_project()
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Design direction task"})

    {:ok, _attachment} =
      CanvasAttachments.attach_canvas(:system, task.id, canvas.id,
        attached_by: %{kind: "user", id: Ecto.UUID.generate()}
      )

    task
  end

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
    test "returns all 100 tools with required components" do
      tools = ToolSurface.tool_definitions()
      # 88 as of task 019f70b8 stage 3, which added `intent_ack` to the
      # `task` bundle. 89 as of ADR-0046 member 5 stage 4, which added
      # `plan_architecture_verdict` to the `plan` bundle. 90 as of ADR-0046
      # member 7 / task 019fa504 stage 2, which added `task_design_decline`
      # to the `task` bundle. 91 as of task 019fa61c stage 3, which added
      # `stage_architecture_audit` to the `plan` bundle — the architect's
      # OTHER surface, which until now asked for a side effect in prose and
      # named no tool at all. 92 as of task 019fe844 stage 3, which added
      # `design_critique_request` to the `review` bundle — the same shape of
      # defect one layer down: the reviewer dispatch template asked for a
      # design review in prose and named no tool that could obtain one.
      # 94 as of task 01a00570 stage 2, which added `review_request_get` and
      # `review_item_list` to the same `review` bundle — an agent could file
      # evidence for a human verdict and then had no way to read the verdict
      # back, so a rejection's feedback text was unreachable to the agent
      # expected to act on it.
      # 95 as of task 01a006c2 stage 1, which added `task_transition_list` to
      # the `task` bundle — the status-transition rows existed and were
      # written transactionally, but no agent without DB access could read
      # them back.
      # 97 as of task 01a006c2 stage 2, which added `runtime_event_list` and
      # `execution_lease_list` to the `task` bundle — the runtime-event and
      # lease rows existed, but reading them back to refute a watchdog
      # no-ack alarm required database access nobody federated has.
      # 98 with `space_create` in the `space` bundle — channel creation had no
      # tool at all, so agents fell back to a raw `Chat.create_channel/1` RPC
      # that wrote NULL participant display names and silently broke mention
      # routing for the agents in those channels.
      # 99 as of task 01a04ad4, which added `dm_create` to the `space` bundle
      # — an agent had no way to reach a human directly at all: no DM tool, no
      # mention path into a DM (`chat.ex`'s DM exemption), and no implicit
      # join (`@implicitly_joinable_kinds` excludes `dm`). Being ADDED to a DM
      # by a human was the only way in.
      # 100 as of task 01a05392 stage 3, which added `stack_retry_member_merge`
      # to the `task` bundle — a stack member whose rollup merge was paused as
      # `rollup_diverged` had no named way to re-run it: the only retriggers
      # were side effects (a validation_pass on an in_review task, or an
      # in_review -> in_progress -> in_review round trip) documented nowhere an
      # agent reads.
      # 101 as of task 01a05b32 stage 1, which added `plan_reject` to the
      # `plan` bundle — a draft plan blocked every plan_create and had no
      # reject affordance anywhere (the UI control only appears once the plan
      # reaches pending_review), so a stuck draft cost a human round-trip.
      # 102 as of task 01a05b32 stage 2, which added `plan_update` to the
      # `plan` bundle — the planner's IN-PLACE draft correction: fix the
      # wrong draft (stages, positions, validations) where it stands, id +
      # version stable, then plan_submit. No new bundle.
      # 103 as of task 01a06672 stage 2, which added `meeting_say` to the
      # `task` bundle beside `meeting_create` — an agent speaking arbitrary
      # text into a meeting it was invited into, in its own voice, with the
      # runtime's ack returned as `spoken` / `failed` / `no_ack`. No new bundle.
      # 104 as of task 01a07400 stage 1, which added `meeting_activity_push`
      # to the `task` bundle beside the other two meeting tools — a runtime
      # declaring `thinking` / `composing` about itself in a meeting, with a
      # server-side ttl that expires the declaration whether or not the
      # runtime survives to withdraw it. No new bundle.
      # Still 104 after task 01a066af stage 4, which added the `meetings`
      # bundle and MOVED `meeting_create` and `meeting_say` into it out of
      # `task`. A move registers no new tool, so the total is unchanged — a
      # change here would mean a tool was copied rather than moved.
      # Still 104 after task 01a083c3 stage 1, which MOVED
      # `meeting_activity_push` out of `task` into `meetings`, joining the
      # two tools 01a066af stage 4 moved — 01a07400 stage 1 had registered it
      # in `task`, so a default runtime could speak in a meeting but could not
      # say it was thinking. A move registers no new tool, so the total is
      # unchanged — a change here would mean the tool was copied, not moved.
      # 105 as of task 01a0a552 stage 3, which added `task_close_as_delivered`
      # to the `task` bundle: the admin-delegated closure for work that
      # shipped without a plan cycle. A genuinely new tool, not a move, so
      # the total moves with it.
      # 119 as of task 01a0d415 stage 2, which added the `experiments` bundle:
      # 14 genuinely new `experiment_*` tools, in a new bundle that is NOT a
      # default grant (`tool_surface_experiments_test.exs` pins that).
      # 120 as of task 01a0acb4 stage 2, which added `validation_payload_amend`
      # to the `plan` bundle: the correction path for ONE defective e2e case
      # on an approved/executing plan. A genuinely new tool, no new bundle.
      assert length(tools) == 120

      tool_names = Enum.map(tools, & &1.name)
      assert "task_close_as_delivered" in tool_names
      assert "send_media" in tool_names
      assert "react" in tool_names
      assert "canvas.versions" in tool_names
      assert "canvas.restore" in tool_names
      assert "space_create" in tool_names
      assert "dm_create" in tool_names
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
      assert "task_ack" in tool_names
      assert "alarm_silence" in tool_names
      assert "task_complete" in tool_names
      assert "task_dependencies" in tool_names
      assert "task_attach_canvas" in tool_names
      # ADR-0046 member 7 / task 019fa504 stage 2 — the designer's decline
      # exit. The six-component rubric below is what this assertion buys; the
      # bundle placement and the refusal taxonomy are pinned in
      # `tool_surface_design_decline_test.exs`.
      assert "task_design_decline" in tool_names
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
      # Task 01a05392 stage 3 — the named retry for a paused stack member.
      # Pinned by exact string so a declaration-without-executor or an
      # executor-without-declaration cannot pass.
      assert "stack_retry_member_merge" in tool_names
      assert "stack_assign_agents" in tool_names
      assert "meeting_create" in tool_names
      # Task 01a07400 stage 1 — self-declared agent activity in a meeting.
      assert "meeting_activity_push" in tool_names
      assert "plan_create" in tool_names
      assert "plan_get" in tool_names
      assert "plan_submit" in tool_names
      # Task 01a05b32 stage 1 — the planner's self-service draft exit, in the
      # existing `plan` bundle (no new bundle).
      assert "plan_reject" in tool_names
      # Task 01a05b32 stage 2 — the planner's in-place draft correction, in
      # the same `plan` bundle (no new bundle).
      assert "plan_update" in tool_names
      # ADR-0046 member 5 stage 4 — the architect's verdict surface. The
      # six-component rubric below is what this assertion buys; the
      # bundle placement and the refusal taxonomy are pinned in
      # `plan_architecture_verdict_tool_test.exs`.
      assert "plan_architecture_verdict" in tool_names
      # Task 019fa61c stage 3 — the architect's audit surface. The
      # six-component rubric below is what this assertion buys; the bundle
      # placement and the refusal taxonomy are pinned in
      # `stage_architecture_audit_tool_test.exs`.
      assert "stage_architecture_audit" in tool_names
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
      # Memory-feedback read tools (task 019f6381 stage 4) — thin read-only
      # wrappers over Platform.MemoryFeedback.list_recent/1. Live in the
      # `memory` bundle alongside memory_view / memory_search.
      assert "org_memory_recently_edited" in tool_names
      assert "org_memory_recently_deleted" in tool_names
      assert "org_memory_feedback_at_path" in tool_names

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

    # Task 01a066af stage 4 — `meeting_create` and `meeting_say` used to be
    # registered inside `task_tools/0`, so they were stamped `"task"`, a bundle
    # absent from `AgentRuntime.default_allowed_bundles/0`. A voice-capable
    # runtime on the defaults was refused by `ToolAuthorization.authorize/2`
    # and could not speak at all. Both directions are asserted: presence in
    # `meetings` alone would still pass if the tools had merely been COPIED.
    test "meeting_say is in the meetings bundle and not in task" do
      meetings = ToolSurface.list_tools(["meetings"]) |> Enum.map(& &1.name)
      task = ToolSurface.list_tools(["task"]) |> Enum.map(& &1.name)

      assert "meeting_say" in meetings
      assert "meeting_create" in meetings
      refute "meeting_say" in task
      refute "meeting_create" in task

      assert Enum.all?(ToolSurface.list_tools(["meetings"]), &(&1.bundle == "meetings"))
    end

    # Task 01a083c3 stage 1 — `meeting_activity_push` was registered in
    # `task_tools/0` by 01a07400 stage 1, after 01a066af stage 4 had already
    # moved the other two meeting tools out, so it was stamped `"task"`.
    #
    # This asserts bundle MEMBERSHIP only, and is deliberately independent of
    # `AgentRuntime.default_allowed_bundles/0`: removing `"meetings"` from the
    # default grant must leave this test green, because a bundle can exist and
    # be populated without being granted by default. The companion test in
    # `agent_runtime_test.exs` is what pins the grant.
    #
    # Both directions are required. Presence in `meetings` alone still passes
    # if the tool was COPIED rather than moved, and a copy is the plausible
    # wrong implementation here.
    test "meeting_activity_push is in the meetings bundle and not in task" do
      meetings = ToolSurface.list_tools(["meetings"]) |> Enum.map(& &1.name)
      task = ToolSurface.list_tools(["task"]) |> Enum.map(& &1.name)

      assert "meeting_activity_push" in meetings
      refute "meeting_activity_push" in task
    end

    # Task 01a083c3 stage 3, WIDENED by task 01a08875 stage 1 — the CLASS
    # guard, not the instance. 01a066af stage 4 moved `meeting_create` and
    # `meeting_say` out of `task`; 01a083c3 stage 1 moved
    # `meeting_activity_push`; 01a08875 stage 1 moved `intent_ack`. This pins
    # the RULE rather than a fourth name, so a future meeting-scoped
    # descriptor added to `task_tools/0` reddens here instead of arriving as
    # yet another follow-up ticket. `task` is absent from
    # `AgentRuntime.default_allowed_bundles/0`, so a meeting-scoped tool
    # landing there is simply unreachable for a default runtime.
    #
    # The class is NOT the `meeting_` name prefix, and that mattered. As
    # originally written this test WAS a prefix guard, and it recorded
    # `intent_ack` as a "KNOWN EXCEPTION ... NOT catchable by a prefix guard",
    # justified by the claim that every dispatch-capable runtime already holds
    # `task`. That claim was false when written — `task` has never appeared in
    # `@default_allowed_bundles` on any commit — and the exemption it bought is
    # why `intent_ack` survived two cleanups of this exact bug class. The
    # prefix WAS the exemption: with the comment deleted and `intent_ack` put
    # back in `task_tools/0`, the prefix version of this test still passed.
    #
    # So the class is defined by the HANDLE a tool takes, which is what
    # actually makes it meeting-scoped: a `meeting_` name, or a `meeting_id` /
    # `intent_id` parameter. That covers all four names above with no list to
    # maintain, and it is what reddens under the mutation.
    test "no meeting-scoped tool is registered in the task bundle" do
      meeting_scoped? = fn tool ->
        String.starts_with?(tool.name, "meeting_") or
          Enum.any?(Map.keys(tool.parameters), &(&1 in [:meeting_id, :intent_id]))
      end

      refute Enum.any?(ToolSurface.list_tools(["task"]), meeting_scoped?)

      # Anti-vacuity. Without the first the refute would still pass if
      # `list_tools/1` started returning `[]`; without the second it would pass
      # if the `meetings` bundle were emptied.
      assert length(ToolSurface.list_tools(["task"])) > 0
      assert Enum.any?(ToolSurface.list_tools(["meetings"]), meeting_scoped?)

      # And the predicate must still recognise the NON-prefix member of the
      # class, or this guard has silently narrowed back to the prefix rule it
      # replaced and the exemption is back in force by omission.
      intent_ack = ToolSurface.list_tools(["meetings"]) |> Enum.find(&(&1.name == "intent_ack"))

      assert intent_ack
      assert meeting_scoped?.(intent_ack)
      refute String.starts_with?(intent_ack.name, "meeting_")
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

    # Task 01a05b32 stage 3 — the plan bundle's EXACT membership. The
    # total-count gate above catches an addition anywhere; this pins the
    # bundle itself: the pre-01a05b32 set PLUS the two draft-exit tools
    # from stages 1–2 — and nothing moved in or out. The bundle is wider
    # than the plan_* prefix: plan_tools/0 also carries the execution-side
    # stage/validation surfaces (stage_start, validation_evaluate,
    # report_blocker, prompt templates) because a plan's stages and
    # validations ARE the plan surface. Deliberate, not incidental: a tool
    # here is an agent-facing commitment.
    # Task 01a0acb4 stage 2 added `validation_payload_amend`, the past-draft
    # counterpart to plan_update for ONE e2e case's text.
    test "plan bundle is exactly the previous set plus plan_reject, plan_update and validation_payload_amend" do
      tools = ToolSurface.list_tools(["plan"])
      names = tools |> Enum.map(& &1.name) |> Enum.sort()

      assert names ==
               Enum.sort([
                 "plan_approve",
                 "plan_architecture_verdict",
                 "plan_create",
                 "plan_get",
                 "plan_reject",
                 "plan_submit",
                 "plan_update",
                 "prompt_template_list",
                 "prompt_template_update",
                 "report_blocker",
                 "stage_architecture_audit",
                 "stage_complete",
                 "stage_list",
                 "stage_start",
                 "validation_evaluate",
                 "validation_list",
                 "validation_pass",
                 "validation_payload_amend"
               ])

      assert Enum.all?(tools, &(&1.bundle == "plan"))
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

    # VACUOUS-TEST FINDING (019fa609 stage 4), the second of two in this file.
    #
    # This asserted `error =~ "project_id"` against execute/3. When
    # meeting_create's dedicated `{:error, {:missing, field}}` clause was
    # deleted, the test kept passing for the wrong reason: `Meetings`
    # still returns `{:missing, :project_id}`, the catch-all now wraps it as
    # "Failed to create meeting: {:missing, :project_id}", and that string
    # still contains "project_id" and is still recoverable. Green, testing a
    # refusal nobody wrote.
    #
    # Re-pointed at dispatch/3 with a `code` assertion so it can fail, and the
    # message assertion tightened to the gate's own wording rather than a
    # substring both producers happen to share.
    test "meeting_create without project_id returns a recoverable error" do
      {:error, error} =
        ToolArguments.dispatch("meeting_create", %{"name" => "No project"}, %{})

      assert error.error =~ "meeting_create: project_id is required"
      assert error.code == :missing_project_id
      assert error.recoverable == true
    end

    # The seam the deletion left behind, pinned so it is a recorded behaviour
    # and not an accident: the gate checks PRESENCE, not type. A present but
    # non-binary project_id passes the gate, reaches the handler, and falls to
    # the catch-all — where the dedicated `{:missing, field}` message used to
    # be. Type validation is explicitly out of the gate's scope (see the
    # ToolArguments moduledoc), so this is the answer such a caller now gets.
    test "meeting_create with a non-binary project_id falls through the gate to the catch-all" do
      {:error, error} =
        ToolArguments.dispatch(
          "meeting_create",
          %{"project_id" => 12_345, "name" => "Bad type"},
          %{}
        )

      refute error.error =~ "is required"
      assert error.error =~ "Failed to create meeting"
      assert error.recoverable == true
    end

    # ── meeting_create: the intended-time pair ───────────────────────────
    #
    # `Meetings.create_meeting/1` builds an explicit whitelist map, so a key
    # the tool forwards can still be dropped before the changeset sees it.
    # Every test below that claims a value was accepted re-reads the row —
    # asserting the response alone would stay green for a handler that echoed
    # its own arguments back without persisting anything.

    test "meeting_create persists both intended-time endpoints and returns them as ISO8601" do
      project = create_project()

      {:ok, result} =
        ToolSurface.execute(
          "meeting_create",
          %{
            "project_id" => project.id,
            "name" => "Design Review",
            "scheduled_start_at" => "2026-08-04T15:00:00Z",
            "scheduled_end_at" => "2026-08-04T16:30:00Z"
          },
          %{}
        )

      assert result.scheduled_start_at == "2026-08-04T15:00:00.000000Z"
      assert result.scheduled_end_at == "2026-08-04T16:30:00.000000Z"

      meeting = Platform.Meetings.get_meeting(result.id)
      assert meeting.scheduled_start_at == ~U[2026-08-04 15:00:00.000000Z]
      assert meeting.scheduled_end_at == ~U[2026-08-04 16:30:00.000000Z]

      # The actuals are untouched by scheduling — the whole point of a second
      # pair of columns is that intent and what happened are separate facts.
      assert is_nil(meeting.started_at)
      assert is_nil(meeting.ended_at)
    end

    test "meeting_create without either endpoint still succeeds and returns both keys as nil" do
      project = create_project()

      {:ok, result} =
        ToolSurface.execute(
          "meeting_create",
          %{"project_id" => project.id, "name" => "Ad Hoc"},
          %{}
        )

      # Key PRESENCE is asserted separately from the value: a serializer that
      # dropped the keys entirely would satisfy `result[:scheduled_start_at]
      # == nil` on a plain map lookup and pass a value-only test.
      assert Map.has_key?(result, :scheduled_start_at)
      assert Map.has_key?(result, :scheduled_end_at)
      assert is_nil(result.scheduled_start_at)
      assert is_nil(result.scheduled_end_at)

      meeting = Platform.Meetings.get_meeting(result.id)
      assert is_nil(meeting.scheduled_start_at)
      assert is_nil(meeting.scheduled_end_at)
    end

    test "meeting_create with a malformed scheduled_start_at is refused by name and creates no row" do
      project = create_project()
      before_count = Repo.aggregate(Platform.Meetings.Meeting, :count)

      # Presence half of the pair: the same shape of call, with a parseable
      # start, does create a row. Without this the count assertion below could
      # pass against a handler that never creates meetings at all.
      {:ok, _ok} =
        ToolSurface.execute(
          "meeting_create",
          %{
            "project_id" => project.id,
            "name" => "Parseable",
            "scheduled_start_at" => "2026-08-04T15:00:00Z",
            "scheduled_end_at" => "2026-08-04T16:00:00Z"
          },
          %{}
        )

      assert Repo.aggregate(Platform.Meetings.Meeting, :count) == before_count + 1

      # Deliberately the lone-parameter shape: an agent that typo'd the only
      # timestamp it passed. A handler that coerced the unparseable value to
      # nil would leave attrs with NEITHER endpoint, sail past the pair
      # validation, and return {:ok, ad-hoc meeting} — so this shape is what
      # makes the row count able to move, and it is the failure that is
      # hardest to notice in production.
      {:error, error} =
        ToolSurface.execute(
          "meeting_create",
          %{
            "project_id" => project.id,
            "name" => "Vague",
            "scheduled_start_at" => "next tuesday"
          },
          %{}
        )

      assert error.recoverable == true
      assert error.error =~ "scheduled_start_at"
      refute error.error =~ "scheduled_end_at"
      assert Repo.aggregate(Platform.Meetings.Meeting, :count) == before_count + 1
    end

    # Mirror image of the test above. Naming scheduled_start_at correctly does
    # not prove the handler reads the key it was given — an implementation that
    # hard-coded "scheduled_start_at" into every parse failure would pass that
    # test and fail this one.
    test "meeting_create with a malformed scheduled_end_at is refused by name and creates no row" do
      project = create_project()
      before_count = Repo.aggregate(Platform.Meetings.Meeting, :count)

      {:error, error} =
        ToolSurface.execute(
          "meeting_create",
          %{
            "project_id" => project.id,
            "name" => "Vague End",
            "scheduled_start_at" => "2026-08-04T15:00:00Z",
            "scheduled_end_at" => "sometime after lunch"
          },
          %{}
        )

      assert error.recoverable == true
      assert error.error =~ "scheduled_end_at"

      # Reported as a malformed VALUE, not as a missing one. A handler that
      # coerced the unparseable end to nil would come back through the pair
      # validation as "is required when scheduled_start_at is set" — which
      # tells a caller that did supply an end to supply one, and is how a
      # silent coercion looks from the outside.
      refute error.error =~ "is required"
      assert Repo.aggregate(Platform.Meetings.Meeting, :count) == before_count
    end

    test "meeting_create with an end before the start returns an error and creates no row" do
      project = create_project()
      before_count = Repo.aggregate(Platform.Meetings.Meeting, :count)

      {:error, error} =
        ToolSurface.execute(
          "meeting_create",
          %{
            "project_id" => project.id,
            "name" => "Backwards",
            "scheduled_start_at" => "2026-08-04T16:00:00Z",
            "scheduled_end_at" => "2026-08-04T15:00:00Z"
          },
          %{}
        )

      # This one comes back through the changeset, not the parse guard — both
      # endpoints are valid timestamps. The message has to stay intelligible
      # to an agent, hence the assertion on the field and the reason rather
      # than merely on `recoverable`.
      assert error.recoverable == true
      assert error.error =~ "scheduled_end_at"
      assert error.error =~ "must be after scheduled_start_at"
      assert Repo.aggregate(Platform.Meetings.Meeting, :count) == before_count
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

      {:ok, %{tasks: results}} =
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

      {:ok, %{tasks: results}} =
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

      {:ok, %{tasks: results}} =
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

      {:ok, %{tasks: results}} = ToolSurface.execute("task_list", %{}, %{})

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

      # The machine code stays the prefix; task 01a0a4aa appends the
      # nothing-was-written sentence every pre-write refusal carries.
      assert String.starts_with?(error.error, "unresolved_deploy_target")
      assert error.error =~ "Nothing was written"
      assert error.recoverable == true
      assert is_binary(error.suggestion)
      assert error.suggestion =~ ~r/project_update|task_update/

      # Task did NOT transition.
      assert Tasks.get_task_record(task.id).status == "in_review"
    end

    # ── Sponsor-bypass plan gate through MCP (task 019f6380 stage 2) ──────
    #
    # Pre-stage-2 the MCP `task_update` path went straight through
    # `Tasks.transition_task_status/2`, which is the base primitive with
    # NO plan-approval gate. That let an agent transition any task into
    # an execution phase without an approved plan — precisely the bypass
    # the LiveView entry point was designed to prevent. Stage 2 wires an
    # explicit `Tasks.require_approved_plan_for/3` call into the MCP
    # execute pipeline with an agent-typed actor, so the gate now holds
    # for agent-initiated MCP calls too. These tests pin that behavior.

    test "task_update as agent on sponsor-only-no-agent task with no plan → gate holds (task 019f6380 stage 2)" do
      # Test case 4 from the task description, wired end-to-end through
      # the MCP surface. Sponsor-only shape (no agent involvement)
      # normally BYPASSES the plan gate — but ONLY for human actors.
      # An agent invoking task_update on the same shape must still be
      # blocked because the sponsor-bypass is a human-only exemption.
      project = create_project()
      sponsor = insert_user_for_sponsor()
      agent_id = Ecto.UUID.generate()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Sponsor-only, agent-initiated MCP",
          status: "backlog",
          sponsor_user_id: sponsor.id
        })

      {:error, error} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "status" => "in_progress"},
          %{agent_id: agent_id}
        )

      assert error.recoverable == true
      assert error.error =~ "Cannot transition to 'in_progress'"
      assert error.error =~ "no approved plan"
      assert error.suggestion =~ ~r/plan_create|plan_approve/

      # Task did NOT transition.
      assert Tasks.get_task_record(task.id).status == "backlog"
    end

    test "task_update as agent on agent-assigned task with no plan → gate holds (task 019f6380 stage 2)" do
      # Standard gate case: agent-assigned task with no plan. Pre-stage-2
      # this would have silently succeeded via the MCP path (no gate at
      # all). Post-stage-2 the friendly `:no_approved_plan` envelope
      # fires.
      project = create_project()
      agent_id = Ecto.UUID.generate()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Agent-only, gate must fire on MCP path",
          status: "backlog",
          assignee_id: agent_id,
          assignee_type: "agent"
        })

      {:error, error} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "status" => "in_progress"},
          %{agent_id: agent_id}
        )

      assert error.recoverable == true
      assert error.error =~ "Cannot transition to 'in_progress'"
    end

    test "task_update with no status change skips the plan gate entirely (task 019f6380 stage 2)" do
      # The `maybe_check_plan_gate/3` short-circuit: bare metadata
      # updates that don't touch status must never hit the gate. This
      # prevents a regression where the actor-threading refactor
      # accidentally makes every task_update require a plan.
      project = create_project()
      agent_id = Ecto.UUID.generate()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Rename me",
          status: "backlog",
          assignee_id: agent_id,
          assignee_type: "agent"
        })

      {:ok, result} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "title" => "Renamed"},
          %{agent_id: agent_id}
        )

      assert result.title == "Renamed"
      # And status is untouched.
      assert Tasks.get_task_record(task.id).status == "backlog"
    end

    test "task_update with an approved plan lets agent transition normally (task 019f6380 stage 2)" do
      # Regression pin: the new gate must not block the happy path. An
      # approved plan opens the gate for any actor.
      project = create_project()
      agent_id = Ecto.UUID.generate()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Has plan, agent moves it",
          status: "backlog",
          assignee_id: agent_id,
          assignee_type: "agent"
        })

      {:ok, _plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

      {:ok, result} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "status" => "in_progress"},
          %{agent_id: agent_id}
        )

      assert result.status == "in_progress"
    end

    test "task_update as agent to in_review from blocked on sponsor-only task → gate holds (task 019f6380 stage 3)" do
      # Stage 3 fence: extends stage 2's MCP-path coverage (which pinned
      # `backlog → in_progress`) to a second execution-phase target
      # (`in_review`) from a second non-execution source (`blocked`).
      # Together the two tests span both the "entering execution phase
      # for the first time" edge (backlog → in_progress) and the
      # "recovering from blocked into review" edge (blocked → in_review)
      # — both must be gated for agent MCP actors even on a
      # sponsor-only-no-agent task.
      #
      # Aside on the plan spec's `status: "done"` sketch — the gate can
      # never fire for target `"done"`: every source status that
      # `@valid_task_transitions` permits reaching done from is already
      # in `@execution_phase_statuses`, so
      # `require_approved_plan_for/3` short-circuits at the "already in
      # execution" clause before the plan check. `in_review` from
      # `blocked` exercises the equivalent semantic (agent-initiated
      # transition into an execution-phase target that would otherwise
      # qualify for sponsor-bypass) via a source/target pair that
      # actually reaches the predicate.
      project = create_project()
      sponsor = insert_user_for_sponsor()
      agent_id = Ecto.UUID.generate()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Sponsor-only, agent-initiated MCP blocked → in_review",
          status: "blocked",
          sponsor_user_id: sponsor.id
        })

      {:error, error} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "status" => "in_review"},
          %{agent_id: agent_id}
        )

      assert error.recoverable == true
      assert error.error =~ "Cannot transition to 'in_review'"
      assert error.error =~ "no approved plan"
      assert error.suggestion =~ ~r/plan_create|plan_approve/

      # Task did NOT transition.
      assert Tasks.get_task_record(task.id).status == "blocked"
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

      {:ok, %{tasks: results}} =
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

      {:ok, %{tasks: results}} =
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

      {:ok, %{tasks: results}} =
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

    # ── Auto-planning dispatch on task_create (post-PR #550 hotfix) ─────
    #
    # `TaskRouterWatcher.should_run?/1` only spawns a router for tasks
    # whose status is in ["planning", "in_progress", "in_review",
    # "deploying"]. `task_create` inserts at "backlog" by default, so
    # without an auto-transition a task with a planning-phase agent
    # assignee would silently stall in backlog — the planner never
    # dispatches. See `Tasks.maybe_start_planning_on_create/1`.

    test "task_create with planning-phase agent assignee auto-transitions to planning" do
      project = create_project()
      planner = create_agent()

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Auto-plan on create",
            "phase_assignees" => %{
              "planning" => %{
                "assignee_id" => planner.id,
                "assignee_type" => "agent"
              }
            }
          },
          %{}
        )

      # Response envelope reflects the post-transition status so callers
      # observing `result.status` see the planning state immediately (no
      # follow-up task_get needed).
      assert result.status == "planning"

      reloaded = Tasks.get_task_record(result.id)
      assert reloaded.status == "planning"

      # phase_assignees still intact — the transition doesn't re-derive
      # or clobber the assignee map.
      assert reloaded.phase_assignees["planning"]["assignee_id"] == planner.id
      assert reloaded.phase_assignees["planning"]["assignee_type"] == "agent"
    end

    test "task_create with flat agent assignee (auto-routed to planning) auto-transitions to planning" do
      # Flat `assignee_id + assignee_type` lifts into
      # `phase_assignees["planning"]` via `TaskAttrs.build_task_attrs/3`
      # (ADR 0044), so the same auto-plan hop must fire for the flat
      # shape too — otherwise MCP callers that use the compact form
      # would still stall in backlog.
      project = create_project()
      planner = create_agent()

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Flat assignee auto-plans",
            "assignee_id" => planner.id,
            "assignee_type" => "agent"
          },
          %{}
        )

      assert result.status == "planning"

      reloaded = Tasks.get_task_record(result.id)
      assert reloaded.status == "planning"
      assert reloaded.phase_assignees["planning"]["assignee_id"] == planner.id
    end

    test "task_create without any assignee stays at backlog" do
      # Boundary: no auto-transition when there's no planning-phase
      # assignee. The task sits at backlog waiting for a later
      # `task_update` to attach an assignee (or the operator to move it
      # via drag-and-drop). Locks the guardrail that the hotfix does
      # NOT change behaviour for assignee-less tasks.
      project = create_project()

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Unassigned"
          },
          %{}
        )

      assert result.status == "backlog"
      assert Tasks.get_task_record(result.id).status == "backlog"
    end

    test "task_create with only execution-phase assignee (no planning slot) stays at backlog" do
      # Boundary: `phase_assignees["execution"]` alone is not enough —
      # planning-phase assignee is the signal the hotfix keys on. This
      # is the shape a caller uses when they want to pre-assign the
      # execution phase but keep planning human-driven.
      project = create_project()
      executor = create_agent()

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Execution assignee only",
            "phase_assignees" => %{
              "execution" => %{
                "assignee_id" => executor.id,
                "assignee_type" => "agent"
              }
            }
          },
          %{}
        )

      assert result.status == "backlog"
      assert Tasks.get_task_record(result.id).status == "backlog"
    end

    test "task_create with planning-phase USER assignee stays at backlog" do
      # Only agent-typed planning assignees warrant an auto-transition
      # — a human planner doesn't need a router-driven dispatch, so we
      # leave the task in backlog for the human to move via the board.
      project = create_project()
      user = insert_user_for_sponsor()

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Human planning",
            "phase_assignees" => %{
              "planning" => %{
                "assignee_id" => user.id,
                "assignee_type" => "user"
              }
            }
          },
          %{}
        )

      assert result.status == "backlog"
      assert Tasks.get_task_record(result.id).status == "backlog"
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

      # Task 01a05877: the schema text must tell the caller that a flat
      # agent-typed assignee under the flag fans into all three phase
      # slots, that explicit phase_assignees win over the fan-out, and
      # that user-typed or missing assignees still need explicit
      # phase_assignees. Pin both the parameter description and the tool
      # description (the MCP transport forwards the latter).
      param_description = task_create.parameters.auto_approve_plan.description
      assert param_description =~ "fans that agent into all three phase slots"
      assert param_description =~ "explicit phase_assignees entries win"
      assert param_description =~ "still need explicit phase_assignees"

      assert task_create.description =~ "fans into all three phase slots"
      assert task_create.description =~ "explicit phase_assignees entries win"
      assert task_create.description =~ "still need explicit phase_assignees"
    end

    test "tool definitions state the update-mode fill on task_update (task 01a0589b stage 2)" do
      # Same pin pattern as the task_create schema test above: the
      # task_update description and its auto_approve_plan parameter
      # description must tell the caller that an agent-typed flat assignee
      # under the flag fills every ABSENT phase slot (judged against the
      # persisted slots overlaid with the call's routed slots), that
      # explicit entries win and present slots are never overwritten, and
      # that user-typed or missing flat assignees still need explicit
      # agent-typed phase_assignees.
      tools = ToolSurface.tool_definitions()
      task_update = Enum.find(tools, &(&1.name == "task_update"))

      assert Map.has_key?(task_update.parameters, :auto_approve_plan)
      assert task_update.parameters.auto_approve_plan.type == "boolean"

      param_description = task_update.parameters.auto_approve_plan.description
      assert param_description =~ "fills the absent phase slots"
      assert param_description =~ "never overwritten"
      assert param_description =~ "still need explicit agent-typed phase_assignees"

      assert task_update.description =~ "absent phase slots"
      assert task_update.description =~ "present slots are never overwritten"
      assert task_update.description =~ "still need explicit agent-typed phase_assignees"
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

      {:ok, %{tasks: results}} =
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
      {:ok, plan} = create_submittable_plan(%{task_id: task.id})
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

    test "task_create with flat agent assignee + auto_approve_plan: true fans into all three phase slots" do
      # Was the defect trap (task 01a05877): the flat pair auto-routed
      # into planning ONLY (per ADR 0044), so the auto-approve
      # precondition refused unconditionally — execution and review could
      # never resolve from a flat agent. The canonical builder now fans
      # the flat agent into every ABSENT slot on :create, and the
      # persisted row carries the full three-slot map the
      # TaskRouterWatcher needs for execution + review dispatch.
      project = create_project()
      agent = create_agent()

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Flat agent auto-approve",
            "auto_approve_plan" => true,
            "assignee_id" => agent.id,
            "assignee_type" => "agent"
          },
          %{}
        )

      assert result.auto_approve_plan == true

      reloaded = Tasks.get_task_record(result.id)
      assert reloaded.auto_approve_plan == true

      assert reloaded.phase_assignees == %{
               "planning" => %{"assignee_id" => agent.id, "assignee_type" => "agent"},
               "execution" => %{"assignee_id" => agent.id, "assignee_type" => "agent"},
               "review" => %{"assignee_id" => agent.id, "assignee_type" => "agent"}
             }
    end

    test "task_create with flat agent assignee and NO auto_approve_plan key routes planning-only (mutation probe)" do
      # Mutation probe — fails if the fan-out is made unconditional.
      # Without the flag the persisted map must stay the planning-only
      # ADR 0044 shape.
      project = create_project()
      agent = create_agent()

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "No flag, planning only",
            "assignee_id" => agent.id,
            "assignee_type" => "agent"
          },
          %{}
        )

      reloaded = Tasks.get_task_record(result.id)
      assert reloaded.auto_approve_plan == false

      assert reloaded.phase_assignees == %{
               "planning" => %{"assignee_id" => agent.id, "assignee_type" => "agent"}
             }
    end

    test "task_create flat agent + flag + explicit planning keeps the explicit planner and fans execution/review" do
      project = create_project()
      planner = create_agent(%{slug: "planner-#{System.unique_integer([:positive])}"})
      flat_agent = create_agent()

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Explicit planner, fanned exec/review",
            "auto_approve_plan" => true,
            "assignee_id" => flat_agent.id,
            "assignee_type" => "agent",
            "phase_assignees" => %{
              "planning" => %{"assignee_id" => planner.id, "assignee_type" => "agent"}
            }
          },
          %{}
        )

      reloaded = Tasks.get_task_record(result.id)

      assert reloaded.phase_assignees == %{
               "planning" => %{"assignee_id" => planner.id, "assignee_type" => "agent"},
               "execution" => %{"assignee_id" => flat_agent.id, "assignee_type" => "agent"},
               "review" => %{"assignee_id" => flat_agent.id, "assignee_type" => "agent"}
             }
    end

    test "task_create flat agent + flag + complete explicit phase_assignees wins verbatim" do
      # Every slot explicitly supplied — the explicit map wins verbatim,
      # no slot is overwritten by the flat agent.
      project = create_project()
      planner = create_agent(%{slug: "planner-#{System.unique_integer([:positive])}"})
      executor = create_agent(%{slug: "executor-#{System.unique_integer([:positive])}"})
      reviewer = create_agent(%{slug: "reviewer-#{System.unique_integer([:positive])}"})
      flat_agent = create_agent()

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Complete explicit map wins",
            "auto_approve_plan" => true,
            "assignee_id" => flat_agent.id,
            "assignee_type" => "agent",
            "phase_assignees" => %{
              "planning" => %{"assignee_id" => planner.id, "assignee_type" => "agent"},
              "execution" => %{"assignee_id" => executor.id, "assignee_type" => "agent"},
              "review" => %{"assignee_id" => reviewer.id, "assignee_type" => "agent"}
            }
          },
          %{}
        )

      reloaded = Tasks.get_task_record(result.id)

      assert reloaded.phase_assignees == %{
               "planning" => %{"assignee_id" => planner.id, "assignee_type" => "agent"},
               "execution" => %{"assignee_id" => executor.id, "assignee_type" => "agent"},
               "review" => %{"assignee_id" => reviewer.id, "assignee_type" => "agent"}
             }
    end

    test "task_create with flat USER assignee + auto_approve_plan: true refuses and writes nothing" do
      # DO-NOT-REGRESS guard: the fan-out is agent-typed only. A user
      # flat pair never satisfies the precondition, and nothing is
      # persisted when it fires.
      project = create_project()
      user = insert_user_for_sponsor()

      assert {:error, envelope} =
               ToolSurface.execute(
                 "task_create",
                 %{
                   "project_id" => project.id,
                   "title" => "User flat auto-approve",
                   "auto_approve_plan" => true,
                   "assignee_id" => user.id,
                   "assignee_type" => "user"
                 },
                 %{}
               )

      assert envelope.code == :auto_approve_precondition_missing
      assert envelope.missing_phases == ["execution", "review"]
      assert envelope.recoverable == true

      # DB unchanged — precondition fires before `Tasks.create_task/1`.
      assert Tasks.list_tasks(project_id: project.id) == []
    end

    test "task_create with flat agent and assignee_type ABSENT + flag fans into all three agent-typed slots" do
      # Absent assignee_type means agent (mirrors
      # `build_phase_entry_from_flat/1`), so the fan-out fires the same
      # as the explicit "agent" shape.
      project = create_project()
      agent = create_agent()

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Typeless flat agent fans out",
            "auto_approve_plan" => true,
            "assignee_id" => agent.id
          },
          %{}
        )

      reloaded = Tasks.get_task_record(result.id)

      assert reloaded.phase_assignees == %{
               "planning" => %{"assignee_id" => agent.id, "assignee_type" => "agent"},
               "execution" => %{"assignee_id" => agent.id, "assignee_type" => "agent"},
               "review" => %{"assignee_id" => agent.id, "assignee_type" => "agent"}
             }
    end

    test "task_update with flat agent + auto_approve_plan: true fans into every absent phase slot (task 01a0589b stage 2)" do
      # ADR 0044 §5 (task 01a0589b): the :update fill runs on the task's
      # persisted slots overlaid by this call's routed slots, so a
      # slotless probe fans into all three slots. The old pin asserted a
      # refusal ("no fan-out on update"); the assertion moving from a
      # refusal to a literal persisted map is the intended behavior
      # change, not a weakened test.
      project = create_project()
      agent = create_agent()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Slotless task"})

      assert {:ok, _updated} =
               ToolSurface.execute(
                 "task_update",
                 %{
                   "task_id" => task.id,
                   "auto_approve_plan" => true,
                   "assignee_id" => agent.id,
                   "assignee_type" => "agent"
                 },
                 %{}
               )

      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.auto_approve_plan == true

      assert reloaded.phase_assignees == %{
               "planning" => %{"assignee_id" => agent.id, "assignee_type" => "agent"},
               "execution" => %{"assignee_id" => agent.id, "assignee_type" => "agent"},
               "review" => %{"assignee_id" => agent.id, "assignee_type" => "agent"}
             }
    end

    test "task_update flat agent + flag fills only absent slots — persisted execution/review survive (no-clobber, task 01a0589b stage 2)" do
      # Mutation probe for the fill key: a fill keyed off the routed map
      # alone would overlay the persisted slots through
      # set_phase_assignees/2's per-slot merge and clobber execution and
      # review to the flat agent. Keyed off the merged map (persisted
      # slots overlaid by this call's routed slots), the only absent slot
      # is planning — the one this call routes.
      project = create_project()
      flat_agent = create_agent(%{slug: "flat-#{System.unique_integer([:positive])}"})
      bound = create_agent(%{slug: "bound-#{System.unique_integer([:positive])}"})

      {:ok, probe} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Bound probe",
          phase_assignees: %{
            "execution" => %{"assignee_id" => bound.id, "assignee_type" => "agent"},
            "review" => %{"assignee_id" => bound.id, "assignee_type" => "agent"}
          }
        })

      assert {:ok, _updated} =
               ToolSurface.execute(
                 "task_update",
                 %{
                   "task_id" => probe.id,
                   "auto_approve_plan" => true,
                   "assignee_id" => flat_agent.id,
                   "assignee_type" => "agent"
                 },
                 %{}
               )

      reloaded = Tasks.get_task_record(probe.id)
      assert reloaded.auto_approve_plan == true

      assert reloaded.phase_assignees == %{
               "planning" => %{"assignee_id" => flat_agent.id, "assignee_type" => "agent"},
               "execution" => %{"assignee_id" => bound.id, "assignee_type" => "agent"},
               "review" => %{"assignee_id" => bound.id, "assignee_type" => "agent"}
             }
    end

    test "task_update with flat USER assignee + auto_approve_plan: true refuses, echoes submitted_args, no corrected_args (task 01a0589b stage 2)" do
      # The fill is agent-typed only. A user flat pair routes to the
      # current-phase slot but never satisfies the precondition, so the
      # refusal survives for unrepairable shapes — and
      # auto_approve_corrected_args/3 returns nil (the repair is not
      # mechanical), so :corrected_args is absent from the envelope.
      # Nothing is persisted when the check fires.
      project = create_project()
      user = insert_user_for_sponsor()
      planner = create_agent(%{slug: "planner-#{System.unique_integer([:positive])}"})

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "User flat task",
          phase_assignees: %{
            "planning" => %{"assignee_id" => planner.id, "assignee_type" => "agent"}
          }
        })

      assert {:error, envelope} =
               ToolSurface.execute(
                 "task_update",
                 %{
                   "task_id" => task.id,
                   "auto_approve_plan" => true,
                   "assignee_id" => user.id,
                   "assignee_type" => "user"
                 },
                 %{}
               )

      assert envelope.code == :auto_approve_precondition_missing
      assert envelope.missing_phases == ["execution", "review"]
      assert envelope.recoverable == true

      # submitted_args echoes the call verbatim.
      assert envelope.submitted_args == %{
               "task_id" => task.id,
               "auto_approve_plan" => true,
               "assignee_id" => user.id,
               "assignee_type" => "user"
             }

      # The repair is not mechanical for a user-typed flat pair.
      refute Map.has_key?(envelope, :corrected_args)

      # Task unchanged — the precondition fires before any writer ran.
      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.auto_approve_plan == false

      assert reloaded.phase_assignees == %{
               "planning" => %{"assignee_id" => planner.id, "assignee_type" => "agent"}
             }
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

    # ── Recoverable refusals echo submitted_args (task 01a05877 stage 2) ──
    #
    # Every recoverable refusal envelope from task_create / task_update
    # carries the arguments as received at the tool boundary (post-defaults
    # for task_create) so a retry is patch-one-field instead of
    # rebuild-everything. The echo lives in the RESPONSE ENVELOPE ONLY —
    # never a log line (the args carry user content; docs/decisions/0005).

    test "task_create user-typed flat assignee + flag refusal echoes submitted_args, no corrected_args" do
      project = create_project()
      user = insert_user_for_sponsor()

      assert {:error, envelope} =
               ToolSurface.execute(
                 "task_create",
                 %{
                   "project_id" => project.id,
                   "title" => "Echo probe user flat",
                   "auto_approve_plan" => true,
                   "assignee_id" => user.id,
                   "assignee_type" => "user"
                 },
                 %{}
               )

      assert envelope.code == :auto_approve_precondition_missing

      # Verbatim echo of the submitted args, post-Map.put_new defaults
      # (status/priority drop in when the keys are absent).
      assert envelope.submitted_args == %{
               "project_id" => project.id,
               "title" => "Echo probe user flat",
               "auto_approve_plan" => true,
               "assignee_id" => user.id,
               "assignee_type" => "user",
               "status" => "backlog",
               "priority" => "medium"
             }

      # A user-typed flat assignee cannot be repaired mechanically — the
      # caller must choose an agent id.
      refute Map.has_key?(envelope, :corrected_args)
    end

    test "task_create without project_id: changeset refusal echoes submitted_args (patch-one-field retry)" do
      assignee_id = Ecto.UUID.generate()

      assert {:error, envelope} =
               ToolSurface.execute(
                 "task_create",
                 %{
                   "title" => "No project echo",
                   "assignee_id" => assignee_id,
                   "assignee_type" => "agent"
                 },
                 %{}
               )

      assert envelope.recoverable == true
      assert envelope.error =~ "Failed to create task"

      # The absent project_id stays absent in the echo, and the
      # Map.put_new defaults are part of it — the retry is literally
      # "add project_id" to this map.
      assert envelope.submitted_args == %{
               "title" => "No project echo",
               "assignee_id" => assignee_id,
               "assignee_type" => "agent",
               "status" => "backlog",
               "priority" => "medium",
               "auto_approve_plan" => false
             }

      refute Map.has_key?(envelope.submitted_args, "project_id")
    end

    test "task_update flat agent with an UNRESOLVABLE id + flag refuses with no corrected_args (fill cannot repair, task 01a0589b stage 2)" do
      # Rewritten (task 01a0589b stage 2): the old pin used a slotless
      # task + resolvable flat agent and expected the refusal to carry a
      # corrected_args completion. That shape now completes in-call (the
      # :update fill runs before the precondition), so the mechanical
      # repair is dormant-by-success on :update. What still refuses with
      # no corrected_args is an id that does not resolve: the fill places
      # it into the absent slots, the slots are present-but-unresolvable,
      # and auto_approve_corrected_args/3 never offers a repair for a
      # failing slot that is present in the merged map.
      project = create_project()
      ghost_id = Ecto.UUID.generate()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Slotless echo"})

      assert {:error, envelope} =
               ToolSurface.execute(
                 "task_update",
                 %{
                   "task_id" => task.id,
                   "auto_approve_plan" => true,
                   "assignee_id" => ghost_id,
                   "assignee_type" => "agent"
                 },
                 %{}
               )

      assert envelope.code == :auto_approve_precondition_missing
      assert envelope.missing_phases == ["execution", "review"]

      assert envelope.submitted_args == %{
               "task_id" => task.id,
               "auto_approve_plan" => true,
               "assignee_id" => ghost_id,
               "assignee_type" => "agent"
             }

      refute Map.has_key?(envelope, :corrected_args)

      # DB unchanged — the precondition fires before any writer ran.
      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.auto_approve_plan == false
      assert reloaded.phase_assignees == %{}
    end

    test "task_update with a present-but-user-typed execution slot: no corrected_args (fill cannot repair)" do
      project = create_project()
      agent = create_agent()
      user = insert_user_for_sponsor()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "User executor echo",
          status: "planning"
        })

      {:ok, task} =
        Tasks.set_phase_assignees(task, %{
          "execution" => %{"assignee_id" => user.id, "assignee_type" => "user"}
        })

      assert {:error, envelope} =
               ToolSurface.execute(
                 "task_update",
                 %{
                   "task_id" => task.id,
                   "auto_approve_plan" => true,
                   "assignee_id" => agent.id,
                   "assignee_type" => "agent"
                 },
                 %{}
               )

      assert envelope.code == :auto_approve_precondition_missing

      # Rewritten expectation (task 01a0589b stage 2): the :update fill
      # completes the ABSENT review slot from the agent-typed flat pair,
      # so only the failing execution slot — present-but-user-typed in
      # the merged map the precondition read — stays missing. Completion
      # cannot repair it, so no corrected_args is offered.
      assert envelope.missing_phases == ["execution"]

      refute Map.has_key?(envelope, :corrected_args)

      assert envelope.submitted_args == %{
               "task_id" => task.id,
               "auto_approve_plan" => true,
               "assignee_id" => agent.id,
               "assignee_type" => "agent"
             }
    end

    test "task_create invalid_phase_keys refusal echoes submitted_args" do
      assert {:error, envelope} =
               ToolSurface.execute(
                 "task_create",
                 %{
                   "project_id" => "unused-the-build-fails-first",
                   "title" => "Bad phase keys",
                   "phase_assignees" => %{"shipping" => %{}}
                 },
                 %{}
               )

      assert envelope.error =~ "Invalid phase_assignees keys"
      assert envelope.recoverable == true

      assert envelope.submitted_args == %{
               "project_id" => "unused-the-build-fails-first",
               "title" => "Bad phase keys",
               "phase_assignees" => %{"shipping" => %{}},
               "status" => "backlog",
               "priority" => "medium",
               "auto_approve_plan" => false
             }
    end

    test "refusal echoes never reach a log line (response envelope only)" do
      project = create_project()
      unique = System.unique_integer([:positive])
      title = "log-silence-probe-#{unique}"

      {result, captured} =
        ExUnit.CaptureLog.with_log([level: :debug], fn ->
          ToolSurface.execute(
            "task_create",
            %{
              "project_id" => project.id,
              "title" => title,
              "auto_approve_plan" => true,
              "assignee_id" => "user-log-silence-#{unique}",
              "assignee_type" => "user"
            },
            %{}
          )
        end)

      assert {:error, envelope} = result
      assert envelope.code == :auto_approve_precondition_missing
      assert envelope.submitted_args["title"] == title

      # The echo must never reach a log line — neither the user-content
      # title nor any submitted_args payload fragment.
      refute captured =~ title
      refute captured =~ "user-log-silence-#{unique}"
      refute captured =~ "submitted_args"
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

      {:ok, plan} = create_submittable_plan(%{task_id: task.id})

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

    # task 01a08c1e stage 2: the named plan_auto_approve param is the
    # only way the policy reaches config through this tool.
    test "project_update writes plan_auto_approve and preserves other config keys" do
      project = create_project(%{name: "Policy project"})

      {:ok, project} =
        Tasks.update_project(project, %{config: %{"brand_decision" => "advisory"}})

      {:ok, result} =
        ToolSurface.execute(
          "project_update",
          %{
            "project_id" => project.id,
            "plan_auto_approve" => %{"enabled" => true, "max_stages" => 5}
          },
          %{}
        )

      assert result.plan_auto_approve == %{"enabled" => true, "max_stages" => 5}

      reloaded = Tasks.get_project(project.id)
      assert reloaded.config["plan_auto_approve"] == %{"enabled" => true, "max_stages" => 5}
      assert reloaded.config["brand_decision"] == "advisory"
    end

    test "project_update refuses a malformed plan_auto_approve and writes nothing" do
      project = create_project(%{name: "Malformed policy project"})

      {:error, error} =
        ToolSurface.execute(
          "project_update",
          %{
            "project_id" => project.id,
            "name" => "Renamed alongside a bad policy",
            "plan_auto_approve" => %{"enabled" => true, "max_stages" => "five"}
          },
          %{}
        )

      assert error.recoverable == true
      assert error.error =~ "max_stages must be a positive integer"

      reloaded = Tasks.get_project(project.id)
      assert reloaded.name == "Malformed policy project"
      refute Map.has_key?(reloaded.config || %{}, "plan_auto_approve")
    end

    # task 01a08c1e stage 3: dispatch_paused is a named boolean param.
    test "project_update pauses and un-pauses dispatch for a project" do
      project = create_project(%{name: "Pausable project"})
      assert project.dispatch_paused == false

      {:ok, result} =
        ToolSurface.execute(
          "project_update",
          %{"project_id" => project.id, "dispatch_paused" => true},
          %{}
        )

      assert result.dispatch_paused == true
      assert Tasks.get_project(project.id).dispatch_paused == true

      {:ok, result} =
        ToolSurface.execute(
          "project_update",
          %{"project_id" => project.id, "dispatch_paused" => false},
          %{}
        )

      assert result.dispatch_paused == false
      assert Tasks.get_project(project.id).dispatch_paused == false
    end

    test "task_create into a paused project with no assignee succeeds" do
      project = create_project(%{name: "Paused intake", dispatch_paused: true})

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{"project_id" => project.id, "title" => "Queued for later"},
          %{}
        )

      task = Repo.get!(Platform.Tasks.Task, result.id)
      assert task.project_id == project.id
      assert is_nil(task.assignee_id)
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

    # ── e2e host collision guard (task 01a006d1 stage 3) ─────────────────

    test "plan_create refuses a plan whose stage name would silently host the e2e cases" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Collision task"})

      {:error, env} =
        ToolSurface.execute(
          "plan_create",
          %{
            "task_id" => task.id,
            "stages" => [
              %{
                "name" => "Widen task_plan_review output class",
                "description" => "Widen it",
                "position" => 1,
                "validations" => [%{"kind" => "test_pass"}, e2e_case("widened plan")]
              }
            ]
          },
          %{}
        )

      # The envelope must NAME the stage and the substring that matched — the
      # author cannot see "review" inside "task_plan_review" unaided.
      assert env.error =~ "Widen task_plan_review output class"
      assert env.error =~ "review"
      assert env.recoverable == true

      assert env.suggestion =~ "rename"
      assert env.suggestion =~ "e2e_host"

      # PERSISTENCE CONTROL — same call. Refusing while leaving a draft plan
      # behind would recreate the exact lockout this guard exists to prevent
      # (a live draft blocks the retry), and only this assertion can see it.
      assert Tasks.latest_plan(task.id) == nil
    end

    # DIRECTION CONTROL — fails outright if the guard rejects everything.
    #
    # It is ALSO the ordering pin (stage 4 probe): move the detector call after
    # `route_e2e_behavior_validations/1` and this test detonates, because the
    # SYNTHESIZED "Task-level review" stage carries the trigger. The rejection
    # test above does NOT pin the ordering — routing relocates the e2e cases
    # rather than deleting them, so the refusal still fires post-rewrite.
    test "plan_create still lifts e2e cases onto a synthesized task-level review stage" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Clean task"})

      {:ok, plan} =
        ToolSurface.execute(
          "plan_create",
          %{
            "task_id" => task.id,
            "stages" => [
              %{
                "name" => "Add the guard",
                "description" => "Add it",
                "position" => 1,
                "validations" => [%{"kind" => "test_pass"}, e2e_case("guard fires")]
              },
              %{
                "name" => "Wire the envelope",
                "description" => "Wire it",
                "position" => 2,
                "validations" => [%{"kind" => "lint_pass"}, e2e_case("envelope explains")]
              }
            ]
          },
          %{}
        )

      names = Enum.map(plan.stages, & &1.name)
      assert List.last(names) == "Task-level review"
      assert Enum.take(names, 2) == ["Add the guard", "Wire the envelope"]

      host = List.last(plan.stages)
      assert Enum.count(host.validations, &(&1.kind == "e2e_behavior")) == 2

      # Positions of the authored stages are untouched.
      assert Enum.map(Enum.take(plan.stages, 2), & &1.position) == [1, 2]

      # And no e2e case was left behind on an authored stage.
      refute Enum.any?(Enum.take(plan.stages, 2), fn s ->
               Enum.any?(s.validations, &(&1.kind == "e2e_behavior"))
             end)
    end

    # Task 01a0588e. The stage the engine synthesized above is marked
    # STRUCTURALLY, not by its name or its description — both are template
    # copy, and a classifier keyed to either fails open on a reword.
    test "plan_create marks only the synthesized stage with origin=synthesized" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Origin task"})

      {:ok, plan} =
        ToolSurface.execute(
          "plan_create",
          %{
            "task_id" => task.id,
            "stages" => [
              %{
                "name" => "Add the guard",
                "description" => "Add it",
                "position" => 1,
                "validations" => [%{"kind" => "test_pass"}, e2e_case("guard fires")]
              },
              %{
                "name" => "Wire the envelope",
                "description" => "Wire it",
                "position" => 2,
                "validations" => [%{"kind" => "lint_pass"}]
              }
            ]
          },
          %{}
        )

      # Read the persisted rows: `origin` is a server-side marker and is not
      # part of the serialized plan the tool hands back.
      assert Enum.map(Tasks.list_stages(plan.id), & &1.origin) ==
               ~w(authored authored synthesized)

      assert Tasks.authored_stage_count(plan.id) == 2
    end

    # A planner handing us `"origin": "synthesized"` must not be able to
    # disguise its own stage as the engine's — `origin` is stripped from raw
    # planner input before the engine's rewrite runs.
    test "plan_create does not honour a planner-supplied origin" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Forged origin"})

      {:ok, plan} =
        ToolSurface.execute(
          "plan_create",
          %{
            "task_id" => task.id,
            "stages" => [
              %{
                "name" => "Add the guard",
                "description" => "Add it",
                "position" => 1,
                "origin" => "synthesized",
                "validations" => [%{"kind" => "test_pass"}]
              }
            ]
          },
          %{}
        )

      assert Enum.map(Tasks.list_stages(plan.id), & &1.origin) == ~w(authored)
      assert Tasks.authored_stage_count(plan.id) == 1
    end

    test "plan_update does not honour a planner-supplied origin" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Forged origin update"})

      {:ok, plan} =
        ToolSurface.execute(
          "plan_create",
          %{
            "task_id" => task.id,
            "stages" => [
              %{"name" => "First", "description" => "d", "position" => 1}
            ]
          },
          %{}
        )

      {:ok, updated} =
        ToolSurface.execute(
          "plan_update",
          %{
            "plan_id" => plan.id,
            "stages" => [
              %{
                "name" => "First",
                "description" => "d",
                "position" => 1,
                "origin" => "synthesized"
              }
            ]
          },
          %{}
        )

      assert updated.id == plan.id
      assert Enum.map(Tasks.list_stages(plan.id), & &1.origin) == ~w(authored)
      assert Tasks.authored_stage_count(plan.id) == 1
    end

    test "plan_create accepts a trigger-named stage that explicitly opts in as e2e_host" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Opt-in task"})

      {:ok, plan} =
        ToolSurface.execute(
          "plan_create",
          %{
            "task_id" => task.id,
            "stages" => [
              %{
                "name" => "Add the guard",
                "description" => "Add it",
                "position" => 1,
                "validations" => [%{"kind" => "test_pass"}]
              },
              %{
                "name" => "Cross-surface validation sweep",
                "description" => "Sweep it",
                "position" => 2,
                "e2e_host" => true,
                "validations" => [e2e_case("sweep runs")]
              }
            ]
          },
          %{}
        )

      names = Enum.map(plan.stages, & &1.name)
      assert names == ["Add the guard", "Cross-surface validation sweep"]
      refute "Task-level review" in names

      host = Enum.find(plan.stages, &(&1.name == "Cross-surface validation sweep"))
      assert Enum.count(host.validations, &(&1.kind == "e2e_behavior")) == 1
    end

    # ── unnamed manual_approval gate guard (task 01a00b91 stage 3) ────────

    test "plan_create accepts a manual_approval that names its UI surface, and persists it unchanged" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Named gate task"})

      {:ok, plan} =
        ToolSurface.execute(
          "plan_create",
          %{
            "task_id" => task.id,
            "stages" => [
              %{
                "name" => "Surface the stage timeline",
                "description" => "Render it",
                "position" => 1,
                "validations" => [
                  %{"kind" => "test_pass"},
                  %{
                    "kind" => "manual_approval",
                    "evaluation_payload" => %{
                      "ui_surface" => "the task detail page's stage timeline at 375px"
                    }
                  }
                ]
              }
            ]
          },
          %{}
        )

      assert [stage] = plan.stages

      gate = Enum.find(stage.validations, &(&1.kind == "manual_approval"))
      assert gate, "the named manual_approval must survive the guard"

      # The guard READS the payload; it must not rewrite or strip it. Asserting
      # only `{:ok, _}` would pass against an implementation that admitted the
      # plan by deleting the field it checked.
      assert gate.evaluation_payload["ui_surface"] ==
               "the task detail page's stage timeline at 375px"
    end

    test "plan_create refuses a manual_approval that names no UI surface, and writes nothing" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Unnamed gate task"})

      {:error, env} =
        ToolSurface.execute(
          "plan_create",
          %{
            "task_id" => task.id,
            "stages" => [
              %{
                "name" => "Add the retry backoff",
                "description" => "Add it",
                "position" => 1,
                "validations" => [%{"kind" => "test_pass"}]
              },
              %{
                "name" => "Confirm the backoff numbers",
                "description" => "Show the human the test run",
                "position" => 2,
                "validations" => [%{"kind" => "manual_approval"}]
              }
            ]
          },
          %{}
        )

      # The envelope must NAME the offending stage and position — "a
      # manual_approval is unnamed" is unactionable in a six-stage plan.
      assert env.error =~ "Confirm the backoff numbers"
      assert env.error =~ "Stage 2"
      assert env.recoverable == true

      # And it must name BOTH exits. A guard that only says "add the field"
      # teaches the planner to name a surface it does not have, which is the
      # padding this task exists to remove.
      assert env.suggestion =~ "ui_surface"
      assert env.suggestion =~ "evaluation_payload"
      assert env.suggestion =~ "DROP the"

      # PERSISTENCE CONTROL — same call. The error envelope reads IDENTICALLY
      # whether or not a draft row was left behind, so this is the only
      # assertion that can see the lockout regression: a live draft blocks the
      # author's own retry and `plan_get` resolves approved plans only, leaving
      # them unable to read, fix, or re-submit.
      assert Tasks.latest_plan(task.id) == nil
    end

    # DIRECTION CONTROL — an implementation that refuses every plan passes the
    # rejection test above and must fail here.
    test "plan_create accepts a plan with no manual_approval at all" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "No gate task"})

      {:ok, plan} =
        ToolSurface.execute(
          "plan_create",
          %{
            "task_id" => task.id,
            "stages" => [
              %{
                "name" => "Add the retry backoff",
                "description" => "Add it",
                "position" => 1,
                "validations" => [%{"kind" => "test_pass"}, %{"kind" => "lint_pass"}]
              }
            ]
          },
          %{}
        )

      assert [stage] = plan.stages
      assert stage.name == "Add the retry backoff"
      assert Enum.map(stage.validations, & &1.kind) == ["test_pass", "lint_pass"]
      refute Tasks.latest_plan(task.id) == nil
    end

    # COEXISTENCE — the two pre-transaction guards must not interfere. A named
    # manual_approval passes its guard, and the e2e cases still route to the
    # synthesised task-level host stage exactly as before.
    test "plan_create routes e2e cases to the synthesized host stage alongside a named manual_approval" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Coexistence task"})

      {:ok, plan} =
        ToolSurface.execute(
          "plan_create",
          %{
            "task_id" => task.id,
            "stages" => [
              %{
                "name" => "Add the guard",
                "description" => "Add it",
                "position" => 1,
                "validations" => [%{"kind" => "test_pass"}, e2e_case("guard fires")]
              },
              %{
                "name" => "Surface the refusal banner",
                "description" => "Render it",
                "position" => 2,
                "validations" => [
                  %{
                    "kind" => "manual_approval",
                    "evaluation_payload" => %{"ui_surface" => "the plan refusal banner at 375px"}
                  },
                  e2e_case("banner explains")
                ]
              }
            ]
          },
          %{}
        )

      names = Enum.map(plan.stages, & &1.name)
      assert List.last(names) == "Task-level review"

      host = List.last(plan.stages)
      assert Enum.count(host.validations, &(&1.kind == "e2e_behavior")) == 2

      # The manual_approval stays put on its authored stage — routing lifts e2e
      # cases only, and the gate's payload is untouched.
      banner = Enum.find(plan.stages, &(&1.name == "Surface the refusal banner"))
      assert Enum.map(banner.validations, & &1.kind) == ["manual_approval"]

      assert hd(banner.validations).evaluation_payload["ui_surface"] ==
               "the plan refusal banner at 375px"
    end

    # VACUOUS-TEST FINDING (019fa609 stage 4). This asserted only
    # `recoverable == true` against execute/3. After plan_create's own task_id
    # check was deleted it kept passing — Tasks.create_plan(%{task_id: nil})
    # fails its changeset and the handler wraps that as
    # "Failed to create plan: ...", also recoverable — so the test stayed green
    # while testing a completely different refusal. Re-pointed at dispatch/3
    # and given a `code` assertion so it can actually fail.
    test "plan_create without task_id returns error" do
      {:error, error} =
        ToolArguments.dispatch("plan_create", %{"stages" => []}, %{})

      assert error.recoverable == true
      assert error.code == :missing_task_id
      assert error.error =~ "task_id is required"
    end

    # ADR-0046 member 9 stage 3 — `responsibility` is gone from the MCP plan
    # surface. Task 019f5d47 stage 2 had made it round-trip through
    # plan_create → serialize_plan; that mechanism is retired (member 7's
    # pre-plan design step delivers designer involvement instead), so the
    # writer and the wire-level read are both deleted.
    #
    # BEHAVIOUR DECISION: a stage map still carrying `"responsibility"` is
    # SILENTLY IGNORED, not rejected. An MCP client's `tools/list` catalogue is
    # cached per session, so a planner runtime spawned before this deploy would
    # hard-fail every plan_create if the key were rejected. The failure mode of
    # tolerance is "field dropped" — which is the desired end state.
    test "plan_create ignores a stale responsibility key: the field is neither persisted nor returned" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Responsibility task"})

      {:ok, result} =
        ToolSurface.execute(
          "plan_create",
          %{
            "task_id" => task.id,
            "stages" => [
              %{
                "name" => "Design direction",
                "position" => 1,
                "responsibility" => "designer",
                # Names its surface — task 01a00b91 stage 3 refuses a
                # manual_approval that does not, and this test is about the
                # `responsibility` key, not the gate rule.
                "validations" => [
                  %{
                    "kind" => "manual_approval",
                    "evaluation_payload" => %{"ui_surface" => "the direction board at 375px"}
                  }
                ]
              }
            ]
          },
          %{}
        )

      assert [stage] = result.stages

      # POSITIVE CONTROL — tolerance, not rejection. The call succeeded, the
      # stage was created, and the rest of the payload survived intact. Without
      # this the refutes below would also hold for a plan_create that rejected
      # the unknown key outright, which is the alternative this stage declined.
      assert stage.name == "Design direction"
      assert stage.position == 1
      assert [%{kind: "manual_approval"}] = stage.validations

      # FIX DETECTOR (read side). Restoring `serialize_stage/1`'s
      # `responsibility:` line detonates here.
      refute Map.has_key?(stage, :responsibility)

      # FIX DETECTOR (write side). The read-side refute alone passes against a
      # plan_create that still WRITES the column and merely stops echoing it,
      # so check the persisted row too — that is the assertion that makes this
      # "no new row can acquire a non-null responsibility" rather than "the
      # wire response got quieter".
      #
      # Stage 3 wrote this as `assert persisted.responsibility == nil`, which
      # was the strongest available form while the column existed. Stage 4
      # dropped the column, so that access is now a KeyError and the claim is
      # restated structurally: the persisted struct has no such key to hold a
      # value in. Restoring the schema field AND the writer detonates here;
      # restoring the schema field alone detonates in
      # `Platform.Tasks.StageTest`.
      persisted = Platform.Repo.get!(Platform.Tasks.Stage, stage.id)
      assert persisted.name == "Design direction"
      refute Map.has_key?(persisted, :responsibility)
    end

    test "plan_create schema no longer documents responsibility but still documents the rest of the stage contract" do
      tools = ToolSurface.tool_definitions()
      plan_create = Enum.find(tools, &(&1.name == "plan_create"))
      assert plan_create, "plan_create tool must be registered"

      description = plan_create.parameters.stages.description

      # GUARD.
      refute description =~ "responsibility"

      # POSITIVE CONTROL — the surrounding contract is byte-preserved. A botched
      # string edit (or an emptied description) would satisfy the refute alone.
      assert description =~ "e2e_behavior"
      assert description =~ "evaluation_payload"
      assert description =~ "setup/actions/expected"
      assert description =~ "Do NOT include a deploy stage"
      # Task 01a006d1 stage 3 widened this shape with the optional per-stage
      # `e2e_host` boolean; the rest of the tuple is still byte-preserved.
      assert description =~ "{name, description, position, e2e_host?, validations:"

      # The e2e host rule must be READABLE by the planner that has to obey it —
      # a refusal whose rule the caller cannot see in the tool description is a
      # trap, not a guard.
      assert description =~ "e2e_host"
      assert description =~ "REFUSED"
      assert description =~ "\"review\" or \"validation\""

      # Task 01a00b91 stage 3 — same readability requirement for the
      # manual_approval rule: a planner must be able to learn the requirement
      # BEFORE tripping it, and must read both exits, not just the field.
      assert description =~ "ui_surface"
      assert description =~ "here is the UI, does it fit the brief"
      assert description =~ "drop the gate"

      # `evaluation` is NOT a trigger (stage 1's verified finding); the
      # description must not claim otherwise.
      refute description =~ "\"evaluation\""
    end

    test "plan_get returns current approved plan" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Plan task"})
      {:ok, plan} = create_submittable_plan(%{task_id: task.id})
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
      {:ok, plan} = create_submittable_plan(%{task_id: task.id})

      {:ok, result} =
        ToolSurface.execute("plan_submit", %{"plan_id" => plan.id}, %{})

      assert result.status == "pending_review"
    end

    test "plan_submit on non-draft plan returns error" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Submit task"})
      {:ok, plan} = create_submittable_plan(%{task_id: task.id})
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

    # ── auto-approve invariant (task 01a05b32 stage 3) ──────────────────
    #
    # plan_reject and plan_update gave planners two new ways to rewrite a
    # draft, but NOTHING in the approval path moved: tasks.ex's private
    # `auto_approve_precondition/2` still demands a non-empty plan plus
    # agent-typed execution AND review phase assignees, and a task lacking
    # them still lands in pending_review for a human. Pinned end-to-end
    # through the MCP `plan_submit` tool — the surface a planner actually
    # calls — so tool + context tail are covered in one shot. The fixtures
    # build via Tasks.create_task directly (as the architecture-gate tests
    # do): the create-time hard-reject lives in TaskAttrs, the runtime
    # skip under test lives in tasks.ex.

    defp auto_approve_task(overrides \\ %{}) do
      project = create_project()

      {:ok, task} =
        Tasks.create_task(
          Map.merge(
            %{
              project_id: project.id,
              title: "Auto-approve invariant #{System.unique_integer([:positive])}",
              status: "planning",
              auto_approve_plan: true,
              phase_assignees: %{
                "execution" => %{
                  "assignee_id" => Ecto.UUID.generate(),
                  "assignee_type" => "agent"
                },
                "review" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
              }
            },
            overrides
          )
        )

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, _stage} = Tasks.create_stage(%{plan_id: plan.id, name: "S1", position: 1})
      {task, plan}
    end

    test "plan_submit auto-approves with the flag plus agent execution and review assignees" do
      {task, plan} = auto_approve_task()

      {:ok, result} = ToolSurface.execute("plan_submit", %{"plan_id" => plan.id}, %{})
      assert result.status == "approved"

      reloaded = Tasks.get_plan(plan.id)
      assert reloaded.status == "approved"
      assert reloaded.auto_approved_at != nil

      # Approval moved the planning task to in_progress — the executor
      # dispatch path opened, exactly as before stages 1–2.
      assert Tasks.get_task_record(task.id).status == "in_progress"
    end

    test "plan_submit stays pending_review when the review phase assignee is missing" do
      {task, plan} =
        auto_approve_task(%{
          phase_assignees: %{
            "execution" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
          }
        })

      {:ok, result} = ToolSurface.execute("plan_submit", %{"plan_id" => plan.id}, %{})
      assert result.status == "pending_review"

      reloaded = Tasks.get_plan(plan.id)
      assert reloaded.status == "pending_review"
      assert reloaded.auto_approved_at == nil

      # The task stays in planning: a human (or architect gate) still owns
      # the approval. auto_approve_precondition/2 skipped, silently, as
      # designed.
      assert Tasks.get_task_record(task.id).status == "planning"
    end

    # ── plan_reject (task 01a05b32 stage 1) ─────────────────────────────

    defp draft_plan_task(title) do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: title})
      {:ok, plan} = create_submittable_plan(%{task_id: task.id})
      %{task: task, plan: plan}
    end

    test "plan_reject discards a draft and persists the reason" do
      %{plan: plan} = draft_plan_task("Reject task")

      {:ok, rejected} =
        ToolSurface.execute(
          "plan_reject",
          %{"plan_id" => plan.id, "rejection_reason" => "  draft missed the migration step  "},
          %{}
        )

      assert rejected.status == "rejected"
      assert rejected.rejection_reason == "draft missed the migration step"
      assert rejected.is_current == false

      reloaded = Tasks.get_plan(plan.id)
      assert reloaded.status == "rejected"
      assert reloaded.rejection_reason == "draft missed the migration step"
    end

    # THE acceptance criterion, end to end over the tool surface: after
    # plan_reject on a draft, plan_create succeeds on the SAME task — no
    # submit, no human round-trip, no admin/DB step.
    test "plan_create works immediately after plan_reject; the task is untouched" do
      %{task: task, plan: plan} = draft_plan_task("Self-service task")
      {:ok, task} = Tasks.update_task(task, %{status: "planning"})

      {:ok, _} =
        ToolSurface.execute(
          "plan_reject",
          %{"plan_id" => plan.id, "rejection_reason" => "obsolete scope"},
          %{}
        )

      # NO task transition: the draft never moved the task past planning.
      assert Tasks.get_task_record(task.id).status == "planning"

      assert {:ok, fresh} =
               ToolSurface.execute("plan_create", %{"task_id" => task.id, "stages" => []}, %{})

      assert fresh.status == "draft"
      assert fresh.version == plan.version + 1
    end

    test "plan_reject on a pending_review plan is refused and the row is unchanged" do
      %{plan: plan} = draft_plan_task("Pending task")
      {:ok, _} = Tasks.submit_plan_for_review(plan)

      {:error, error} =
        ToolSurface.execute(
          "plan_reject",
          %{"plan_id" => plan.id, "rejection_reason" => "not mine to withdraw"},
          %{}
        )

      assert error.recoverable == false
      assert error.error =~ "draft-status plans (current: pending_review)"
      assert error.suggestion =~ "wait for the human reviewer"
      assert error.suggestion =~ "cannot withdraw a submitted plan"

      reloaded = Tasks.get_plan(plan.id)
      assert reloaded.status == "pending_review"
      assert is_nil(reloaded.rejection_reason)
    end

    test "plan_reject on an approved plan is refused and the row is unchanged" do
      %{plan: plan} = draft_plan_task("Approved task")
      {:ok, plan} = Tasks.submit_plan_for_review(plan)
      {:ok, _} = Tasks.approve_plan(plan, "system")

      {:error, error} =
        ToolSurface.execute(
          "plan_reject",
          %{"plan_id" => plan.id, "rejection_reason" => "nope"},
          %{}
        )

      assert error.recoverable == false
      assert error.error =~ "draft-status plans (current: approved)"
      assert error.suggestion =~ "immutable to this tool"

      reloaded = Tasks.get_plan(plan.id)
      assert reloaded.status == "approved"
      assert is_nil(reloaded.rejection_reason)
    end

    test "plan_reject on an already-rejected plan is refused and the row is unchanged" do
      %{plan: plan} = draft_plan_task("Already-rejected task")
      {:ok, _} = Tasks.reject_plan(plan, "reviewer", "human rejection")

      {:error, error} =
        ToolSurface.execute(
          "plan_reject",
          %{"plan_id" => plan.id, "rejection_reason" => "again"},
          %{}
        )

      assert error.recoverable == false
      assert error.error =~ "draft-status plans (current: rejected)"

      reloaded = Tasks.get_plan(plan.id)
      assert reloaded.status == "rejected"
      assert reloaded.rejection_reason == "human rejection"
    end

    test "plan_reject with a blank or whitespace rejection_reason is a parameter error" do
      %{plan: plan} = draft_plan_task("Blank reason task")

      for reason <- ["", "   ", "\t\n"] do
        {:error, error} =
          ToolSurface.execute(
            "plan_reject",
            %{"plan_id" => plan.id, "rejection_reason" => reason},
            %{}
          )

        assert error.recoverable == true
        assert error.error =~ "rejection_reason"
        assert error.error =~ "non-blank"
      end

      # Missing entirely is the same parameter error.
      {:error, error} =
        ToolSurface.execute("plan_reject", %{"plan_id" => plan.id}, %{})

      assert error.error =~ "rejection_reason"

      reloaded = Tasks.get_plan(plan.id)
      assert reloaded.status == "draft"
      assert is_nil(reloaded.rejection_reason)
    end

    test "plan_create blocked by a DRAFT is self-service: recoverable, names the two exits" do
      %{plan: plan} = draft_plan_task("Draft-locked task")

      {:error, error} =
        ToolSurface.execute("plan_create", %{"task_id" => plan.task_id, "stages" => []}, %{})

      assert error.recoverable == true
      assert error.error =~ "already draft"
      assert error.suggestion =~ "plan_update"
      assert error.suggestion =~ "plan_reject"
    end

    test "plan_create blocked by a pending_review plan keeps the wait-for-human wording" do
      %{plan: plan} = draft_plan_task("Pending-locked task")
      {:ok, _} = Tasks.submit_plan_for_review(plan)

      {:error, error} =
        ToolSurface.execute("plan_create", %{"task_id" => plan.task_id, "stages" => []}, %{})

      assert error.recoverable == false
      assert error.error =~ "already pending_review"
      assert error.suggestion =~ "Wait for human approval"
    end

    test "plan_reject with an unknown plan_id returns the not-found envelope" do
      {:error, error} =
        ToolSurface.execute(
          "plan_reject",
          %{"plan_id" => Ecto.UUID.generate(), "rejection_reason" => "x"},
          %{}
        )

      assert error.recoverable == false
      assert error.error =~ "Plan not found"
    end

    test "plan_reject bridges an audit row with the actor and reason" do
      # Attach the TelemetryHandler explicitly — in some test envs the
      # Application-boot attach hasn't run and the audit bridge would be
      # inert. Restored on exit, because it is VM-global (task 019f9d80).
      Platform.TelemetryHelpers.ensure_boot_handler!(Platform.Audit.TelemetryHandler)

      %{plan: plan} = draft_plan_task("Audit task")

      {:ok, _} =
        ToolSurface.execute(
          "plan_reject",
          %{
            "plan_id" => plan.id,
            "rejection_reason" => "wrong stage split",
            "rejected_by" => "planner-agent"
          },
          %{}
        )

      events = Platform.Audit.list(event_type: "platform.tasks.plan_rejected")

      assert Enum.any?(events, fn e ->
               e.resource_type == "plan" and e.resource_id == plan.id and
                 e.action == "plan_rejected" and e.actor_type == "agent" and
                 e.metadata["rejected_by"] == "planner-agent" and
                 e.metadata["rejection_reason"] == "wrong stage split" and
                 e.metadata["task_id"] == plan.task_id
             end),
             "expected an audit row for the plan_rejected event; got #{inspect(events)}"
    end

    test "plan_reject defaults rejected_by to system when no caller identity is present" do
      Platform.TelemetryHelpers.ensure_boot_handler!(Platform.Audit.TelemetryHandler)

      %{plan: plan} = draft_plan_task("System actor task")

      {:ok, _} =
        ToolSurface.execute(
          "plan_reject",
          %{"plan_id" => plan.id, "rejection_reason" => "default actor"},
          %{}
        )

      events = Platform.Audit.list(event_type: "platform.tasks.plan_rejected")

      assert Enum.any?(events, fn e ->
               e.resource_id == plan.id and e.actor_type == "system" and
                 e.metadata["rejected_by"] == "system"
             end)
    end

    # ── plan_update (task 01a05b32 stage 2) ─────────────────────────────

    # A draft with a WRONG tree, created through the tool the way a planner
    # creates one. The old stage's description is load-bearing in the
    # byte-identity assertions below.
    defp staged_draft_task(title) do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: title})

      {:ok, plan} =
        ToolSurface.execute(
          "plan_create",
          %{
            "task_id" => task.id,
            "stages" => [
              %{
                "name" => "Wrong stage",
                "description" => "The WRONG description",
                "position" => 1,
                "validations" => [%{"kind" => "lint_pass"}]
              }
            ]
          },
          %{}
        )

      %{task: task, plan: plan}
    end

    defp corrected_stages do
      [
        %{
          "name" => "Build",
          "description" => "Build the corrected thing",
          "position" => 1,
          "validations" => [%{"kind" => "test_pass"}, %{"kind" => "lint_pass"}]
        },
        %{
          "name" => "Surface",
          "description" => "Surface the corrected thing",
          "position" => 2,
          "validations" => [%{"kind" => "code_review"}]
        }
      ]
    end

    defp plan_tree(plan_id) do
      plan_id |> Tasks.get_plan() |> Repo.preload(stages: :validations)
    end

    defp plan_validation_ids(plan_id) do
      Repo.one(
        from(v in Tasks.Validation,
          join: s in Tasks.Stage,
          on: v.stage_id == s.id,
          where: s.plan_id == ^plan_id,
          select: count(v.id)
        )
      )
    end

    # Discriminating fixture for the `Plan.stages` ordering contract (ticket
    # 01a077e7). Every other test in this block feeds `corrected_stages/0`,
    # whose list order ALREADY matches position order — so it passes whether
    # or not the association orders by position, which is how the missing
    # `preload_order` survived. Here the input list is deliberately in
    # DESCENDING position order, so insertion order and position order
    # disagree: without `preload_order: [asc: :position]` on
    # `Plan.has_many(:stages)` the reload comes back ["Surface", "Build"],
    # and without the sort in `replace_plan_stages/3` so does the value the
    # tool returns.
    defp out_of_order_stages do
      [
        %{
          "name" => "Surface",
          "description" => "Second by position, FIRST in the input list",
          "position" => 2,
          "validations" => [%{"kind" => "code_review"}]
        },
        %{
          "name" => "Build",
          "description" => "First by position, SECOND in the input list",
          "position" => 1,
          "validations" => [%{"kind" => "test_pass"}]
        }
      ]
    end

    test "plan_update returns and persists stages in POSITION order, not insertion order" do
      %{plan: plan} = staged_draft_task("Out-of-order update task")

      {:ok, updated} =
        ToolSurface.execute(
          "plan_update",
          %{"plan_id" => plan.id, "stages" => out_of_order_stages()},
          %{}
        )

      # The value the tool hands back is ordered by position, even though the
      # caller supplied the stages the other way round.
      assert Enum.map(updated.stages, & &1.position) == [1, 2]
      assert Enum.map(updated.stages, & &1.name) == ["Build", "Surface"]

      # …and a fresh preload agrees, which is the association's contract
      # rather than one call site remembering to sort.
      reloaded = plan_tree(plan.id)
      assert Enum.map(reloaded.stages, & &1.position) == [1, 2]
      assert Enum.map(reloaded.stages, & &1.name) == ["Build", "Surface"]

      # The tree is still correct, not merely sorted: validations followed
      # their own stage across the recreation.
      build = Enum.find(reloaded.stages, &(&1.name == "Build"))
      assert Enum.map(build.validations, & &1.kind) == ["test_pass"]
    end

    test "plan_update swaps the draft's tree in place: id + version stable, no orphans" do
      %{plan: plan} = staged_draft_task("Update task")

      old_stage_ids = Enum.map(plan.stages, & &1.id)

      old_validation_ids =
        Enum.flat_map(plan.stages, fn s -> Enum.map(s.validations, & &1.id) end)

      {:ok, updated} =
        ToolSurface.execute(
          "plan_update",
          %{"plan_id" => plan.id, "stages" => corrected_stages()},
          %{}
        )

      # The plan ROW is reused, not replaced: this is a correction, not a
      # new version row.
      assert updated.id == plan.id
      assert updated.version == plan.version
      assert updated.status == "draft"

      # The corrected tree is visible in the RETURNED plan…
      assert Enum.map(updated.stages, & &1.name) == ["Build", "Surface"]
      assert Enum.map(updated.stages, & &1.position) == [1, 2]

      build = Enum.find(updated.stages, &(&1.name == "Build"))
      assert length(build.validations) == 2
      assert Enum.any?(build.validations, &(&1.kind == "test_pass"))

      # …and identical via Tasks.get_plan — persistence, not just the return.
      reloaded = plan_tree(plan.id)
      assert Enum.map(reloaded.stages, & &1.name) == ["Build", "Surface"]
      assert Enum.map(reloaded.stages, & &1.position) == [1, 2]

      # The old stages are GONE (recreated, not mutated), and no orphaned
      # validation rows point at the deleted stages.
      new_stage_ids = Enum.map(reloaded.stages, & &1.id)
      assert old_stage_ids -- new_stage_ids == old_stage_ids

      orphaned =
        Repo.all(from(v in Tasks.Validation, where: v.stage_id in ^old_stage_ids))

      assert orphaned == []
      refute old_validation_ids == []

      # Exactly the new validations exist for the plan: 2 on Build, 1 on
      # Surface — no stragglers, no duplicates.
      assert plan_validation_ids(plan.id) == 3
    end

    # THE acceptance criterion: a planner fixes its wrong draft over MCP and
    # submits the CORRECTED plan, with the SAME plan id it held before the
    # correction — and approval flows normally with the corrected stages.
    test "plan_submit after plan_update submits the corrected tree and approval flows" do
      %{task: task, plan: plan} = staged_draft_task("Submit-after-update task")

      {:ok, updated} =
        ToolSurface.execute(
          "plan_update",
          %{"plan_id" => plan.id, "stages" => corrected_stages()},
          %{}
        )

      # The caller's OLD plan id submits — the correction did not mint a
      # different handle.
      {:ok, submitted} = ToolSurface.execute("plan_submit", %{"plan_id" => updated.id}, %{})
      assert submitted.id == plan.id
      assert submitted.version == plan.version
      assert submitted.status == "pending_review"

      # The sort is now belt-and-braces: `Plan.has_many(:stages)` carries
      # `preload_order: [asc: :position]` (ticket 01a077e7), so plan_submit's
      # preload arrives ordered. It used to preload with no ORDER BY, which is
      # what this sort was written to work around. Kept because this asserts a
      # property of the TREE, not of one preload's ordering.
      assert Enum.map(Enum.sort_by(submitted.stages, & &1.position), & &1.name) ==
               ["Build", "Surface"]

      {:ok, _approved} = Tasks.approve_plan(Tasks.get_plan(plan.id), "system")

      # current_plan/1 (what approved-plan consumers read) carries the
      # CORRECTED tree.
      current = Tasks.current_plan(task.id)
      assert current.status == "approved"
      assert current.id == plan.id

      assert Enum.map(Enum.sort_by(current.stages, & &1.position), & &1.name) ==
               ["Build", "Surface"]
    end

    test "plan_update on a pending_review plan is refused and the tree is byte-identical" do
      %{plan: plan} = staged_draft_task("Locked draft task")
      {:ok, _} = Tasks.submit_plan_for_review(Tasks.get_plan(plan.id))

      before = plan_tree(plan.id)

      {:error, error} =
        ToolSurface.execute(
          "plan_update",
          %{"plan_id" => plan.id, "stages" => corrected_stages()},
          %{}
        )

      assert error.recoverable == false
      assert error.error =~ "draft-status plans (current: pending_review)"
      assert error.suggestion =~ "wait for the human reviewer"
      assert error.suggestion =~ "cannot withdraw or edit a submitted plan"

      # BYTE-IDENTICAL: same stage rows (ids), same description, same
      # validation rows. A refused update must not have touched anything.
      after_tree = plan_tree(plan.id)
      assert Enum.map(after_tree.stages, & &1.id) == Enum.map(before.stages, & &1.id)

      wrong = Enum.find(after_tree.stages, &(&1.name == "Wrong stage"))
      assert wrong.description == "The WRONG description"

      assert Enum.map(after_tree.stages, fn s -> Enum.map(s.validations, & &1.id) end) ==
               Enum.map(before.stages, fn s -> Enum.map(s.validations, & &1.id) end)
    end

    test "plan_update on an approved plan is refused and the tree is byte-identical" do
      %{plan: plan} = staged_draft_task("Approved update task")
      {:ok, _} = Tasks.submit_plan_for_review(Tasks.get_plan(plan.id))
      {:ok, _} = Tasks.approve_plan(Tasks.get_plan(plan.id), "system")

      before = plan_tree(plan.id)

      {:error, error} =
        ToolSurface.execute(
          "plan_update",
          %{"plan_id" => plan.id, "stages" => corrected_stages()},
          %{}
        )

      assert error.recoverable == false
      assert error.error =~ "draft-status plans (current: approved)"
      assert error.suggestion =~ "immutable to this tool"

      after_tree = plan_tree(plan.id)
      assert Enum.map(after_tree.stages, & &1.id) == Enum.map(before.stages, & &1.id)

      wrong = Enum.find(after_tree.stages, &(&1.name == "Wrong stage"))
      assert wrong.description == "The WRONG description"

      assert Enum.map(after_tree.stages, fn s -> Enum.map(s.validations, & &1.id) end) ==
               Enum.map(before.stages, fn s -> Enum.map(s.validations, & &1.id) end)
    end

    test "plan_update lifts e2e cases into the task-level review stage identically to plan_create" do
      %{plan: plan} = staged_draft_task("E2E update task")

      {:ok, updated} =
        ToolSurface.execute(
          "plan_update",
          %{
            "plan_id" => plan.id,
            "stages" => [
              %{
                "name" => "Add the guard",
                "description" => "Add it",
                "position" => 1,
                "validations" => [%{"kind" => "test_pass"}, e2e_case("corrected plan")]
              }
            ]
          },
          %{}
        )

      names = Enum.map(updated.stages, & &1.name)
      assert List.last(names) == "Task-level review"
      assert Enum.take(names, 1) == ["Add the guard"]

      host = List.last(updated.stages)
      assert Enum.count(host.validations, &(&1.kind == "e2e_behavior")) == 1

      # The authored stage KEEPS its non-e2e validation — routing lifts the
      # e2e case, it does not move the rest.
      authored = List.first(updated.stages)
      assert Enum.count(authored.validations, &(&1.kind == "test_pass")) == 1

      # No e2e case was left behind on the authored stage.
      refute Enum.any?(authored.validations, &(&1.kind == "e2e_behavior"))
    end

    test "plan_update refuses a trigger-named stage carrying e2e cases and writes nothing" do
      %{plan: plan} = staged_draft_task("Collision update task")

      {:error, env} =
        ToolSurface.execute(
          "plan_update",
          %{
            "plan_id" => plan.id,
            "stages" => [
              %{
                "name" => "Widen task_plan_review output class",
                "description" => "Widen it",
                "position" => 1,
                "validations" => [%{"kind" => "test_pass"}, e2e_case("collide")]
              }
            ]
          },
          %{}
        )

      assert env.recoverable == true
      assert env.error =~ "Widen task_plan_review output class"

      # PERSISTENCE CONTROL — a refused update leaves the draft's CURRENT
      # tree byte-identical, so the planner can fix and retry.
      reloaded = plan_tree(plan.id)
      assert Enum.map(reloaded.stages, & &1.name) == ["Wrong stage"]
      assert plan_validation_ids(plan.id) == 1
    end

    test "plan_update refuses an empty stages array and leaves the draft untouched" do
      %{plan: plan} = staged_draft_task("Empty stages task")

      {:error, error} =
        ToolSurface.execute("plan_update", %{"plan_id" => plan.id, "stages" => []}, %{})

      assert error.recoverable == true
      assert error.error =~ "`stages` must not be empty"
      assert error.error =~ "at least one stage"
      assert error.suggestion =~ "plan_reject"

      reloaded = plan_tree(plan.id)
      assert Enum.map(reloaded.stages, & &1.name) == ["Wrong stage"]
      assert plan_validation_ids(plan.id) == 1
    end

    test "plan_update with missing or non-list stages is a parameter error" do
      %{plan: plan} = staged_draft_task("Bad stages task")

      {:error, error} = ToolSurface.execute("plan_update", %{"plan_id" => plan.id}, %{})
      assert error.recoverable == true
      assert error.error =~ "`stages` is required"

      {:error, error} =
        ToolSurface.execute("plan_update", %{"plan_id" => plan.id, "stages" => "nope"}, %{})

      assert error.recoverable == true
      assert error.error =~ "`stages` is required"

      reloaded = plan_tree(plan.id)
      assert Enum.map(reloaded.stages, & &1.name) == ["Wrong stage"]
    end

    test "plan_update with an unknown plan_id returns the not-found envelope" do
      {:error, error} =
        ToolSurface.execute(
          "plan_update",
          %{"plan_id" => Ecto.UUID.generate(), "stages" => corrected_stages()},
          %{}
        )

      assert error.recoverable == false
      assert error.error =~ "Plan not found"
    end

    test "plan_update bridges an audit row with the actor and a before/after summary" do
      # Attach the TelemetryHandler explicitly — in some test envs the
      # Application-boot attach hasn't run and the audit bridge would be
      # inert. Restored on exit, because it is VM-global (task 019f9d80).
      Platform.TelemetryHelpers.ensure_boot_handler!(Platform.Audit.TelemetryHandler)

      %{plan: plan} = staged_draft_task("Audit update task")

      {:ok, _updated} =
        ToolSurface.execute(
          "plan_update",
          %{
            "plan_id" => plan.id,
            "stages" => corrected_stages(),
            "updated_by" => "planner-agent"
          },
          %{}
        )

      events = Platform.Audit.list(event_type: "platform.tasks.plan_updated")

      assert Enum.any?(
               events,
               fn e ->
                 e.resource_type == "plan" and e.resource_id == plan.id and
                   e.action == "plan_updated" and e.actor_type == "agent" and
                   e.metadata["updated_by"] == "planner-agent" and
                   e.metadata["task_id"] == plan.task_id and
                   e.metadata["before"]["stage_count"] == 1 and
                   e.metadata["before"]["stages"] == [
                     %{
                       "position" => 1,
                       "name" => "Wrong stage",
                       "validation_kinds" => ["lint_pass"]
                     }
                   ] and
                   e.metadata["after"]["stage_count"] == 2 and
                   e.metadata["after"]["stages"] == [
                     %{
                       "position" => 1,
                       "name" => "Build",
                       "validation_kinds" => ["test_pass", "lint_pass"]
                     },
                     %{
                       "position" => 2,
                       "name" => "Surface",
                       "validation_kinds" => ["code_review"]
                     }
                   ]
               end
             ),
             "expected an audit row for the plan_updated event; got #{inspect(events)}"
    end

    test "plan_update defaults updated_by to system when no caller identity is present" do
      Platform.TelemetryHelpers.ensure_boot_handler!(Platform.Audit.TelemetryHandler)

      %{plan: plan} = staged_draft_task("System actor update task")

      {:ok, _} =
        ToolSurface.execute(
          "plan_update",
          %{"plan_id" => plan.id, "stages" => corrected_stages()},
          %{}
        )

      events = Platform.Audit.list(event_type: "platform.tasks.plan_updated")

      assert Enum.any?(events, fn e ->
               e.resource_id == plan.id and e.actor_type == "system" and
                 e.metadata["updated_by"] == "system"
             end)
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
            "needs_human" => true,
            "attempts" => [
              "checked the deploy secret in 1Password: absent",
              "searched the repo for DEPLOY_TOKEN: only CI references",
              "asked the deploy agent in the execution space: no reply in 30m"
            ],
            "memory_ref" => "org/page/deploy.md",
            "unblock_action" => "Rowan pastes the deploy token into the CI secret",
            "category" => "decision"
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

    # Migrated from execute/3 to dispatch/3 in 019fa609 stage 4: the tool's own
    # presence check is gone and the generic gate now produces this refusal, so
    # asserting at execute/3 would assert nothing (the handler would call
    # Chat.list_participants(nil) and raise). The deletion also flipped
    # recoverable from false to true — telling an agent that misspelled an
    # argument to give up was the bug, not the wording.
    test "space_list_agents returns an error when space_id is missing" do
      assert {:error, err} = ToolArguments.dispatch("space_list_agents", %{}, %{})
      assert err.error =~ "space_id is required"
      assert err.code == :missing_space_id
      assert err.recoverable == true
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

    # Migrated to dispatch/3 in 019fa609 stage 4 — see space_list_agents above.
    test "space_leave requires space_id" do
      agent = create_agent()

      assert {:error, error} =
               ToolArguments.dispatch("space_leave", %{}, %{agent_id: agent.id})

      assert error.error =~ "space_id is required"
      assert error.code == :missing_space_id
      assert error.recoverable == true
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

    # ── send_media: file_base64 (task 01a0d4a0 stage 5) ────────────────────
    #
    # A remote MCP caller (`services/meeting-voice-agent`'s worker) has no
    # filesystem in common with Core — a local `file_path` it writes is
    # unreadable here (`:enoent`). `file_base64` is the cross-host-safe
    # shape: bytes travel over the wire, never a path. These tests never
    # create a local temp file at all, unlike the file_path/file_paths
    # tests above — that absence IS the point being proven.

    test "send_media posts a message with a file_base64 attachment, no local path involved" do
      space = create_space()
      participant = create_participant(space.id)

      test_uploads = Path.join(System.tmp_dir!(), "platform_test_uploads_#{Ecto.UUID.generate()}")
      prev = Application.get_env(:platform, :chat_attachments_root)
      Application.put_env(:platform, :chat_attachments_root, test_uploads)

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
              "file_base64" => Base.encode64("here is the long hand-off answer"),
              "content" => "here is the long hand-off answer",
              "filename" => "response.md"
            },
            context
          )

        assert is_binary(result.message_id)
        assert result.space_id == space.id
        assert result.attachment_count == 1
      after
        Application.put_env(:platform, :chat_attachments_root, prev)
        File.rm_rf(test_uploads)
      end
    end

    test "send_media rejects invalid file_base64 without touching storage" do
      space = create_space()
      participant = create_participant(space.id)

      context = %{
        space_id: space.id,
        agent_participant_id: participant.id
      }

      {:error, error} =
        ToolSurface.execute(
          "send_media",
          %{"space_id" => space.id, "file_base64" => "not-valid-base64!!"},
          context
        )

      assert error.error =~ "Failed to send media"
    end

    # ── send_media space authorization (task 01a0ac54) ───────────────────
    #
    # Driven through `ToolArguments.dispatch/3` with the context shape both
    # transports build (`MCPController.build_context/2`,
    # `RuntimeChannel.execute_tool_call/4`): `agent_participant_id` is nil for
    # a caller with no participant row in `space_id`.
    #
    # The Message changeset still refuses a nil participant_id, so absence of
    # a Message row alone cannot detect removal of the gate. The refusal string,
    # the `recoverable: false` flag and the EMPTY attachments root can: without
    # the gate, persist_send_media_attachments/1 writes the file before the
    # changeset refuses the insert.

    defp with_send_media_fixture(fun) do
      root = Path.join(System.tmp_dir!(), "platform_test_uploads_#{Ecto.UUID.generate()}")
      prev = Application.get_env(:platform, :chat_attachments_root)
      Application.put_env(:platform, :chat_attachments_root, root)

      tmp_path = Path.join(System.tmp_dir!(), "test-upload-#{Ecto.UUID.generate()}.txt")
      File.write!(tmp_path, "hello world")

      try do
        fun.(tmp_path, root)
      after
        Application.put_env(:platform, :chat_attachments_root, prev)
        File.rm(tmp_path)
        File.rm_rf(root)
      end
    end

    defp stored_files(root) do
      root
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
    end

    defp transport_context(space_id, agent) do
      %{
        space_id: space_id,
        agent_id: agent.id,
        agent_participant_id: nil,
        runtime_id: "rt-#{System.unique_integer([:positive])}"
      }
    end

    defp send_media_args(space_id, tmp_path) do
      %{"space_id" => space_id, "file_path" => tmp_path, "content" => "hi"}
    end

    test "send_media refuses a caller with no participant row in an existing space, before any storage write" do
      agent = create_agent()
      space = create_space()
      # Someone else is in the space; the caller is not.
      create_participant(space.id)

      with_send_media_fixture(fn tmp_path, root ->
        assert {:error, error} =
                 ToolArguments.dispatch(
                   "send_media",
                   send_media_args(space.id, tmp_path),
                   transport_context(space.id, agent)
                 )

        assert error.error == "Access denied: agent is not a participant in space #{space.id}"
        assert error.recoverable == false
        assert error.suggestion == "Use space_list to find spaces the agent has access to"
        refute error.error =~ "Changeset"

        assert Repo.aggregate(
                 from(m in Platform.Chat.Message, where: m.space_id == ^space.id),
                 :count
               ) == 0

        assert stored_files(root) == []
      end)
    end

    test "send_media refuses a well-formed space_id naming no space" do
      agent = create_agent()
      ghost_id = Ecto.UUID.generate()

      with_send_media_fixture(fn tmp_path, root ->
        assert {:error, error} =
                 ToolArguments.dispatch(
                   "send_media",
                   send_media_args(ghost_id, tmp_path),
                   transport_context(ghost_id, agent)
                 )

        assert error.error == "Access denied: agent is not a participant in space #{ghost_id}"
        assert error.recoverable == false
        assert stored_files(root) == []
      end)
    end

    test "send_media refuses a non-UUID space_id without raising" do
      agent = create_agent()

      with_send_media_fixture(fn tmp_path, root ->
        assert {:error, error} =
                 ToolArguments.dispatch(
                   "send_media",
                   send_media_args("not-a-uuid", tmp_path),
                   transport_context("not-a-uuid", agent)
                 )

        assert error.error == "Access denied: agent is not a participant in space not-a-uuid"
        assert error.recoverable == false
        assert stored_files(root) == []
      end)
    end

    test "send_media resolves the caller's participant row from agent_id when the context carries none" do
      agent = create_agent()
      space = create_space()

      participant =
        create_participant(space.id, %{participant_type: "agent", participant_id: agent.id})

      with_send_media_fixture(fn tmp_path, root ->
        assert {:ok, result} =
                 ToolArguments.dispatch(
                   "send_media",
                   send_media_args(space.id, tmp_path),
                   transport_context(space.id, agent)
                 )

        assert result.space_id == space.id
        assert result.attachment_count == 1

        message = Repo.get!(Platform.Chat.Message, result.message_id)
        assert message.space_id == space.id
        assert message.participant_id == participant.id

        # Positive control for the storage assertion above: a permitted call
        # DOES write under this root, so an empty root on refusal means something.
        assert [_file] = stored_files(root)
      end)
    end

    # ── send_media: a context participant from ANOTHER space (task 01a0cbe0) ──
    #
    # Before this task the writer was `context.agent_participant_id ||
    # lookup`, so a non-nil context value was trusted without checking it
    # against `args["space_id"]`. The message landed in FOREIGN and one file was
    # written. The changeset accepts any non-nil participant_id, so absence of a
    # Message row is NOT the detector here: the refusal string and the empty
    # attachments root are.

    test "send_media refuses a context participant that belongs to another space, before any storage write" do
      agent = create_agent()
      good = create_space()
      foreign = create_space()
      create_participant(foreign.id)

      good_participant =
        create_participant(good.id, %{participant_type: "agent", participant_id: agent.id})

      with_send_media_fixture(fn tmp_path, root ->
        assert {:error, error} =
                 ToolArguments.dispatch(
                   "send_media",
                   send_media_args(foreign.id, tmp_path),
                   %{
                     space_id: foreign.id,
                     agent_id: agent.id,
                     agent_participant_id: good_participant.id
                   }
                 )

        assert error.error == "Access denied: agent is not a participant in space #{foreign.id}"
        assert error.recoverable == false
        assert stored_files(root) == []

        assert Repo.aggregate(
                 from(m in Platform.Chat.Message, where: m.space_id == ^foreign.id),
                 :count
               ) == 0
      end)
    end

    test "send_media honours a context participant that belongs to the target space" do
      agent = create_agent()
      space = create_space()

      participant =
        create_participant(space.id, %{participant_type: "agent", participant_id: agent.id})

      with_send_media_fixture(fn tmp_path, root ->
        assert {:ok, result} =
                 ToolArguments.dispatch(
                   "send_media",
                   send_media_args(space.id, tmp_path),
                   %{space_id: space.id, agent_id: agent.id, agent_participant_id: participant.id}
                 )

        message = Repo.get!(Platform.Chat.Message, result.message_id)
        assert message.space_id == space.id
        assert message.participant_id == participant.id
        assert [_file] = stored_files(root)
      end)
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

    # Task 01a0ac54 stage 2: react's participant nil-check had no test pinning
    # its refusal. The caller is named by `agent_id` only and has no participant
    # row in the space that owns the message, so both lookups come back nil.
    test "react refuses a caller with no participant row in the message's space" do
      agent = create_agent()
      space = create_space()
      author = create_participant(space.id)

      {:ok, message} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "hello"
        })

      assert {:error, error} =
               ToolSurface.execute(
                 "react",
                 %{"space_id" => space.id, "message_id" => message.id, "emoji" => "👍"},
                 %{space_id: space.id, agent_id: agent.id, agent_participant_id: nil}
               )

      assert error.error == "Access denied: agent is not a participant in space #{space.id}"
      assert error.recoverable == false
      assert error.suggestion == "Use space_list to find spaces the agent has access to"
      assert Chat.list_reactions(message.id) == []
    end

    # Task 01a0cbe0. The message-belongs-to-space check constrains the MESSAGE,
    # not the PARTICIPANT: a message genuinely in FOREIGN passes it, and before
    # this task a GOOD participant in the context then reacted in FOREIGN.
    test "react refuses a context participant that belongs to another space" do
      agent = create_agent()
      good = create_space()
      foreign = create_space()
      author = create_participant(foreign.id)

      good_participant =
        create_participant(good.id, %{participant_type: "agent", participant_id: agent.id})

      {:ok, message} =
        Chat.post_message(%{
          space_id: foreign.id,
          participant_id: author.id,
          content_type: "text",
          content: "hello"
        })

      assert {:error, error} =
               ToolArguments.dispatch(
                 "react",
                 %{"space_id" => foreign.id, "message_id" => message.id, "emoji" => "👍"},
                 %{
                   space_id: foreign.id,
                   agent_id: agent.id,
                   agent_participant_id: good_participant.id
                 }
               )

      assert error.error == "Access denied: agent is not a participant in space #{foreign.id}"
      assert error.recoverable == false

      assert Repo.aggregate(
               from(r in Platform.Chat.Reaction, where: r.message_id == ^message.id),
               :count
             ) == 0
    end

    # Migrated to dispatch/3 in 019fa609 stage 4. The empty-string emoji is
    # deliberately kept as the input: the gate counts a blank string as absent,
    # which is the same call react's own check used to refuse. The other two
    # branches it carried (space_id, message_id) are covered by the gate's own
    # table-driven test in tool_arguments_test.exs.
    test "react rejects missing emoji" do
      space = create_space()
      participant = create_participant(space.id, %{display_name: "Agent"})

      {:error, error} =
        ToolArguments.dispatch(
          "react",
          %{"space_id" => space.id, "message_id" => Ecto.UUID.generate(), "emoji" => ""},
          %{space_id: space.id, agent_participant_id: participant.id}
        )

      assert error.error =~ "emoji is required"
      assert error.code == :missing_emoji
      assert error.recoverable == true
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
      # Status-aware since 01a05394-8300 stage 2: two `backlog` members in
      # a `forming` stack are not runnable now, so both are `blocked_now`.
      refute t1.id in result.executable_now
      refute t2.id in result.executable_now
      assert Enum.sort(result.blocked_now) == Enum.sort([t1.id, t2.id])
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

      # Task 01a05394-8300 stage 4: `stack_list` returns an envelope, not a
      # bare array.
      {:ok, %{stacks: results, total: 1, has_more: false}} =
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
      # Status-aware since 01a0562f-28ad stage 2: same partition as
      # `stack_get`. Both members are `backlog` in a `forming` stack, so a
      # backlog root is not runnable now — nothing is executable_now and
      # both (the root and the child now blocking on it) are blocked_now.
      assert result.executable_now == []
      assert Enum.sort(result.blocked_now) == Enum.sort([root.id, child.id])
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
      # Status-aware since 01a0562f-28ad stage 2: same partition as
      # `stack_get`. The edge is gone, but both members are still `backlog`
      # in a `forming` stack — a backlog root is not runnable now, so
      # nothing is executable_now and both are blocked_now.
      assert result.executable_now == []
      assert Enum.sort(result.blocked_now) == Enum.sort([root.id, child.id])
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

      {:ok, ok_member} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Healthy",
          phase_assignees: %{
            "planning" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
          }
        })

      {:ok, bad_member} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Will Fail",
          phase_assignees: %{
            "planning" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
          }
        })

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

    # Reworded by task 019fb01b stage 4, which moved this tool onto
    # `Platform.Chat.Canvas.ToolAccess.fetch_for_read/2`. The sentence is now
    # the one every canvas-id-keyed read on this surface emits, which is the
    # point of the move: a caller cannot tell which tool it knocked on from the
    # answer it got back.
    test "canvas_get with non-existent canvas returns the shared not-found envelope", ctx do
      canvas_id = Ecto.UUID.generate()

      {:error, error} =
        ToolSurface.execute(
          "canvas_get",
          %{"canvas_id" => canvas_id},
          ctx.context
        )

      assert error.error =~ "not found"
      assert error.recoverable == false
      assert error.canvas_id == canvas_id
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

    # ── canvas_get and the :task_agent grant (task 019fb01b stage 4) ──
    #
    # The widening this stage ships, stated as a test. Before it, `canvas_get`
    # asked only "is this agent in the canvas's space". These pin the two
    # halves of the new answer: a task binding is enough, and it is the ONLY
    # thing that is enough.
    #
    # This is the shape `prompt_templates.ex:506` has been instructing the
    # planner into: "If a design direction canvas is attached to this task,
    # read it with `canvas_get`." When the designer built that canvas in its
    # own space (the ADR-0046 native path) rather than the execution space,
    # that instruction was false until this stage.

    test "canvas_get resolves for an agent bound to the attached task, not the space", ctx do
      designer_space = create_space(%{name: "Designer Space"})
      designer = create_participant(designer_space.id, %{display_name: "Saru"})

      {:ok, canvas, _msg} =
        Chat.create_canvas_with_message(designer_space.id, designer.id, %{
          "title" => "Design direction"
        })

      task = task_with_attached_canvas!(canvas)

      # The real writer, not a hand-rolled map: the grant classifies on
      # `phase_assignees` as `Tasks.set_phase_assignees/2` writes it.
      {:ok, _task} =
        Tasks.set_phase_assignees(task, %{
          "planning" => %{"assignee_id" => ctx.agent.id, "assignee_type" => "agent"}
        })

      refute Chat.get_agent_participant(designer_space.id, ctx.agent.id)

      {:ok, summary} =
        ToolSurface.execute("canvas_get", %{"canvas_id" => canvas.id}, ctx.context)

      assert summary.id == canvas.id
      assert summary.title == "Design direction"

      # Full mode is the mode the planner actually needs; the grant has to
      # carry the document, not just the metadata.
      {:ok, full} =
        ToolSurface.execute(
          "canvas_get",
          %{"canvas_id" => canvas.id, "mode" => "full"},
          ctx.context
        )

      assert is_map(full.document)
    end

    # The grant is task-derived, and a task carries an org. An agent whose only
    # roster is in another org holds no grant on either side, so the widening
    # must not have opened a cross-tenant read.
    test "canvas_get denies an agent whose only roster is in another org", ctx do
      org_a = Tenancy.get_org_by_slug!("sxi")
      org_b = Tenancy.get_org_by_slug!("soylent")

      space_a = create_space(%{name: "Org A Channel", org_id: org_a.id})
      author = create_participant(space_a.id)

      {:ok, canvas, _msg} =
        Chat.create_canvas_with_message(space_a.id, author.id, %{"title" => "Merger Terms"})

      task_with_attached_canvas!(canvas)

      outsider = create_agent()
      space_b = create_space(%{name: "Org B Channel", org_id: org_b.id})

      outsider_participant =
        create_participant(space_b.id, %{
          participant_type: "agent",
          participant_id: outsider.id,
          display_name: outsider.name
        })

      context = %{agent_id: outsider.id, agent_participant_id: outsider_participant.id}

      {:error, error} = ToolSurface.execute("canvas_get", %{"canvas_id" => canvas.id}, context)

      assert error.error =~ "Access denied"
      assert error.recoverable == false
      refute Map.has_key?(error, :space_id)
      refute inspect(error) =~ "Merger Terms"
    end

    # `agent_id` is a nullable `:binary_id` on `Platform.Agents.AgentRuntime`,
    # so a runtime with no linked agent reaches this tool. It failed closed
    # before the move and it has to still fail closed after: the widening is
    # "agents bound to the task", never "callers we cannot identify".
    test "canvas_get denies a context with no agent identity", ctx do
      {:ok, canvas, _msg} =
        Chat.create_canvas_with_message(ctx.space.id, ctx.participant.id, %{
          "title" => "In-space Canvas"
        })

      for context <- [%{agent_id: nil, space_id: ctx.space.id}, %{}] do
        assert {:error, error} =
                 ToolSurface.execute("canvas_get", %{"canvas_id" => canvas.id}, context)

        assert error.recoverable == false
        refute Map.has_key?(error, :document)
        refute inspect(error) =~ "In-space Canvas"
      end
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
      agent_id = Ecto.UUID.generate()

      # The calling agent is the task's assignee. Task 019fb581 stage 3 gates
      # both writes on `Platform.Tasks.TaskAccess`, so an agent with no
      # binding to the task can no longer attach to it OR detach from it —
      # asserted in the denial tests at the end of this block. Without a
      # grant here every test in the block would be denied at the first door
      # and would assert nothing about the canvas half.
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Attach me",
          assignee_type: "agent",
          assignee_id: agent_id
        })

      space = create_space()
      participant = create_participant(space.id)

      {:ok, canvas} =
        Chat.create_canvas(%{
          "space_id" => space.id,
          "created_by" => participant.id,
          "title" => "Evidence canvas"
        })

      # …and a participant of the canvas's space. Task 019e2c4b stage 2
      # authorizes the attacher against the canvas, so an agent that was
      # never in that space can no longer attach it. The two conjuncts are
      # independent, which is why the setup has to mint both.
      create_participant(space.id, %{participant_type: "agent", participant_id: agent_id})

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

    # Mint a `TaskAccess` grant for a principal WITHOUT touching the task's
    # assignee columns: `Tasks.set_phase_assignees/2` re-derives the
    # top-level assignee from the current phase and would silently strip the
    # setup agent's own grant. `:space_member` is also the path stage 2 mints
    # for a dispatched designer, so this is the production shape.
    defp grant_task_access(task, kind, id) do
      {:ok, space} = Platform.Orchestration.ExecutionSpace.find_or_create(task.id)

      create_participant(space.id, %{participant_type: kind, participant_id: id})
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

    # ── Attacher authorization (task 019e2c4b stage 2) ───────────────────
    #
    # Attaching a canvas to a task confers `:task_reader` — org-wide read — on
    # everyone who can read that task. Without this gate, any agent could
    # staple a stranger's canvas onto a task in its own org and read it.
    test "task_attach_canvas denies an agent that cannot read the canvas", ctx do
      # Bound to the TASK (so the first door opens) but never in the canvas's
      # space. Without the task binding this would be denied one door earlier
      # and would prove nothing about the canvas conjunct.
      stranger_id = Ecto.UUID.generate()
      grant_task_access(ctx.task, "agent", stranger_id)

      stranger = %{
        agent_id: stranger_id,
        space_id: ctx.space.id,
        agent_participant_id: ctx.participant.id
      }

      {:error, error} =
        ToolSurface.execute(
          "task_attach_canvas",
          %{"task_id" => ctx.task.id, "canvas_id" => ctx.canvas.id},
          stranger
        )

      assert error.error =~ "Access denied"
      assert error.recoverable == false
      assert error.canvas_id == ctx.canvas.id

      # And nothing was written.
      {:ok, %{canvases: canvases}} =
        ToolSurface.execute("task_list_canvases", %{"task_id" => ctx.task.id}, ctx.context)

      assert canvases == []
    end

    # ── The task conjunct (task 019fb581 stage 3) ────────────────────────
    #
    # `task_attach_canvas` mints a `:task_reader` grant. Until this stage any
    # runtime holding a canvas could staple it onto any task it could name.
    test "task_attach_canvas denies an agent with no binding to the task", ctx do
      # Reads the canvas fine — it is in the canvas's space. The ONLY thing
      # it lacks is a relationship with the task.
      stranger_id = Ecto.UUID.generate()
      create_participant(ctx.space.id, %{participant_type: "agent", participant_id: stranger_id})

      {:error, error} =
        ToolSurface.execute(
          "task_attach_canvas",
          %{"task_id" => ctx.task.id, "canvas_id" => ctx.canvas.id},
          %{agent_id: stranger_id, space_id: ctx.space.id}
        )

      assert error.code == :task_forbidden
      assert error.error =~ "Access denied"
      assert error.task_id == ctx.task.id
      assert error.recoverable == false

      # The denial is a RECOVERY MECHANISM: a designer who reads it can close
      # her own design step in one call instead of burning the 30-minute hold.
      assert error.suggestion =~ "task_design_decline"

      {:ok, %{canvases: canvases}} =
        ToolSurface.execute("task_list_canvases", %{"task_id" => ctx.task.id}, ctx.context)

      assert canvases == []
    end

    test "task_attach_canvas denies a caller with no identity at all", ctx do
      {:error, error} =
        ToolSurface.execute(
          "task_attach_canvas",
          %{"task_id" => ctx.task.id, "canvas_id" => ctx.canvas.id},
          %{}
        )

      # `canvas_authorization_actor/1` returns nil for a context with neither
      # key, and nil is no principal at BOTH doors. The task door is first.
      assert error.code == :task_forbidden
      assert error.error =~ "Access denied"
    end

    # The gate reads `:agent_id` / `:user_id` as the SUBJECT; `attached_by` is
    # attribution and is recorded from the same context but never consulted for
    # authorization.
    test "task_attach_canvas authorizes a participating user via :user_id", ctx do
      user_id = Ecto.UUID.generate()
      create_participant(ctx.space.id, %{participant_id: user_id})
      grant_task_access(ctx.task, "user", user_id)

      assert {:ok, result} =
               ToolSurface.execute(
                 "task_attach_canvas",
                 %{"task_id" => ctx.task.id, "canvas_id" => ctx.canvas.id},
                 %{user_id: user_id}
               )

      assert result.canvas_id == ctx.canvas.id
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

    # ── The detach gate (task 019fb581 stage 3) ──────────────────────────
    #
    # This clause ignored its `context` entirely until stage 3: any runtime
    # that knew a task id and a canvas id could revoke the attachment.
    test "task_detach_canvas denies an agent with no binding to the task", ctx do
      {:ok, _} =
        ToolSurface.execute(
          "task_attach_canvas",
          %{"task_id" => ctx.task.id, "canvas_id" => ctx.canvas.id},
          ctx.context
        )

      stranger_id = Ecto.UUID.generate()
      create_participant(ctx.space.id, %{participant_type: "agent", participant_id: stranger_id})

      {:error, error} =
        ToolSurface.execute(
          "task_detach_canvas",
          %{"task_id" => ctx.task.id, "canvas_id" => ctx.canvas.id},
          %{agent_id: stranger_id, space_id: ctx.space.id}
        )

      assert error.code == :task_forbidden
      assert error.error =~ "Access denied"
      assert error.task_id == ctx.task.id
      assert error.recoverable == false

      # The attachment survived — a denial is not a silent no-op.
      {:ok, %{canvases: canvases}} =
        ToolSurface.execute("task_list_canvases", %{"task_id" => ctx.task.id}, ctx.context)

      assert [_row] = canvases
    end

    test "task_detach_canvas denies a caller with no identity at all", ctx do
      {:ok, _} =
        ToolSurface.execute(
          "task_attach_canvas",
          %{"task_id" => ctx.task.id, "canvas_id" => ctx.canvas.id},
          ctx.context
        )

      {:error, error} =
        ToolSurface.execute(
          "task_detach_canvas",
          %{"task_id" => ctx.task.id, "canvas_id" => ctx.canvas.id},
          %{}
        )

      assert error.code == :task_forbidden
    end

    test "task_detach_canvas surfaces task_not_found for an unknown task", ctx do
      {:error, error} =
        ToolSurface.execute(
          "task_detach_canvas",
          %{"task_id" => Ecto.UUID.generate(), "canvas_id" => ctx.canvas.id},
          ctx.context
        )

      assert error.error =~ "Task not found"
      assert error.recoverable == false
    end

    # ── The read gate (task 019fb581 stage 4) ────────────────────────────
    #
    # `task_list_canvases` ignored its `context` until stage 4. It returns
    # attachment metadata rather than canvas documents, so this is defence in
    # depth: what it closes is enumerating which canvases hang off a task the
    # caller has nothing to do with, and the titles that ride along.
    test "task_list_canvases denies an agent with no binding to the task", ctx do
      {:ok, _} =
        ToolSurface.execute(
          "task_attach_canvas",
          %{"task_id" => ctx.task.id, "canvas_id" => ctx.canvas.id, "note" => "private"},
          ctx.context
        )

      # Reads the canvas fine, since it is in the canvas's space. The only thing it
      # lacks is a relationship with the TASK, which is the whole gate here.
      stranger_id = Ecto.UUID.generate()
      create_participant(ctx.space.id, %{participant_type: "agent", participant_id: stranger_id})

      result =
        ToolSurface.execute(
          "task_list_canvases",
          %{"task_id" => ctx.task.id},
          %{agent_id: stranger_id, space_id: ctx.space.id}
        )

      # THE DECISION, PINNED: a denial, never an empty list disguised as an
      # answer. An empty list is indistinguishable from "this task has no
      # attachments" and would make the tool's own `returns` contract false
      # for a task that carries one. See `Platform.Tasks.TaskAccess`'s
      # moduledoc for the full reasoning.
      refute match?({:ok, %{canvases: []}}, result)

      assert {:error, error} = result
      assert error.code == :task_forbidden
      assert error.error =~ "Access denied"
      assert error.task_id == ctx.task.id
      assert error.recoverable == false

      # And the row it refused to show is really there. Otherwise this test
      # would pass against a task with nothing attached.
      {:ok, %{canvases: [_row]}} =
        ToolSurface.execute("task_list_canvases", %{"task_id" => ctx.task.id}, ctx.context)
    end

    # THE COUPLING THAT JUSTIFIES DENYING RATHER THAN RETURNING `[]`.
    #
    # The standing objection to an authorization denial is that it is an
    # existence oracle. It is not one HERE, because `task_get` is deliberately
    # ungated (see the NON-SCOPE section in `Platform.Tasks.TaskAccess`) and
    # hands the same caller full task existence in one call from the same
    # bundle. This test fails the day somebody gates `task_get`, which is the
    # day the denial decision above needs re-deciding rather than inheriting.
    test "the actor task_list_canvases denies can still read the task via task_get", ctx do
      stranger_id = Ecto.UUID.generate()
      create_participant(ctx.space.id, %{participant_type: "agent", participant_id: stranger_id})
      stranger = %{agent_id: stranger_id, space_id: ctx.space.id}

      assert {:error, %{code: :task_forbidden}} =
               ToolSurface.execute("task_list_canvases", %{"task_id" => ctx.task.id}, stranger)

      assert {:ok, task} = ToolSurface.execute("task_get", %{"task_id" => ctx.task.id}, stranger)
      assert task.id == ctx.task.id

      # The disjointness claim the same moduledoc makes: `serialize_task/1`
      # carries no canvas data, so `task_list_canvases` is not a wrapper over
      # `task_get` and gating one without the other is coherent.
      refute Enum.any?(Map.keys(task), &(&1 |> Atom.to_string() |> String.contains?("canvas")))
    end

    test "task_list_canvases denies a caller with no identity at all", ctx do
      {:error, error} =
        ToolSurface.execute("task_list_canvases", %{"task_id" => ctx.task.id}, %{})

      assert error.code == :task_forbidden
      assert error.error =~ "Access denied"
    end

    # Positive control for the gate: a principal with a `:space_member` grant
    # and NO canvas-side standing still lists. The read gate is task-only by
    # design: `CanvasAccess`'s `:task_reader` path already says anyone who
    # can read the task may read its attached canvases, so adding a canvas
    # conjunct here would contradict the grant it is guarding.
    test "task_list_canvases allows an execution-space member of the task", ctx do
      {:ok, _} =
        ToolSurface.execute(
          "task_attach_canvas",
          %{"task_id" => ctx.task.id, "canvas_id" => ctx.canvas.id, "note" => "shared"},
          ctx.context
        )

      member_id = Ecto.UUID.generate()
      grant_task_access(ctx.task, "agent", member_id)

      assert {:ok, %{canvases: [row]}} =
               ToolSurface.execute(
                 "task_list_canvases",
                 %{"task_id" => ctx.task.id},
                 %{agent_id: member_id}
               )

      assert row.canvas_id == ctx.canvas.id
      assert row.note == "shared"
    end

    # BEHAVIOUR CHANGE, pinned rather than left to be discovered downstream:
    # an unknown task id used to read as `{:ok, %{canvases: []}}`. It now
    # matches the two write clauses.
    test "task_list_canvases surfaces task_not_found for an unknown task", ctx do
      {:error, error} =
        ToolSurface.execute(
          "task_list_canvases",
          %{"task_id" => Ecto.UUID.generate()},
          ctx.context
        )

      assert error.error =~ "Task not found"
      assert error.recoverable == false
    end

    test "task_list_canvases surfaces task_not_found for a soft-deleted task", ctx do
      {:ok, _} =
        ToolSurface.execute(
          "task_attach_canvas",
          %{"task_id" => ctx.task.id, "canvas_id" => ctx.canvas.id},
          ctx.context
        )

      {:ok, _} = Tasks.soft_delete_task(ctx.task)

      {:error, error} =
        ToolSurface.execute("task_list_canvases", %{"task_id" => ctx.task.id}, ctx.context)

      assert error.error =~ "Task not found"
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

    test "similar_tasks entries all clear the confidence threshold" do
      # REWRITTEN, task 01a08a27 stage 3. This test used to assert
      # `length(result.similar_tasks) <= 2`, which pinned the OLD
      # positional semantics: the score was `1.0 / min(semantic_rank,
      # lexical_rank)`, so rank 3 scored 0.33 and fell under the 0.5
      # cutoff, making the filter equivalent to "top-2 in some channel".
      # A COUNT bound is the wrong assertion for a match-quality score —
      # three equally-good duplicates should all be returned, and under
      # the overlap coefficient these three fixtures are equally good
      # (they differ only by a trailing index digit). Keeping `<= 2`
      # would have pinned the defect rather than the requirement, so the
      # assertion moves to the SCORE, which is what the threshold
      # actually filters on.
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
            # Body widened at stage 3, and NOT to make the assertion
            # easier. With the stage-1 body ("the definitive one") the
            # whole query was 6 raw tokens, which sits at
            # `prepare_lexical_query/1`'s short-query floor, so it kept
            # the implicit AND — and the seeds contain no "definitive",
            # so the conjunction returned zero rows. The test therefore
            # asserted over an EMPTY list, and both of its original
            # assertions (`length(...) <= 2` and `Enum.all?(...)`) are
            # trivially true of `[]`. It had been passing vacuously.
            # This body clears the floor into the OR-alternation path so
            # the seeds are actually retrieved and actually scored; the
            # `refute ... == []` below is what stops the vacuity
            # returning silently.
            "description" =>
              "the definitive raspberry gizmo cluster ticket, superseding the earlier near-matches"
          },
          %{}
        )

      # Non-vacuity: the list must not be empty, or "every entry clears
      # the threshold" is vacuously true over zero entries.
      refute result.similar_tasks == []

      assert Enum.all?(result.similar_tasks, fn entry ->
               entry.similarity_score >= 0.35
             end),
             "every returned entry must clear the threshold, got: " <>
               inspect(Enum.map(result.similar_tasks, &{&1.title, &1.similarity_score}))
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

  # ── similar_tasks scoring (task 01a08a27, stage 1) ────────────────────
  #
  # `hit_similarity_score/1` is `1.0 / min(semantic_rank, lexical_rank)`,
  # so whatever the lexical channel happens to return first is stamped
  # 1.000 — "certain duplicate" — regardless of whether it has anything
  # to do with the ticket being filed. The two tests below are a PAIR and
  # NEITHER PINS ANYTHING ALONE: the negative is satisfied by a scorer
  # hardcoded to 0.0, the positive is satisfied by the current
  # reciprocal-rank implementation. Only together do they constrain the
  # score to track match quality. Do not delete either as redundant.
  #
  # STAGE 3 UPDATE: the negative's create body is no longer short — see
  # the FIXTURE CORRECTED note inside that test for why a fully-shared
  # short query is degenerate rather than hard, and for the retrieval
  # control that replaces "short body" as the guard against vacuity. The
  # paragraph below still governs the POSITIVE control's body, which
  # remains short.
  #
  # WHY THE CREATE BODIES ARE SHORT. Measured on this branch against
  # this corpus: a 58-stem create body returns 0 lexical hits, a 33-stem
  # body returns 0, an 8-stem body returns 0, and a 3-stem body returns
  # the row at `lexical_rank 1`. That is the fault-2 conjunction, and it
  # means a ticket-length fixture here would make BOTH tests vacuous —
  # `similar_tasks == []` would hold because the channel returned
  # nothing, not because any score was filtered, and the positive control
  # would fail for a reason that has nothing to do with scoring. Short
  # bodies keep both tests inside the regime where the lexical channel
  # actually produces the candidates the scorer is supposed to judge.
  # Ticket-length behaviour is pinned separately, in
  # `search_lexical_query_test.exs`.
  #
  # Both force the Noop memory provider (see the describe setup). The
  # semantic channel is never asserted on in either direction — it stalls
  # in episodes and either assertion is a flake. Ordering and `min_rank`
  # are deliberately not asserted on; both are correct today.
  describe "task_create similar_tasks scoring (task 01a08a27, noop semantic provider)" do
    setup do
      prev = Application.get_env(:platform, :memory_service, [])

      Application.put_env(:platform, :memory_service, provider: Platform.Memory.Providers.Noop)

      on_exit(fn -> Application.put_env(:platform, :memory_service, prev) end)
      :ok
    end

    test "an unrelated top-ranked task scores below threshold" do
      project = create_project()

      # Fixture shapes taken from the two hits observed live against a
      # board-reporting create: `01a06575-4786` (status :done) reported
      # 1.000 and `01a04516-d064` (status :cancelled, "NOT A DEFECT"
      # title) reported 0.500. Neither had anything to do with the
      # ticket being filed — they shared only generic vocabulary.
      {:ok, decoy_done} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Nightly export job writes a duplicate status row",
          description:
            "The nightly export job writes a duplicate status row into the finance reconciliation sheet whenever two runs overlap."
        })

      {:ok, decoy_done} = Tasks.transition_task_status(decoy_done, "in_progress")
      {:ok, decoy_done} = Tasks.transition_task_status(decoy_done, "done")

      {:ok, decoy_cancelled} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "NOT A DEFECT: the transcription worker retries by design",
          description:
            "Filed and cancelled. The retry loop in the transcription worker is intentional backoff, not a bug."
        })

      {:ok, decoy_cancelled} = Tasks.transition_task_status(decoy_cancelled, "cancelled")

      # A ticket on a third subject — the deploy dashboard — that shares
      # the generic words "nightly", "status" and "row" with the finance
      # export decoy but nothing else. Sharing generic vocabulary is
      # exactly the case the confidence score is supposed to
      # discriminate, and exactly the case the reciprocal-rank score
      # cannot.
      #
      # FIXTURE CORRECTED, task 01a08a27 stage 3, and the correction is
      # a STRENGTHENING — read this before shortening it back. As landed
      # in stage 1 the filed title was the bare string "Nightly job
      # status row", whose every non-stopword token also appears in the
      # finance-export decoy. That makes Q a SUBSET of C, which forces
      # |Q ∩ C| = |Q| and min(|Q|, |C|) = |Q|, so the overlap
      # coefficient is exactly 1.000 — and so is the positive control in
      # the next test, which is also a containment. Two fixtures that
      # both score 1.000 cannot be separated by ANY threshold, and the
      # problem is not the choice of coefficient: Jaccard scores this
      # decoy 0.286 against the true near-duplicate's 0.263, i.e. it
      # ranks the decoy HIGHER. No symmetric token-set measure can
      # discriminate a query whose entire vocabulary is shared, because
      # there is nothing in the query that is not in the candidate.
      # That fixture was therefore not a hard case for the scorer, it
      # was a degenerate one — and note the stage-1 comment already
      # described this ticket as being about "the deploy dashboard"
      # while the string carried no deploy vocabulary at all. The body
      # below gives the ticket the subject the comment always claimed.
      #
      # It is still nowhere near ticket length (the stage-1 measurements
      # that motivated short bodies were taken at 33 and 58 stems, and
      # before stage 2 replaced the implicit AND with an OR-alternation,
      # under which a longer query returns MORE candidates rather than
      # emptying). The retrieval assertion below is what keeps that
      # judgement honest rather than assumed.
      create_title = "Deploy dashboard shows a stale status row after nightly rollback"

      create_body =
        "The deploy dashboard tile keeps rendering yesterday's release status row " <>
          "after the nightly rollback finishes, so operators comparing tiles read a " <>
          "stale artefact version."

      # ANTI-VACUITY CONTROL, and it is the whole reason this test can be
      # trusted. `similar_tasks == []` has TWO causes that are
      # indistinguishable from the assertion alone: the scorer filtered
      # the decoys out (what is under test), or the lexical channel never
      # returned them (a vacuous pass that would survive any scorer,
      # including one hardcoded to 1.0). Pin retrieval separately and
      # directly, so the emptiness below can only mean "filtered".
      {:ok, %{results: raw_hits}} =
        Platform.Org.Wiki.Search.search(create_title <> " " <> create_body,
          source: "task",
          project_id: project.id,
          agent: nil,
          limit: 6
        )

      assert decoy_done.id in Enum.map(raw_hits, & &1.id),
             "the finance-export decoy must be RETRIEVED, or this test passes vacuously " <>
               "no matter what the scorer does; got: " <> inspect(Enum.map(raw_hits, & &1.id))

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => create_title,
            "description" => create_body
          },
          %{}
        )

      assert is_binary(result.id)
      refute result.id in [decoy_done.id, decoy_cancelled.id]

      # RED before stage 3: whatever the lexical channel returned first
      # was rank 1, and rank 1 always reported 1.000, so no unrelated hit
      # could ever be filtered by the threshold. Green now because the
      # score reads token overlap and not position — the decoy shares 3
      # of its 14 tokens with a 21-token query, scoring 0.214.
      assert result.similar_tasks == [],
             "expected no unrelated hit to clear the threshold, got: " <>
               inspect(Enum.map(result.similar_tasks, &{&1.title, &1.similarity_score}))
    end

    test "a genuine near-duplicate still clears the threshold" do
      project = create_project()

      {:ok, seeded} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Nightly deploy webhook drops the release tag on rollback",
          description:
            "On rollback the deploy webhook posts the previous release tag rather than the tag being rolled back to, so the changelog entry and the deployed artefact disagree about which commit is live."
        })

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{"project_id" => project.id, "title" => "deploy webhook release tag rollback"},
          %{}
        )

      entry = Enum.find(result.similar_tasks, fn e -> e.id == seeded.id end)

      assert entry,
             "expected the near-duplicate to be returned, got: " <>
               inspect(Enum.map(result.similar_tasks, & &1.id))

      # Green today, and green BECAUSE a hit cleared the threshold —
      # not by accident of an empty list. Asserted at 0.5 rather than at
      # the 0.35 gate deliberately: a genuine near-duplicate should clear
      # the bar with margin, so this stays a real constraint even if the
      # threshold is later lowered.
      assert entry.similarity_score >= 0.5
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

  # ── M11: external-principal chat scoping (pure) ──────────────────────

  describe "external chat allowlist + scope_for_external/2" do
    @chat_names ~w(send_media react space_list space_get_context space_get_messages space_search_messages)

    test "external_chat_tools/0 is exactly the six chat tool names" do
      assert ToolSurface.external_chat_tools() == MapSet.new(@chat_names)
    end

    test "external_chat_tool?/1 recognises chat tools and rejects the rest" do
      assert ToolSurface.external_chat_tool?("send_media")
      assert ToolSurface.external_chat_tool?("react")
      assert ToolSurface.external_chat_tool?("space_list")
      refute ToolSurface.external_chat_tool?("task_create")
      refute ToolSurface.external_chat_tool?("canvas_create")
      refute ToolSurface.external_chat_tool?("space_leave")
      refute ToolSurface.external_chat_tool?("principal_search")
    end

    test "scope_for_external(_, true) yields exactly the six chat tools from a broad surface" do
      tools = ToolSurface.list_tools(~w(messaging task canvas space context_read))
      scoped = ToolSurface.scope_for_external(tools, true)

      names = scoped |> Enum.map(& &1.name) |> Enum.sort()
      assert names == Enum.sort(@chat_names)

      # None of the non-chat tools survive — including the mutating
      # space_leave and the context_read extras.
      refute "task_create" in names
      refute "canvas.create" in names
      refute "space_leave" in names
      refute "principal_search" in names
      refute "canvas_list" in names
    end

    test "scope_for_external(_, false) is the identity function" do
      tools = ToolSurface.list_tools(~w(messaging task canvas space context_read))
      assert ToolSurface.scope_for_external(tools, false) == tools
    end

    test "intersection is fail-closed: no chat bundle granted → empty, never injected" do
      # allowed_bundles = [task] only — no messaging/space/context_read.
      tools = ToolSurface.list_tools(~w(task))
      assert ToolSurface.scope_for_external(tools, true) == []
    end
  end

  # ── UUID boundary (task 019fa129 stage 4) ────────────────────────────────
  describe "UUID boundary: every id here is a raw tool argument" do
    # Every id reaching a tool in this module is literally whatever string
    # the agent typed. An unguarded `Repo.get/2` turns a typo into an
    # `Ecto.Query.CastError` that kills the tool call instead of returning
    # the tool's own not-found envelope. `get_by_uuid/2` is the seam.
    #
    # THE LOAD-BEARING INPUT IS THE 16-CHARACTER ONE. `Ecto.UUID.cast/1`
    # accepts any 16-byte binary, so a suite built from "higgins" plus a
    # valid UUID is fully green against the bug.
    @slug_16 "higginshigginsxx"

    test "stage_complete returns its not-found envelope, not a raise" do
      for id <- [@slug_16, "higgins", ""] do
        assert {:error, %{error: "Stage not found: " <> _}} =
                 ToolSurface.execute("stage_complete", %{"stage_id" => id}, %{})
      end
    end

    test "plan_approve returns its not-found envelope, not a raise" do
      for id <- [@slug_16, "higgins"] do
        assert {:error, %{error: "Plan not found: " <> _, recoverable: false}} =
                 ToolSurface.execute("plan_approve", %{"plan_id" => id}, %{})
      end
    end

    test "review_request_create does not raise on a malformed validation_id" do
      assert {:error, _} =
               ToolSurface.execute(
                 "review_request_create",
                 %{"validation_id" => @slug_16, "items" => []},
                 %{}
               )
    end

    test "org_list_descendants returns its :not_found envelope, not a raise" do
      assert {:error, %{code: :not_found}} =
               ToolSurface.execute("org_list_descendants", %{"org_id" => @slug_16}, %{})
    end

    test "a malformed context agent_id resolves to no agent rather than raising" do
      # load_agent/1 backs the memory tools' actor resolution. A 16-character
      # agent_id used to raise here; before THAT it would have been
      # hex-encoded into an invented actor id by file_delete_actor/1.
      assert {:error, _} =
               ToolSurface.execute("memory_view", %{"path" => "org/page/x.md"}, %{
                 agent_id: @slug_16
               })
    end
  end

  # ── stage_list: two entry points, one stated resolution rule ────────────
  #
  # Task 019fa609 stage 5. `stage_list` accepts `task_id` as well as
  # `plan_id`, which makes it a CONDITIONAL requirement and therefore takes it
  # out of `ToolArguments`' scope entirely — that gate is per-parameter and a
  # per-parameter gate cannot express "exactly one of these two". The check
  # moves into the handler, following the `skill.get` precedent.
  #
  # Every test here drives `ToolArguments.dispatch/3` rather than
  # `ToolSurface.execute/3`, because `dispatch/3` is the documented entry
  # point and is what both federation transports call. For this tool the two
  # are now equivalent (the gate finds nothing to enforce), and asserting at
  # the entry point is what keeps them honest if that ever stops being true.
  defp stage_list(args), do: ToolArguments.dispatch("stage_list", args, %{})

  defp plan_with_stage(task, attrs) do
    {:ok, plan} = Tasks.create_plan(Map.merge(%{task_id: task.id}, attrs))

    {:ok, _stage} =
      Tasks.create_stage(%{plan_id: plan.id, name: "Stage v#{plan.version}", position: 1})

    plan
  end

  defp planned_task(title \\ "Resolution task") do
    project = create_project()
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: title})
    task
  end

  describe "stage_list resolves a plan from either plan_id or task_id" do
    test "task_id resolves to the task's current approved plan" do
      task = planned_task()
      plan = plan_with_stage(task, %{status: "approved", version: 1})

      assert {:ok, [stage]} = stage_list(%{"task_id" => task.id})
      assert stage.name == "Stage v1"
      assert stage.plan_id == plan.id
    end

    test "a pending v2 does not shadow the approved v1, and rows say which plan answered" do
      # The disambiguation is already in the row: serialize_stage/1 emits
      # plan_id, so a caller who passed only task_id can still see which plan
      # the answer came from without a second call.
      task = planned_task()
      v1 = plan_with_stage(task, %{status: "approved", version: 1})
      v2 = plan_with_stage(task, %{status: "pending_review", version: 2})

      assert {:ok, [stage]} = stage_list(%{"task_id" => task.id})
      assert stage.plan_id == v1.id
      refute stage.plan_id == v2.id
      assert stage.name == "Stage v1"
    end

    test "a task whose only plan is unapproved is refused, not answered with []" do
      # The failure this replaces: an empty array is indistinguishable from
      # "this task has no stages", so a caller concludes the plan is empty
      # when in fact a v2 is sitting in review.
      task = planned_task()
      draft = plan_with_stage(task, %{status: "draft", version: 1})

      assert {:error, envelope} = stage_list(%{"task_id" => task.id})
      assert envelope.code == :no_current_plan
      assert envelope.recoverable == true
      assert envelope.suggestion =~ draft.id
      assert envelope.suggestion =~ "version 1"
      assert envelope.suggestion =~ "draft"
    end

    test "a task with no plan at all is refused with the same code and a different suggestion" do
      task = planned_task()

      assert {:error, envelope} = stage_list(%{"task_id" => task.id})
      assert envelope.code == :no_current_plan
      assert envelope.suggestion =~ "no plan"
      assert envelope.recoverable == true
    end

    test "a malformed task_id is refused rather than raising a cast error" do
      assert {:error, %{code: :no_current_plan}} = stage_list(%{"task_id" => @slug_16})
    end

    test "plan_id alone still answers exactly as it did before task_id existed" do
      task = planned_task()
      plan = plan_with_stage(task, %{status: "approved", version: 1})

      assert stage_list(%{"plan_id" => plan.id}) ==
               ToolSurface.execute("stage_list", %{"plan_id" => plan.id}, %{})

      assert {:ok, [stage]} = stage_list(%{"plan_id" => plan.id})
      assert stage.plan_id == plan.id
    end

    test "both arguments agreeing is accepted, and plan_id is what answers" do
      # Stated rule: when both are supplied and they agree, plan_id wins. It
      # is the more specific of the two — it can name a plan task_id would
      # never resolve to.
      task = planned_task()
      v1 = plan_with_stage(task, %{status: "approved", version: 1})
      v2 = plan_with_stage(task, %{status: "pending_review", version: 2})

      assert {:ok, [stage]} = stage_list(%{"plan_id" => v2.id, "task_id" => task.id})
      assert stage.plan_id == v2.id
      refute stage.plan_id == v1.id
    end

    test "both arguments disagreeing is refused, never silently resolved to one" do
      other = planned_task("Unrelated task")
      other_plan = plan_with_stage(other, %{status: "approved", version: 1})
      task = planned_task()
      _mine = plan_with_stage(task, %{status: "approved", version: 1})

      assert {:error, envelope} = stage_list(%{"plan_id" => other_plan.id, "task_id" => task.id})
      assert envelope.code == :plan_task_mismatch
      assert envelope.recoverable == true
      assert envelope.error =~ other_plan.id
      assert envelope.error =~ task.id
    end

    test "a plan_id naming no plan at all is the same mismatch, with its own message" do
      task = planned_task()
      _plan = plan_with_stage(task, %{status: "approved", version: 1})
      absent = Ecto.UUID.generate()

      assert {:error, envelope} = stage_list(%{"plan_id" => absent, "task_id" => task.id})
      assert envelope.code == :plan_task_mismatch
      assert envelope.error =~ "no plan"

      # A malformed plan_id resolves the same way rather than raising, which
      # is the point of checking the pair through a lookup that cannot cast.
      assert {:error, %{code: :plan_task_mismatch}} =
               stage_list(%{"plan_id" => @slug_16, "task_id" => task.id})
    end

    test "neither argument is refused with a code naming both acceptable arguments" do
      assert {:error, envelope} = stage_list(%{})
      assert envelope.code == :missing_plan_reference
      assert envelope.error =~ "plan_id"
      assert envelope.error =~ "task_id"
      assert envelope.recoverable == true
      assert envelope.suggestion =~ "tools/list"
    end

    test "a blank or whitespace-only argument counts as absent, matching the gate" do
      for args <- [
            %{"plan_id" => "   "},
            %{"task_id" => ""},
            %{"plan_id" => nil, "task_id" => nil},
            %{"plan_id" => "  ", "task_id" => "  "}
          ] do
        assert {:error, %{code: :missing_plan_reference}} = stage_list(args),
               "#{inspect(args)} names no plan and must be refused, not cast into a query"
      end
    end
  end

  describe "stage_list's declared contract matches what it does" do
    test "neither parameter is declared required, so the generic gate does not cover it" do
      # This is the consequence the stage brief insisted be stated: the tool
      # that motivated the ticket ends up outside the mechanism the ticket
      # asked for, because `plan_id` XOR `task_id` is not a per-parameter
      # requirement. `ToolArguments` finding nothing to enforce is CORRECT,
      # and the handler's own refusal is what covers the tool.
      assert ToolArguments.required_params("stage_list") == []
      assert ToolArguments.validate("stage_list", %{}) == :ok

      tool = Enum.find(ToolSurface.tool_definitions(), &(&1.name == "stage_list"))
      assert tool.parameters.plan_id.required == false
      assert tool.parameters.task_id.required == false
    end

    test "the description states both entry points and the resolution rule" do
      tool = Enum.find(ToolSurface.tool_definitions(), &(&1.name == "stage_list"))

      # The old description — "List all stages for a plan, ordered by
      # position, with validations preloaded." — warned nobody off, which is
      # why the ticket's author reached for the wrong tool twice.
      assert tool.description =~ "task_id"
      assert tool.description =~ "plan_id"
      assert tool.limitations =~ "Exactly one of `plan_id` or `task_id` is required"
    end

    test "the limitations prose names exactly the refusal codes the clause emits" do
      tool = Enum.find(ToolSurface.tool_definitions(), &(&1.name == "stage_list"))
      codes = ToolSurface.stage_list_error_codes()

      documented =
        codes
        |> Enum.filter(&(tool.limitations =~ "`#{&1}`"))
        |> MapSet.new()

      assert documented == MapSet.new(codes),
             """
             Every code the clause can emit must be named in `limitations`.
             Missing: #{inspect(MapSet.difference(MapSet.new(codes), documented))}
             """
    end

    test "the observed refusal code set is exactly the documented one" do
      # The guard that makes the prose above load-bearing rather than
      # decorative: drive every refusal and compare the sets. A code emitted
      # but undeclared, or declared but unreachable, fails here.
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Code set task"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "draft", version: 1})

      {:ok, other_task} = Tasks.create_task(%{project_id: project.id, title: "Other"})

      {:ok, other_plan} =
        Tasks.create_plan(%{task_id: other_task.id, status: "approved", version: 1})

      cases = [
        {%{}, :missing_plan_reference},
        {%{"task_id" => task.id}, :no_current_plan},
        {%{"plan_id" => other_plan.id, "task_id" => task.id}, :plan_task_mismatch}
      ]

      observed =
        for {args, expected} <- cases, into: MapSet.new() do
          assert {:error, envelope} = ToolArguments.dispatch("stage_list", args, %{}),
                 "expected #{inspect(args)} to be refused"

          assert envelope.code == expected, "for #{inspect(args)}: #{inspect(envelope)}"
          assert envelope.recoverable == true
          envelope.code
        end

      # Referenced so the draft plan above is unmistakably the no_current_plan
      # fixture rather than an unused binding.
      assert plan.status == "draft"

      assert observed == MapSet.new(ToolSurface.stage_list_error_codes()),
             """
             Emitted-but-undeclared: #{inspect(MapSet.difference(observed, MapSet.new(ToolSurface.stage_list_error_codes())))}
             Declared-but-unexercised: #{inspect(MapSet.difference(MapSet.new(ToolSurface.stage_list_error_codes()), observed))}
             """
    end
  end

  # ── design_critique_request (task 019fe844 stage 3) ──────────────────────
  #
  # The tool exists because the reviewer dispatch template told agents to
  # "obtain Saru's design review" with no mechanism that could succeed. A
  # test asserting only that the tool NAME is registered would pass against
  # a clause that returns `{:error, :not_implemented}`, so the tests below
  # assert on the outbound bytes and on the review item's CONTENT.

  describe "design_critique_request — bundle placement" do
    test "is on the review bundle and only there" do
      review = ToolSurface.list_tools(["review"]) |> Enum.map(& &1.name)
      assert "design_critique_request" in review

      for bundle <- ToolSurface.all_bundles(), bundle != "review" do
        refute "design_critique_request" in Enum.map(ToolSurface.list_tools([bundle]), & &1.name),
               "design_critique_request leaked into the #{bundle} bundle"
      end
    end

    test "declares canvas_id required and documents the synchronous return" do
      tool =
        ToolSurface.list_tools(["review"])
        |> Enum.find(&(&1.name == "design_critique_request"))

      assert tool.parameters.canvas_id.required
      refute tool.parameters.review_request_id.required
      assert tool.when_to_use =~ "SYNCHRONOUSLY" or tool.when_to_use =~ "synchronous"
      assert tool.returns =~ "review_item_id"
    end
  end

  describe "design_critique_request — execute/3" do
    setup do
      {:ok, _} = Application.ensure_all_started(:req)

      Application.put_env(
        :platform,
        :external_agents_dispatcher_req_client,
        Req.new(plug: {Req.Test, :tool_surface_design_critique})
      )

      on_exit(fn ->
        Application.delete_env(:platform, :external_agents_dispatcher_req_client)
      end)

      :ok
    end

    test "returns the verdict and lands it on the supplied review request" do
      %{canvas: canvas, task: task} = critique_wiring()
      request = critique_review_request!(task)
      critique_stub!(critique_issues_json())

      assert {:ok, result} =
               ToolSurface.execute(
                 "design_critique_request",
                 %{
                   "canvas_id" => canvas.id,
                   "task_id" => task.id,
                   "review_request_id" => request.id,
                   "note" => "look at the submit affordance"
                 },
                 %{agent_id: Ecto.UUID.generate()}
               )

      assert [%{"severity" => "high"} | _] = result.issues
      refute result.unparseable?
      assert is_binary(result.review_item_id)

      # Proves the canvas actually reached the model rather than an empty
      # context being billed.
      assert_receive {:outbound, body}
      user = Enum.find(body["messages"], &(&1["role"] == "user"))["content"]
      assert user =~ "Submit button, grey on grey"
      assert user =~ "look at the submit affordance"

      reloaded = Platform.Tasks.ReviewRequests.get_review_request(request.id)
      item = Enum.find(reloaded.items, &(&1.label =~ "Saru"))
      refute is_nil(item), "no Saru-labelled item landed on the review request"
      assert item.content =~ "contrast ratio 2.1:1"
      assert reloaded.status == "pending"
    end

    test "an unresolvable canvas is a recoverable structured error, not a raise" do
      critique_wiring()
      critique_stub!(critique_issues_json())

      assert {:error, envelope} =
               ToolSurface.execute(
                 "design_critique_request",
                 %{"canvas_id" => Ecto.UUID.generate()},
                 %{agent_id: Ecto.UUID.generate()}
               )

      assert envelope.recoverable == true
      assert envelope.suggestion =~ "canvas_id"
      refute_receive {:outbound, _}
    end

    test "an unfilled Designer role is reported as NOT recoverable" do
      %{canvas: canvas} = critique_wiring(assign_role?: false)
      critique_stub!(critique_issues_json())

      assert {:error, envelope} =
               ToolSurface.execute(
                 "design_critique_request",
                 %{"canvas_id" => canvas.id},
                 %{agent_id: Ecto.UUID.generate()}
               )

      # A caller told `recoverable: true` here retries a call that cannot
      # ever succeed until a human assigns the role.
      assert envelope.recoverable == false
      assert envelope.suggestion =~ "Designer"
      refute_receive {:outbound, _}
    end

    # Task 01a0ac54 stage 2 sweep. `space_id` is transport-reserved, so it
    # reaches this tool as `context.space_id`, and `Critique.land_verdict/2`
    # posts the verdict there via `ExecutionSpace.post_engagement/3`. The
    # positive control shows that landing happens for a participant, so the
    # refusal test's empty space is the gate, not a landing that never runs.
    test "lands the critique in a named space the caller participates in" do
      %{canvas: canvas} = critique_wiring()
      critique_stub!(critique_issues_json())
      agent = create_agent()
      target = create_space()

      participant =
        create_participant(target.id, %{participant_type: "agent", participant_id: agent.id})

      assert {:ok, _result} =
               ToolSurface.execute(
                 "design_critique_request",
                 %{"canvas_id" => canvas.id},
                 %{space_id: target.id, agent_id: agent.id, agent_participant_id: participant.id}
               )

      assert Enum.any?(
               Chat.list_messages(target.id, limit: 10),
               &(&1.content =~ "contrast ratio 2.1:1")
             )
    end

    test "refuses a named space the caller does not participate in, before dispatch" do
      %{canvas: canvas} = critique_wiring()
      critique_stub!(critique_issues_json())
      agent = create_agent()
      foreign = create_space()
      create_participant(foreign.id)

      assert {:error, error} =
               ToolSurface.execute(
                 "design_critique_request",
                 %{"canvas_id" => canvas.id},
                 %{space_id: foreign.id, agent_id: agent.id, agent_participant_id: nil}
               )

      assert error.error == "Access denied: agent is not a participant in space #{foreign.id}"
      assert error.recoverable == false
      refute_receive {:outbound, _}
      assert Chat.list_messages(foreign.id, limit: 10) == []
    end

    # Task 01a0cbe0: a non-nil context participant is verified against
    # `context.space_id`, not trusted. The positive control is "lands the
    # critique in a named space the caller participates in" above.
    test "refuses a context participant that belongs to another space, before dispatch" do
      %{canvas: canvas} = critique_wiring()
      critique_stub!(critique_issues_json())
      agent = create_agent()
      good = create_space()
      foreign = create_space()
      create_participant(foreign.id)

      good_participant =
        create_participant(good.id, %{participant_type: "agent", participant_id: agent.id})

      assert {:error, error} =
               ToolArguments.dispatch(
                 "design_critique_request",
                 %{"canvas_id" => canvas.id},
                 %{
                   space_id: foreign.id,
                   agent_id: agent.id,
                   agent_participant_id: good_participant.id
                 }
               )

      assert error.error == "Access denied: agent is not a participant in space #{foreign.id}"
      assert error.recoverable == false
      refute_receive {:outbound, _}
      assert Chat.list_messages(foreign.id, limit: 10) == []
    end
  end

  describe "the reviewer dispatch template names a mechanism that exists" do
    test "dispatch.in_review points at design_critique_request and keeps the escape hatch" do
      body =
        Platform.Orchestration.PromptTemplates.default_templates()
        |> Enum.find(&(&1.slug == "dispatch.in_review"))
        |> Map.fetch!(:content)

      assert body =~ "design_critique_request"
      refute body =~ "@vega"

      # The escape hatch is a FALLBACK from a mechanism now, but it must
      # still be there — an agent that cannot obtain the critique still has
      # to be able to file the gate and say so.
      assert body =~ "create the review request anyway and note that design review is missing"
      assert body =~ "never replaces human approval"

      # The tool must actually be reachable by an agent holding this
      # template's bundle, or the instruction is the same defect again.
      assert "design_critique_request" in Enum.map(ToolSurface.list_tools(["review"]), & &1.name)
    end
  end

  # ── design_critique_request fixtures ─────────────────────────────────────

  defp critique_wiring(opts \\ []) do
    [spec] = Platform.Responsibilities.Handlers.DesignCritique.register()
    {:ok, row} = Platform.Responsibilities.upsert_by_key(spec)

    project = create_project()

    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "Critique the checkout surface"})

    space = create_space()

    {:ok, participant} =
      Platform.Orchestration.ExecutionSpace.ensure_system_participant(space.id)

    {:ok, canvas} =
      Chat.create_canvas(%{
        space_id: space.id,
        created_by: participant.id,
        title: "Checkout screen",
        document: %{
          "version" => 1,
          "revision" => 1,
          "root" => %{
            "id" => "root",
            "type" => "stack",
            "children" => [
              %{
                "id" => "n",
                "type" => "markdown",
                "props" => %{"content" => "Submit button, grey on grey"}
              }
            ]
          }
        }
      })

    if Keyword.get(opts, :assign_role?, true), do: critique_designer!(row.key)

    %{task: task, space: space, canvas: canvas}
  end

  defp critique_designer!(responsibility_key) do
    Repo.insert!(
      %Platform.Roles.Role{
        key: "designer",
        name: "Designer",
        description: "test",
        icon: "hero-swatch"
      },
      on_conflict: :nothing,
      conflict_target: :key
    )

    %Platform.Roles.RoleResponsibility{}
    |> Platform.Roles.RoleResponsibility.changeset(%{
      role_key: "designer",
      responsibility_key: responsibility_key
    })
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:role_key, :responsibility_key])

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "saru-tool-surface-#{System.unique_integer([:positive])}",
        name: "Saru Tool Surface Test",
        status: "active",
        kind: "external",
        endpoint_kind: "openai_compat",
        base_url: "https://api.example.test",
        model: "test-model",
        workspace_id: nil
      })
      |> Repo.insert!()

    :ok = Platform.ExternalAgents.EphemeralCredentials.put(agent.id, "sk-tool-surface-test")
    on_exit(fn -> Platform.ExternalAgents.EphemeralCredentials.delete(agent.id) end)

    {:ok, _} = Platform.Roles.assign_role("designer", agent.id)

    agent
  end

  defp critique_review_request!(task) do
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "UI"})
    {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

    {:ok, request} =
      Platform.Tasks.ReviewRequests.create_review_request(%{
        validation_id: validation.id,
        task_id: task.id,
        items: [%{label: "Desktop screenshot", content: "evidence"}]
      })

    request
  end

  defp critique_stub!(content) do
    test_pid = self()

    Req.Test.stub(:tool_surface_design_critique, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:outbound, Jason.decode!(raw)})

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}]
      })
    end)

    :ok
  end

  defp critique_issues_json do
    Jason.encode!(%{
      "issues" => [
        %{
          "severity" => "high",
          "location" => "Submit button",
          "issue" => "The submit button sits at contrast ratio 2.1:1 against its background.",
          "suggestion" => "Darken the fill to at least 4.5:1."
        }
      ]
    })
  end

  describe "report_blocker cost" do
    alias Platform.Orchestration.RuntimeEvent

    defp blocker_stage do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Costly blocker"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, name: "Build", position: 1})
      {task, stage}
    end

    defp full_blocker_args(task, stage, overrides \\ %{}) do
      Map.merge(
        %{
          "task_id" => task.id,
          "stage_id" => stage.id,
          "description" => "mix test fails on a migration",
          "needs_human" => false,
          "attempts" => [
            "ran mix test: fails on migration 20260808",
            "read the ADR: no answer",
            "reset the test DB: same failure"
          ],
          "memory_ref" => "org/page/identity.md",
          "unblock_action" => "Rowan picks A or B",
          "category" => "product"
        },
        overrides
      )
    end

    defp blocker_context, do: %{runtime_id: "runtime:test", agent_id: "agent:cost"}

    test "two attempts are refused and nothing is recorded" do
      {task, stage} = blocker_stage()
      before = Repo.aggregate(RuntimeEvent, :count)

      args =
        full_blocker_args(task, stage, %{
          "attempts" => ["ran mix test, failed", "read the ADR, no answer"]
        })

      assert {:error, %{error: msg, recoverable: true}} =
               ToolSurface.execute("report_blocker", args, blocker_context())

      assert msg =~ "report_blocker refused"
      assert msg =~ "attempts"
      assert Repo.aggregate(RuntimeEvent, :count) == before
    end

    test "duplicate or blank attempts do not count as distinct" do
      {task, stage} = blocker_stage()

      args =
        full_blocker_args(task, stage, %{
          "attempts" => ["ran mix test", "ran mix test", "  ", "read the ADR"]
        })

      assert {:error, %{error: msg}} =
               ToolSurface.execute("report_blocker", args, blocker_context())

      assert msg =~ "attempts"
    end

    test "missing memory_ref, unblock_action and category are all named" do
      {task, stage} = blocker_stage()
      before = Repo.aggregate(RuntimeEvent, :count)

      args =
        task
        |> full_blocker_args(stage)
        |> Map.drop(["memory_ref", "unblock_action", "category"])

      assert {:error, %{error: msg}} =
               ToolSurface.execute("report_blocker", args, blocker_context())

      assert msg =~ "memory_ref"
      assert msg =~ "unblock_action"
      assert msg =~ "category"
      refute msg =~ "attempts"
      assert Repo.aggregate(RuntimeEvent, :count) == before
    end

    test "infra with needs_human is refused and nothing is recorded" do
      {task, stage} = blocker_stage()
      before = Repo.aggregate(RuntimeEvent, :count)

      args = full_blocker_args(task, stage, %{"category" => "infra", "needs_human" => true})

      assert {:error, %{error: msg, recoverable: true}} =
               ToolSurface.execute("report_blocker", args, blocker_context())

      assert msg =~ "@[Dalton]"
      assert msg =~ "infra"
      assert Repo.aggregate(RuntimeEvent, :count) == before
    end

    test "full valid args record the event with the four new payload keys" do
      {task, stage} = blocker_stage()
      args = full_blocker_args(task, stage)

      assert {:ok, %{blocked: true, event_id: event_id}} =
               ToolSurface.execute("report_blocker", args, blocker_context())

      event = Repo.get!(RuntimeEvent, event_id)
      assert event.event_type == "execution.blocked"
      assert event.payload["attempts"] == args["attempts"]
      assert event.payload["memory_ref"] == "org/page/identity.md"
      assert event.payload["unblock_action"] == "Rowan picks A or B"
      assert event.payload["category"] == "product"
      assert event.payload["reported_by"] == "agent:cost"
    end

    test "infra without needs_human is accepted" do
      {task, stage} = blocker_stage()
      args = full_blocker_args(task, stage, %{"category" => "infra", "needs_human" => false})

      assert {:ok, %{blocked: true}} =
               ToolSurface.execute("report_blocker", args, blocker_context())
    end
  end
end
