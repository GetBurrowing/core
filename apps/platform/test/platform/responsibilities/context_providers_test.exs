defmodule Platform.Responsibilities.ContextProvidersTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.ContextProviders` (ADR-0041 M8
  stage 1).

  Covers each slot's happy path, the missing-row fallbacks that prevent
  Hal's first nightly on a fresh org from crashing, the
  `:meeting_transcript` error tuple, and a round-trip that materialises
  all three slots into a single keyed map.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Meetings
  alias Platform.Meetings.SummaryPrompt
  alias Platform.Org.Context, as: OrgContext
  alias Platform.Org.WikiPage
  alias Platform.Repo
  alias Platform.Responsibilities.ContextProviders
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema

  import Ecto.Query

  defp drop_org_identity_files do
    Repo.delete_all(
      from(p in WikiPage,
        where:
          p.file_key in [
            "ORG_IDENTITY.md",
            "org/identity.md",
            "org/page/identity.md"
          ]
      )
    )
  end

  defp post_message do
    slug = "ctxprov-#{System.unique_integer([:positive])}"

    {:ok, space} =
      Chat.create_space(%{name: "Ctx Prov #{slug}", slug: slug, kind: "channel"})

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Ctx Author",
        joined_at: DateTime.utc_now()
      })

    {:ok, message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: "context-provider test message"
      })

    message
  end

  defp sample_segments do
    [
      %{
        "participant_identity" => "user_1",
        "speaker_name" => "Harper",
        "text" => "Helios milestone is on track.",
        "start_time" => 0,
        "end_time" => 3000,
        "final" => true
      },
      %{
        "participant_identity" => "user_2",
        "speaker_name" => "Mira Chen",
        "text" => "Let's land the rollout this week.",
        "start_time" => 3500,
        "end_time" => 6000,
        "final" => true
      }
    ]
  end

  describe "gather_context/2 — :org_identity" do
    test "returns missing? true and empty content when ORG_IDENTITY.md isn't seeded" do
      # The test DB may have a seeded ORG_IDENTITY.md (or its path-style
      # alias `org/identity.md` / `org/page/identity.md`) — clear every
      # variant so the gather actually exercises the missing-file branch.
      drop_org_identity_files()

      assert {:ok, %{org_identity: payload}} = ContextProviders.gather_context(:org_identity, [])

      assert payload.missing? == true
      assert payload.content == ""
      assert payload.version == nil
    end

    test "returns the file body, version, and missing? false when seeded" do
      {:ok, page} =
        OrgContext.upsert_file(%{
          file_key: "ORG_IDENTITY.md",
          content: "# Mission\nBuild Helios.",
          updated_by: Ecto.UUID.generate()
        })

      assert {:ok, %{org_identity: payload}} = ContextProviders.gather_context(:org_identity, [])

      assert payload.missing? == false
      assert payload.content == "# Mission\nBuild Helios."
      assert payload.version == page.version
    end
  end

  describe "gather_context/2 — :recent_journal" do
    test "returns an empty entries_by_date list and total 0 on an empty wiki" do
      assert {:ok, %{recent_journal: payload}} =
               ContextProviders.gather_context(:recent_journal, [])

      assert payload.days == 7
      assert payload.entries_by_date == []
      assert payload.total == 0
    end

    test "groups entries by date and counts the total" do
      today = Date.utc_today()

      {:ok, _entry} =
        OrgContext.append_memory_entry(%{
          content: "Decision: ship Helios v1 by Friday.",
          date: today
        })

      assert {:ok, %{recent_journal: payload}} =
               ContextProviders.gather_context(:recent_journal, [])

      assert payload.total >= 1
      assert is_list(payload.entries_by_date)
    end

    test "honours the :workspace_id opt by filtering recent_memory accordingly" do
      ws_id = Ecto.UUID.generate()
      today = Date.utc_today()

      {:ok, _global_entry} =
        OrgContext.append_memory_entry(%{
          content: "Unscoped entry",
          date: today
        })

      {:ok, _scoped_entry} =
        OrgContext.append_memory_entry(%{
          content: "Workspace-scoped entry",
          date: today,
          workspace_id: ws_id
        })

      # Scoped query should ONLY surface the workspace-scoped entry
      assert {:ok, %{recent_journal: scoped}} =
               ContextProviders.gather_context(:recent_journal, workspace_id: ws_id)

      flattened = scoped.entries_by_date |> Enum.flat_map(fn {_d, entries} -> entries end)
      assert Enum.all?(flattened, fn entry -> entry.workspace_id == ws_id end)
      assert Enum.any?(flattened, fn entry -> entry.content == "Workspace-scoped entry" end)
    end

    test "accepts a map of opts as well as a keyword list" do
      assert {:ok, %{recent_journal: payload}} =
               ContextProviders.gather_context(:recent_journal, %{days: 3})

      assert payload.days == 3
    end
  end

  describe "gather_context/2 — :meeting_transcript" do
    test "returns {:error, :missing_transcript_id} when opts has no transcript_id" do
      assert {:error, :missing_transcript_id} =
               ContextProviders.gather_context(:meeting_transcript, [])
    end

    test "returns {:error, :not_found} for an unknown transcript_id" do
      assert {:error, :not_found} =
               ContextProviders.gather_context(:meeting_transcript,
                 transcript_id: Ecto.UUID.generate()
               )
    end

    test "loads a real transcript and returns formatted_text + counts" do
      {:ok, transcript} =
        Meetings.create_transcript(%{
          room_id: Ecto.UUID.generate(),
          space_id: Ecto.UUID.generate(),
          segments: sample_segments()
        })

      assert {:ok, %{meeting_transcript: payload}} =
               ContextProviders.gather_context(:meeting_transcript,
                 transcript_id: transcript.id
               )

      assert payload.transcript_id == transcript.id
      assert payload.segment_count == 2
      assert payload.duration_ms == 6000
      # formatted_text must byte-for-byte match SummaryPrompt.format_segments/1
      # so handlers stay in sync with the canonical formatting.
      assert payload.formatted_text == SummaryPrompt.format_segments(sample_segments())
      assert payload.formatted_text =~ "Harper"
      assert payload.formatted_text =~ "Mira Chen"
    end

    test "handles a transcript with no segments without crashing" do
      {:ok, transcript} =
        Meetings.create_transcript(%{
          room_id: Ecto.UUID.generate(),
          space_id: Ecto.UUID.generate(),
          segments: []
        })

      assert {:ok, %{meeting_transcript: payload}} =
               ContextProviders.gather_context(:meeting_transcript,
                 transcript_id: transcript.id
               )

      assert payload.segment_count == 0
      assert payload.duration_ms == 0
      assert payload.formatted_text == ""
    end
  end

  # Slots ported in from ContextGatherer when the two materialisers
  # collapsed onto this module. The batch adapter degrades every tuple
  # below to `nil`; these assert the reason it degrades from, which is
  # the whole point of the port.
  describe "gather_context/2 — :current_message" do
    test "returns {:error, :missing_message_id} when opts has no message_id" do
      assert {:error, :missing_message_id} =
               ContextProviders.gather_context(:current_message, [])
    end

    test "returns {:error, :invalid_message_id} for a non-binary id" do
      assert {:error, :invalid_message_id} =
               ContextProviders.gather_context(:current_message, message_id: 42)
    end

    test "returns {:error, :not_found} for an unknown message id" do
      assert {:error, :not_found} =
               ContextProviders.gather_context(:current_message,
                 message_id: Ecto.UUID.generate()
               )
    end

    test "loads a real message and returns it under :current_message" do
      message = post_message()

      assert {:ok, %{current_message: %Message{id: id}}} =
               ContextProviders.gather_context(:current_message, message_id: message.id)

      assert id == message.id
    end

    test "reads a string-keyed message_id out of a raw trigger_meta map" do
      message = post_message()

      assert {:ok, %{current_message: %Message{id: id}}} =
               ContextProviders.gather_context(:current_message, %{
                 "message_id" => message.id
               })

      assert id == message.id
    end

    test "an unconvertible sibling key does not blank the slot's real id" do
      # The router hands `trigger_meta` through verbatim and it routinely
      # carries string keys that were never atoms. Per-key coercion means
      # the junk key is dropped, not the whole opts list.
      message = post_message()

      bogus = "never_an_atom_#{System.unique_integer([:positive])}"

      assert {:ok, %{current_message: %Message{id: id}}} =
               ContextProviders.gather_context(:current_message, %{
                 "message_id" => message.id,
                 bogus => "junk"
               })

      assert id == message.id
    end
  end

  describe "gather_context/2 — :current_meeting" do
    test "returns {:error, :missing_meeting_id} when opts has no meeting_id" do
      assert {:error, :missing_meeting_id} =
               ContextProviders.gather_context(:current_meeting, [])
    end

    test "returns {:error, :not_found} for an unknown meeting id" do
      assert {:error, :not_found} =
               ContextProviders.gather_context(:current_meeting,
                 meeting_id: Ecto.UUID.generate()
               )
    end
  end

  describe "gather_context/2 — :trigger_payload" do
    test "echoes the payload straight through" do
      payload = %{"event" => "test", "value" => 42}

      assert {:ok, %{trigger_payload: ^payload}} =
               ContextProviders.gather_context(:trigger_payload, %{payload: payload})
    end

    test "tolerates a string-keyed payload" do
      payload = %{"hello" => "world"}

      assert {:ok, %{trigger_payload: ^payload}} =
               ContextProviders.gather_context(:trigger_payload, %{"payload" => payload})
    end

    test "returns {:error, :missing_payload} when the trigger carried none" do
      assert {:error, :missing_payload} =
               ContextProviders.gather_context(:trigger_payload, %{})
    end
  end

  # ── :plan_payload ─────────────────────────────────────────────────────────
  #
  # The architecture pass runs strictly AFTER plan submission (ADR-0046),
  # so "no plan resolvable" is a wiring bug rather than an empty state —
  # this slot refuses instead of returning a tolerant empty payload, and
  # the Router's context-refusal arm turns that into a stopped dispatch.

  defp plan_project do
    {:ok, project} =
      Tasks.create_project(%{name: "Ctx Plan Project #{System.unique_integer([:positive])}"})

    project
  end

  defp plan_task(project_id, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        Map.merge(
          %{
            project_id: project_id,
            title: "Plan Payload Task",
            description: "Give the architect the intent the plan was written against.",
            status: "planning"
          },
          attrs
        )
      )

    task
  end

  defp bare_plan(task_id, status \\ "pending_review") do
    {:ok, plan} = Tasks.create_plan(%{task_id: task_id})

    plan
    |> Ecto.Changeset.change(status: status)
    |> Repo.update!()
  end

  defp add_stage(plan_id, position, attrs \\ %{}) do
    {:ok, stage} =
      Tasks.create_stage(
        Map.merge(
          %{
            plan_id: plan_id,
            position: position,
            name: "Stage #{position}",
            description: "Stage #{position} description",
            status: "pending"
          },
          attrs
        )
      )

    stage
  end

  defp add_validation(stage_id, kind, attrs \\ %{}) do
    {:ok, validation} =
      Tasks.create_validation(Map.merge(%{stage_id: stage_id, kind: kind}, attrs))

    validation
  end

  defp three_stage_plan do
    project = plan_project()
    task = plan_task(project.id)
    plan = bare_plan(task.id)

    # Inserted out of order on purpose — the slot sorts by position.
    for position <- [3, 1, 2], do: add_stage(plan.id, position)

    %{project: project, task: task, plan: plan}
  end

  describe "gather_context/2 — :plan_payload refusals" do
    # PAIRED POSITIVE CONTROL for the three refusal assertions below. A
    # resolver that errored unconditionally would pass all of them; this
    # one test is what makes them observations rather than a tautology.
    test "resolves a real plan — the control the refusals are measured against" do
      %{plan: plan} = three_stage_plan()

      assert {:ok, %{plan_payload: %{stage_count: 3}}} =
               ContextProviders.gather_context(:plan_payload, %{plan: plan})
    end

    test "returns {:error, :no_plan_payload} for an empty context" do
      assert {:error, :no_plan_payload} = ContextProviders.gather_context(:plan_payload, %{})
    end

    test "returns {:error, :no_plan_payload} for a plan_id that resolves to nothing" do
      assert {:error, :no_plan_payload} =
               ContextProviders.gather_context(:plan_payload, %{plan_id: Ecto.UUID.generate()})
    end

    test "returns {:error, :no_plan_payload} for a task that has no plans" do
      task = plan_task(plan_project().id)

      assert {:error, :no_plan_payload} =
               ContextProviders.gather_context(:plan_payload, %{task_id: task.id})
    end

    test "returns {:error, :no_plan_payload} when every plan on the task is dead" do
      task = plan_task(plan_project().id)
      _superseded = bare_plan(task.id, "superseded")
      _rejected = bare_plan(task.id, "rejected")

      assert {:error, :no_plan_payload} =
               ContextProviders.gather_context(:plan_payload, %{task_id: task.id})
    end

    test "a malformed plan_id refuses rather than raising" do
      assert {:error, :no_plan_payload} =
               ContextProviders.gather_context(:plan_payload, %{plan_id: "not-a-uuid"})
    end
  end

  describe "gather_context/2 — :plan_payload resolution" do
    test "resolves from a plan_id, including a string-keyed one" do
      %{plan: plan} = three_stage_plan()

      assert {:ok, %{plan_payload: from_atom}} =
               ContextProviders.gather_context(:plan_payload, %{plan_id: plan.id})

      assert {:ok, %{plan_payload: from_string}} =
               ContextProviders.gather_context(:plan_payload, %{"plan_id" => plan.id})

      assert from_atom.plan_id == plan.id
      assert from_string.plan_id == plan.id
    end

    test "resolves the latest non-superseded/non-rejected plan from a bare task_id" do
      task = plan_task(plan_project().id)

      superseded = bare_plan(task.id, "superseded")
      live = bare_plan(task.id, "approved")

      assert live.version > superseded.version

      assert {:ok, %{plan_payload: payload}} =
               ContextProviders.gather_context(:plan_payload, %{task_id: task.id})

      assert payload.plan_id == live.id
      assert payload.plan_status == "approved"
    end

    test "carries the task intent the plan was written against" do
      project = plan_project()
      task = plan_task(project.id, %{title: "Wire the thing", description: "Because ADR-0046."})
      plan = bare_plan(task.id)

      assert {:ok, %{plan_payload: payload}} =
               ContextProviders.gather_context(:plan_payload, %{plan: plan})

      assert payload.task_id == task.id
      assert payload.task_title == "Wire the thing"
      assert payload.task_description == "Because ADR-0046."
      assert payload.task_status == "planning"
      assert payload.project_id == project.id
      assert payload.plan_version == plan.version
      assert Map.has_key?(payload, :epic_id)
      assert Map.has_key?(payload, :stack_id)
    end

    test "sorts stages by position and reports stage_count" do
      %{plan: plan} = three_stage_plan()

      assert {:ok, %{plan_payload: payload}} =
               ContextProviders.gather_context(:plan_payload, %{plan: plan})

      assert payload.stage_count == 3
      assert Enum.map(payload.stages, & &1.position) == [1, 2, 3]
    end

    test "truncates the task description at 1200 and stage descriptions at 600" do
      project = plan_project()
      task = plan_task(project.id, %{description: String.duplicate("t", 5_000)})
      plan = bare_plan(task.id)
      add_stage(plan.id, 1, %{description: String.duplicate("s", 5_000)})

      assert {:ok, %{plan_payload: payload}} =
               ContextProviders.gather_context(:plan_payload, %{plan: plan})

      assert String.length(payload.task_description) == 1201
      assert String.ends_with?(payload.task_description, "…")

      [stage] = payload.stages
      assert String.length(stage.description) == 601
      assert String.ends_with?(stage.description, "…")
    end
  end

  describe "gather_context/2 — :plan_payload validation gates" do
    setup do
      project = plan_project()
      task = plan_task(project.id)
      plan = bare_plan(task.id)
      stage = add_stage(plan.id, 1, %{name: "Gated Stage", status: "running"})

      add_validation(stage.id, "test_pass")
      add_validation(stage.id, "manual_approval")

      add_validation(stage.id, "e2e_behavior", %{
        evaluation_payload: %{
          "setup" => "seed a plan with three stages",
          "actions" => "call gather_context/2 with an empty map",
          "expected" => String.duplicate("e", 500)
        }
      })

      _ungated = add_stage(plan.id, 2, %{name: "Ungated Stage"})

      %{plan: plan, stage: stage}
    end

    test "surfaces every validation kind on the stage", %{plan: plan} do
      assert {:ok, %{plan_payload: payload}} =
               ContextProviders.gather_context(:plan_payload, %{plan: plan})

      [gated, ungated] = payload.stages

      kinds = Enum.map(gated.validations, & &1.kind)
      assert "test_pass" in kinds
      assert "manual_approval" in kinds
      assert "e2e_behavior" in kinds
      assert Enum.all?(gated.validations, &(&1.status == "pending"))

      assert gated.status == "running"
      assert ungated.validations == []
      assert ungated.e2e_expected == []
    end

    test "carries the e2e `expected` truncated to 200 and never setup/actions", %{plan: plan} do
      assert {:ok, %{plan_payload: payload}} =
               ContextProviders.gather_context(:plan_payload, %{plan: plan})

      [gated | _] = payload.stages

      assert [expected] = gated.e2e_expected
      assert String.length(expected) == 201
      assert String.ends_with?(expected, "…")

      serialised = inspect(payload, limit: :infinity, printable_limit: :infinity)
      refute serialised =~ "seed a plan with three stages"
      refute serialised =~ "call gather_context/2 with an empty map"
    end
  end

  # ── :sibling_tasks ─────────────────────────────────────────────────────────
  #
  # Tasks in these blocks are built with `Repo.insert!` rather than
  # `Tasks.create_task/1` on purpose. Every context-level task write
  # broadcasts to the singleton `TaskRouterWatcher`, which evaluates
  # from a process that does not own this test's sandbox connection —
  # producing failures indistinguishable from the known `TaskRouter`
  # flake cluster (filed as 019fa003-091a). The context function is not
  # what's under test here; the slot is.

  defp insert_task!(project_id, attrs) do
    now = DateTime.utc_now()

    %TaskSchema{}
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          project_id: project_id,
          title: "Sibling #{System.unique_integer([:positive])}",
          status: "in_progress",
          inserted_at: now,
          updated_at: now
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp insert_stack!(project_id) do
    slug = "ctx-siblings-#{System.unique_integer([:positive])}"

    {:ok, stack} =
      Tasks.Stacks.create_stack(%{
        project_id: project_id,
        slug: slug,
        name: "Ctx Siblings #{slug}",
        rollup_branch: "stack/#{slug}"
      })

    stack
  end

  defp insert_epic!(project_id) do
    {:ok, epic} =
      Tasks.create_epic(%{
        project_id: project_id,
        name: "Ctx Siblings Epic #{System.unique_integer([:positive])}"
      })

    epic
  end

  # An in-flight project task carrying a live plan — i.e. one that the
  # project-window tier is supposed to surface.
  defp planned_task!(project_id, attrs) do
    task = insert_task!(project_id, attrs)
    _plan = bare_plan(task.id, "pending_review")
    task
  end

  defp siblings_for(task_id) do
    assert {:ok, %{sibling_tasks: payload}} =
             ContextProviders.gather_context(:sibling_tasks, %{task_id: task_id})

    payload
  end

  describe "gather_context/2 — :sibling_tasks is optional, never a refusal" do
    # The required/optional split is the whole point of this slot's
    # contract: `:plan_payload` refuses so the Router stops a dispatch,
    # `:sibling_tasks` must not, because "no siblings" is a correct and
    # extremely common state. If this ever flips, every standalone task
    # in a fresh project loses its architecture pass.
    test "an unresolvable anchor is an empty {:ok, _} payload, not an error" do
      for opts <- [
            %{},
            %{task_id: Ecto.UUID.generate()},
            %{task_id: "not-a-uuid"},
            %{plan_id: Ecto.UUID.generate()}
          ] do
        assert {:ok, %{sibling_tasks: %{scope: :no_anchor, total: 0, tasks: []}}} =
                 ContextProviders.gather_context(:sibling_tasks, opts),
               "opts #{inspect(opts)} must resolve to an empty payload, never {:error, _}"
      end
    end

    test "the same trigger shapes that REFUSE for :plan_payload still succeed here" do
      # Paired contrast, same input, two slots — this is the assertion
      # that documents the split rather than merely relying on it.
      assert {:error, :no_plan_payload} = ContextProviders.gather_context(:plan_payload, %{})
      assert {:ok, %{sibling_tasks: _}} = ContextProviders.gather_context(:sibling_tasks, %{})
    end

    test "a solo task in a fresh project is :none, not an error" do
      task = insert_task!(plan_project().id, %{status: "planning"})

      assert %{scope: :none, total: 0, shown: 0, truncated?: false, tasks: []} =
               siblings_for(task.id)
    end
  end

  describe "gather_context/2 — :sibling_tasks tier ladder" do
    setup do
      project = plan_project()
      stack = insert_stack!(project.id)

      anchor =
        insert_task!(project.id, %{
          title: "Stacked Anchor",
          status: "planning",
          stack_id: stack.id,
          stack_position: 1
        })

      # Stack members deliberately carry NO plans, so they can't also
      # show up via the project-window tier and blur the two results.
      members =
        for position <- [2, 3, 4] do
          insert_task!(project.id, %{
            title: "Stack Member #{position}",
            stack_id: stack.id,
            stack_position: position
          })
        end

      # 5 unrelated in-flight project tasks, each with a live plan — the
      # exact set the project-window tier would return.
      noise = for n <- 1..5, do: planned_task!(project.id, %{title: "Project Noise #{n}"})

      %{project: project, stack: stack, anchor: anchor, members: members, noise: noise}
    end

    test "a stacked anchor returns its stack members in stack_position order", ctx do
      payload = siblings_for(ctx.anchor.id)

      assert payload.scope == :stack
      assert payload.total == 3
      assert payload.shown == 3
      refute payload.truncated?

      assert Enum.map(payload.tasks, & &1.task_id) == Enum.map(ctx.members, & &1.id)
      assert Enum.map(payload.tasks, & &1.stack_position) == [2, 3, 4]

      sibling_ids = MapSet.new(payload.tasks, & &1.task_id)
      refute MapSet.member?(sibling_ids, ctx.anchor.id), "the anchor must not be its own sibling"

      for noisy <- ctx.noise do
        refute MapSet.member?(sibling_ids, noisy.id),
               "stack tier must not leak the project window"
      end
    end

    test "POSITIVE CONTROL: those same project tasks DO appear once the anchor is unstacked",
         ctx do
      # Same mechanism, same fixtures, one field changed. Without this
      # the exclusion assertion above would also pass for a resolver
      # that simply returned nothing.
      {:ok, unstacked} =
        ctx.anchor
        |> Ecto.Changeset.change(stack_id: nil, stack_position: nil)
        |> Repo.update()

      payload = siblings_for(unstacked.id)

      assert payload.scope == :project_window
      sibling_ids = MapSet.new(payload.tasks, & &1.task_id)

      for noisy <- ctx.noise do
        assert MapSet.member?(sibling_ids, noisy.id),
               "project window must surface #{noisy.title}"
      end
    end

    test "an epic anchor with no stack resolves to the epic tier", ctx do
      epic = insert_epic!(ctx.project.id)

      anchor =
        insert_task!(ctx.project.id, %{
          title: "Epic Anchor",
          status: "planning",
          epic_id: epic.id
        })

      in_flight = insert_task!(ctx.project.id, %{title: "Epic Peer", epic_id: epic.id})

      retired =
        insert_task!(ctx.project.id, %{title: "Epic Done", epic_id: epic.id, status: "done"})

      payload = siblings_for(anchor.id)

      assert payload.scope == :epic
      sibling_ids = MapSet.new(payload.tasks, & &1.task_id)

      assert MapSet.member?(sibling_ids, in_flight.id)
      refute MapSet.member?(sibling_ids, retired.id), "epic tier keeps in-flight statuses only"
      refute MapSet.member?(sibling_ids, anchor.id)

      for noisy <- ctx.noise do
        refute MapSet.member?(sibling_ids, noisy.id),
               "epic tier must not fall through to the project window"
      end
    end
  end

  describe "gather_context/2 — :sibling_tasks project window" do
    test "DETECTOR: the window caps at 10 and reports what it dropped" do
      # Remove the `@project_window_limit` cap (or raise it) and
      # `shown == 10` / `truncated? == true` / `dropped == 10` all fail.
      project = plan_project()
      anchor = insert_task!(project.id, %{title: "Window Anchor", status: "planning"})

      for n <- 1..20, do: planned_task!(project.id, %{title: "Windowed #{n}"})

      payload = siblings_for(anchor.id)

      assert payload.scope == :project_window
      assert payload.total == 20
      assert payload.shown == 10
      assert payload.truncated? == true
      assert payload.dropped == 10
      assert length(payload.tasks) == 10
    end

    test "an unplanned in-flight task is excluded — and its exclusion is counted" do
      project = plan_project()
      anchor = insert_task!(project.id, %{title: "Filter Anchor", status: "planning"})
      unplanned = insert_task!(project.id, %{title: "No Plan Yet"})

      excluded = siblings_for(anchor.id)

      refute Enum.any?(excluded.tasks, &(&1.task_id == unplanned.id))

      assert excluded.unplanned_excluded == 1,
             "a dropped sibling must be counted, not silently vanish"

      # POSITIVE CONTROL on the same mechanism: give it a plan and the
      # very same task appears.
      _plan = bare_plan(unplanned.id, "pending_review")

      included = siblings_for(anchor.id)

      assert Enum.any?(included.tasks, &(&1.task_id == unplanned.id))
      assert included.unplanned_excluded == 0
      assert included.total == 1
    end

    test "a superseded-only plan does not qualify a sibling for the window" do
      project = plan_project()
      anchor = insert_task!(project.id, %{title: "Dead Plan Anchor", status: "planning"})
      dead = insert_task!(project.id, %{title: "Dead Plan Sibling"})
      _superseded = bare_plan(dead.id, "superseded")

      payload = siblings_for(anchor.id)

      refute Enum.any?(payload.tasks, &(&1.task_id == dead.id))
      assert payload.unplanned_excluded == 1
    end

    test "orders the window by updated_at desc" do
      project = plan_project()
      anchor = insert_task!(project.id, %{title: "Order Anchor", status: "planning"})
      now = DateTime.utc_now()

      oldest =
        planned_task!(project.id, %{
          title: "Oldest",
          updated_at: DateTime.add(now, -3600, :second)
        })

      newest = planned_task!(project.id, %{title: "Newest", updated_at: now})

      middle =
        planned_task!(project.id, %{
          title: "Middle",
          updated_at: DateTime.add(now, -60, :second)
        })

      assert Enum.map(siblings_for(anchor.id).tasks, & &1.task_id) ==
               [newest.id, middle.id, oldest.id]
    end
  end

  describe "gather_context/2 — :sibling_tasks stage budgets" do
    test "the project window shows 3 stages per sibling and says how many it hid" do
      project = plan_project()
      anchor = insert_task!(project.id, %{title: "Stage Budget Anchor", status: "planning"})
      sibling = insert_task!(project.id, %{title: "Eight Stage Sibling"})
      plan = bare_plan(sibling.id, "approved")

      for position <- 1..8, do: add_stage(plan.id, position)

      [entry] = siblings_for(anchor.id).tasks

      assert entry.stage_count == 8
      assert entry.stages_shown == 3
      assert entry.truncated? == true
      assert Enum.map(entry.stages, & &1.position) == [1, 2, 3]
    end

    test "the stack tier gets the wider 6-stage budget" do
      project = plan_project()
      stack = insert_stack!(project.id)

      anchor =
        insert_task!(project.id, %{
          title: "Stack Stage Anchor",
          status: "planning",
          stack_id: stack.id,
          stack_position: 1
        })

      member =
        insert_task!(project.id, %{
          title: "Stack Stage Member",
          stack_id: stack.id,
          stack_position: 2
        })

      plan = bare_plan(member.id, "approved")
      for position <- 1..8, do: add_stage(plan.id, position)

      [entry] = siblings_for(anchor.id).tasks

      assert entry.stage_count == 8
      assert entry.stages_shown == 6
      assert entry.truncated? == true
      assert entry.latest_plan_status == "approved"
    end

    test "sibling stage descriptions are truncated at 180 chars" do
      project = plan_project()
      anchor = insert_task!(project.id, %{title: "Truncate Anchor", status: "planning"})
      sibling = insert_task!(project.id, %{title: "Long Description Sibling"})
      plan = bare_plan(sibling.id, "approved")
      add_stage(plan.id, 1, %{description: String.duplicate("d", 5_000)})

      [entry] = siblings_for(anchor.id).tasks
      [stage] = entry.stages

      assert String.length(stage.description) == 181
      assert String.ends_with?(stage.description, "…")
    end
  end

  describe "gather_context/2 — unknown slot" do
    test "returns {:error, {:unknown_slot, _}} for slots this module doesn't materialise" do
      assert {:error, {:unknown_slot, :not_a_real_slot}} =
               ContextProviders.gather_context(:not_a_real_slot, [])
    end
  end

  describe "round-trip — all three slots in sequence" do
    test "Hal's full context_provided list (org_identity + recent_journal) resolves cleanly" do
      {:ok, _page} =
        OrgContext.upsert_file(%{
          file_key: "ORG_IDENTITY.md",
          content: "# Helios HQ\nProject lead: Mira Chen.",
          updated_by: Ecto.UUID.generate()
        })

      {:ok, _entry} =
        OrgContext.append_memory_entry(%{
          content: "Stand-up: Helios sprint kickoff.",
          date: Date.utc_today()
        })

      gathered =
        [:org_identity, :recent_journal]
        |> Enum.reduce(%{}, fn slot, acc ->
          {:ok, payload} = ContextProviders.gather_context(slot, [])
          Map.merge(acc, payload)
        end)

      assert gathered.org_identity.content =~ "Helios HQ"
      assert gathered.org_identity.missing? == false
      assert gathered.recent_journal.total >= 1
    end

    test "meetings.summarize's full context_provided list resolves into one keyed map" do
      {:ok, _page} =
        OrgContext.upsert_file(%{
          file_key: "ORG_IDENTITY.md",
          content: "# Org\nCEO: Mira Chen.",
          updated_by: Ecto.UUID.generate()
        })

      {:ok, transcript} =
        Meetings.create_transcript(%{
          room_id: Ecto.UUID.generate(),
          space_id: Ecto.UUID.generate(),
          segments: sample_segments()
        })

      slot_opts = %{
        org_identity: [],
        recent_journal: [],
        meeting_transcript: [transcript_id: transcript.id]
      }

      gathered =
        [:org_identity, :recent_journal, :meeting_transcript]
        |> Enum.reduce(%{}, fn slot, acc ->
          {:ok, payload} = ContextProviders.gather_context(slot, slot_opts[slot])
          Map.merge(acc, payload)
        end)

      # All three top-level keys land in the merged context map, keyed by
      # their symbolic name — exactly what M1's Router will hand to the
      # prompt-rendering step.
      assert Map.has_key?(gathered, :org_identity)
      assert Map.has_key?(gathered, :recent_journal)
      assert Map.has_key?(gathered, :meeting_transcript)

      assert gathered.org_identity.content =~ "Mira Chen"
      assert gathered.meeting_transcript.segment_count == 2
      assert gathered.meeting_transcript.formatted_text =~ "Helios milestone"
    end
  end
end
