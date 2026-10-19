defmodule Platform.Meetings.TriageTest do
  @moduledoc """
  Tests for the `Platform.Meetings.Triage.file_tasks_from_canvas/2` filing
  surface — the create-vs-skip decision that stitches the triage-officer
  runtime to the Tasks context (task 019f5e2b-8d29 stage 1).

  Stages 2–5 layer on top: needs_promotion badge, per-canvas cap, telemetry,
  and junk-batch rollback. Those exercise their own coverage.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Meetings.Triage
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Triage #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/triage"
      })

    slug = "triage-space-#{System.unique_integer([:positive])}"

    {:ok, space} =
      Chat.create_space(%{
        name: "Triage Space #{slug}",
        slug: slug,
        kind: "channel"
      })

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        display_name: "TriageAgent",
        joined_at: DateTime.utc_now()
      })

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => participant.id,
        "title" => "Meeting Triage Canvas"
      })

    %{project: project, canvas: canvas, space: space}
  end

  describe "file_tasks_from_canvas/2 — happy path" do
    test "files a fresh task and returns it under :filed", %{project: project, canvas: canvas} do
      assert {:ok, %{filed: [%Task{} = task], skipped: [], errors: []}} =
               Triage.file_tasks_from_canvas(canvas,
                 project_id: project.id,
                 action_items: [
                   %{title: "Ship guardrails demo", description: "from meeting"}
                 ]
               )

      assert task.title == "Ship guardrails demo"
      assert task.status == "backlog"
      assert task.description == "from meeting"
      assert task.metadata["source"] == "meetings.triage"
      assert task.metadata["source_canvas_id"] == canvas.id
    end

    test "multiple items — all fresh — all file", %{project: project, canvas: canvas} do
      items = [
        %{title: "Kickoff onboarding for Neven"},
        %{title: "Prep Q3 board deck"},
        %{title: "Sync with Globex legal"}
      ]

      assert {:ok, %{filed: filed, skipped: [], errors: []}} =
               Triage.file_tasks_from_canvas(canvas, project_id: project.id, action_items: items)

      assert length(filed) == 3
      titles = Enum.map(filed, & &1.title)
      assert "Kickoff onboarding for Neven" in titles
      assert "Prep Q3 board deck" in titles
      assert "Sync with Globex legal" in titles
    end

    test "custom source string is honored", %{project: project, canvas: canvas} do
      assert {:ok, %{filed: [%Task{} = task]}} =
               Triage.file_tasks_from_canvas(canvas,
                 project_id: project.id,
                 action_items: [%{title: "Confirm venue booking"}],
                 source: "meetings.triage.qa"
               )

      assert task.metadata["source"] == "meetings.triage.qa"
    end

    test "extra_metadata is merged into every task", %{project: project, canvas: canvas} do
      assert {:ok, %{filed: [%Task{} = task]}} =
               Triage.file_tasks_from_canvas(canvas,
                 project_id: project.id,
                 action_items: [%{title: "Confirm venue booking"}],
                 extra_metadata: %{"meeting_id" => "abc-123"}
               )

      assert task.metadata["meeting_id"] == "abc-123"
      assert task.metadata["source"] == "meetings.triage"
    end
  end

  describe "file_tasks_from_canvas/2 — dedup skip path" do
    test "skips a title fuzzy-matching an existing open task and returns {:skipped, id}",
         %{project: project, canvas: canvas} do
      {:ok, existing} =
        Tasks.create_task(%{project_id: project.id, title: "Provision Neven Acme account"})

      pre_count = Repo.aggregate(Task, :count, :id)

      assert {:ok, %{filed: [], skipped: [%{existing_task_id: id, title: title}], errors: []}} =
               Triage.file_tasks_from_canvas(canvas,
                 project_id: project.id,
                 action_items: [%{title: "Provision Neven Acme account"}]
               )

      assert id == existing.id
      assert title == "Provision Neven Acme account"

      # Skip really means "no insert" — the total row count is unchanged.
      assert Repo.aggregate(Task, :count, :id) == pre_count
    end

    test "skip path emits a canvas_event on the canvas topic", %{
      project: project,
      canvas: canvas
    } do
      {:ok, existing} =
        Tasks.create_task(%{project_id: project.id, title: "Provision Neven Acme account"})

      :ok = ChatPubSub.subscribe_canvas(canvas.id)

      {:ok, _result} =
        Triage.file_tasks_from_canvas(canvas,
          project_id: project.id,
          action_items: [%{title: "Provision Neven Acme account"}]
        )

      canvas_id = canvas.id
      existing_id = existing.id

      assert_receive {:canvas_event, ^canvas_id,
                      %{
                        type: "triage_task_skipped",
                        existing_task_id: ^existing_id,
                        candidate_title: "Provision Neven Acme account"
                      }},
                     500
    end

    test "skip path appends a text node noting the skip to the canvas", %{
      project: project,
      canvas: canvas
    } do
      {:ok, existing} =
        Tasks.create_task(%{project_id: project.id, title: "Provision Neven Acme account"})

      {:ok, _result} =
        Triage.file_tasks_from_canvas(canvas,
          project_id: project.id,
          action_items: [%{title: "Provision Neven Acme account"}]
        )

      # The canvas server persists asynchronously — refetch until the
      # revision advances past the initial 1.
      canvas_id = canvas.id

      {:ok, %{document: doc}} =
        Platform.Chat.Canvas.Server.describe(canvas_id)

      children = get_in(doc, ["root", "children"]) || []

      assert Enum.any?(children, fn child ->
               child["type"] == "text" and
                 String.contains?(
                   get_in(child, ["props", "value"]) || "",
                   "skipped (existing task #{existing.id})"
                 )
             end),
             "expected canvas to carry a skip note; children=#{inspect(children)}"
    end

    test "mixed batch — some skip, some file", %{project: project, canvas: canvas} do
      {:ok, existing} =
        Tasks.create_task(%{project_id: project.id, title: "Provision Neven Acme account"})

      items = [
        %{title: "Provision Neven Acme account"},
        %{title: "Prep Q3 board deck"}
      ]

      assert {:ok, %{filed: [filed], skipped: [%{existing_task_id: skipped_id}], errors: []}} =
               Triage.file_tasks_from_canvas(canvas, project_id: project.id, action_items: items)

      assert filed.title == "Prep Q3 board deck"
      assert skipped_id == existing.id
    end
  end

  describe "file_tasks_from_canvas/2 — error paths" do
    test "missing :project_id returns {:error, :missing_project_id}", %{canvas: canvas} do
      assert {:error, :missing_project_id} =
               Triage.file_tasks_from_canvas(canvas, action_items: [%{title: "x"}])
    end

    test "missing :action_items returns {:error, :missing_action_items}", %{
      project: project,
      canvas: canvas
    } do
      assert {:error, :missing_action_items} =
               Triage.file_tasks_from_canvas(canvas, project_id: project.id)
    end

    test "unknown canvas id returns {:error, :canvas_not_found}", %{project: project} do
      assert {:error, :canvas_not_found} =
               Triage.file_tasks_from_canvas(Ecto.UUID.generate(),
                 project_id: project.id,
                 action_items: [%{title: "x"}]
               )
    end

    test "action item missing a title is recorded under :errors", %{
      project: project,
      canvas: canvas
    } do
      assert {:ok, %{filed: [], skipped: [], errors: [%{reason: :missing_title}]}} =
               Triage.file_tasks_from_canvas(canvas,
                 project_id: project.id,
                 action_items: [%{description: "no title here"}]
               )
    end

    test "accepts a canvas id (binary) as first arg", %{project: project, canvas: canvas} do
      assert {:ok, %{filed: [%Task{}]}} =
               Triage.file_tasks_from_canvas(canvas.id,
                 project_id: project.id,
                 action_items: [%{title: "Handle via canvas id"}]
               )
    end
  end

  describe "file_tasks_from_canvas/2 — needs_promotion + backlog cap (stage 2)" do
    test "tasks filed while under the cap get needs_promotion: true", %{
      project: project,
      canvas: canvas
    } do
      assert {:ok, %{filed: [%Task{} = task]}} =
               Triage.file_tasks_from_canvas(canvas,
                 project_id: project.id,
                 action_items: [%{title: "Under cap task"}],
                 backlog_cap: 5
               )

      assert task.needs_promotion == true
      assert task.metadata["source"] == "meetings.triage"
    end

    test "tasks filed over the cap get needs_promotion: false", %{
      project: project,
      canvas: canvas
    } do
      # Preseed 5 existing triage-source tasks (cap == 5), then file one
      # more — that one should NOT be flagged.
      for i <- 1..5 do
        {:ok, _} =
          Tasks.create_task(%{
            project_id: project.id,
            title: "Existing triage #{i}",
            needs_promotion: true,
            metadata: %{"source" => "meetings.triage"}
          })
      end

      assert {:ok, %{filed: [%Task{} = new_task]}} =
               Triage.file_tasks_from_canvas(canvas,
                 project_id: project.id,
                 action_items: [%{title: "Over cap task"}],
                 backlog_cap: 5
               )

      assert new_task.needs_promotion == false
      assert new_task.metadata["source"] == "meetings.triage"
    end

    test "within a single batch, cap is applied progressively", %{
      project: project,
      canvas: canvas
    } do
      # Start with 3 in the project, cap at 5 — batch of 4 should get
      # first two `true`, last two `false` (3+2 hits the cap, 4th/5th
      # over).
      for i <- 1..3 do
        {:ok, _} =
          Tasks.create_task(%{
            project_id: project.id,
            title: "Preseed #{i}",
            needs_promotion: true,
            metadata: %{"source" => "meetings.triage"}
          })
      end

      # Distinct titles so the dedup gate doesn't collapse the batch —
      # this test is about the cap counter, not the fuzzy matcher.
      items = [
        %{title: "Confirm venue booking"},
        %{title: "Draft Globex engagement letter"},
        %{title: "Kickoff Neven onboarding"},
        %{title: "Schedule board dry-run"}
      ]

      assert {:ok, %{filed: filed}} =
               Triage.file_tasks_from_canvas(canvas,
                 project_id: project.id,
                 action_items: items,
                 backlog_cap: 5
               )

      needs_flags = Enum.map(filed, & &1.needs_promotion)
      # First two land under cap (3 → 4, 4 → 5), last two over.
      assert needs_flags == [true, true, false, false]
    end

    test "opts[:backlog_cap] overrides the app-env default", %{
      project: project,
      canvas: canvas
    } do
      # 0-cap means "never flag" — every task ships with false.
      assert {:ok, %{filed: [%Task{needs_promotion: false}]}} =
               Triage.file_tasks_from_canvas(canvas,
                 project_id: project.id,
                 action_items: [%{title: "Zero cap"}],
                 backlog_cap: 0
               )
    end

    test "counter only reads same-project + same-source rows", %{
      project: project,
      canvas: canvas
    } do
      # Preseed a task in a DIFFERENT project → should NOT count.
      {:ok, other_project} =
        Tasks.create_project(%{
          name: "Other #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/other-cap"
        })

      for i <- 1..10 do
        {:ok, _} =
          Tasks.create_task(%{
            project_id: other_project.id,
            title: "Cross-project #{i}",
            needs_promotion: true,
            metadata: %{"source" => "meetings.triage"}
          })
      end

      # Preseed a task in the SAME project with a DIFFERENT source → should NOT count.
      {:ok, _} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Same project, different source",
          metadata: %{"source" => "some.other.pipeline"}
        })

      assert {:ok, %{filed: [%Task{needs_promotion: true}]}} =
               Triage.file_tasks_from_canvas(canvas,
                 project_id: project.id,
                 action_items: [%{title: "Should still be under cap"}],
                 backlog_cap: 1
               )
    end
  end

  describe "file_tasks_from_canvas/2 — telemetry emission (stage 3)" do
    setup do
      test_pid = self()
      handler_id = "triage-telemetry-test-#{System.unique_integer([:positive])}"

      # Bridge the telemetry events to the test process so we can
      # assert_receive on them without touching the audit persistence
      # layer. Same pattern used elsewhere in the codebase.
      :telemetry.attach_many(
        handler_id,
        [
          [:platform, :meetings, :triage_dispatch],
          [:platform, :meetings, :tasks_created_from_meeting]
        ],
        fn event, measurements, metadata, _cfg ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :ok
    end

    test "emits one :triage_dispatch event per batch with the action-item count", %{
      project: project,
      canvas: canvas
    } do
      items = [
        %{title: "Ship Q3 launch plan"},
        %{title: "Draft Globex engagement letter"},
        %{title: "Book venue for kickoff"}
      ]

      {:ok, _} =
        Triage.file_tasks_from_canvas(canvas,
          project_id: project.id,
          action_items: items
        )

      canvas_id = canvas.id
      project_id = project.id

      assert_receive {:telemetry_event, [:platform, :meetings, :triage_dispatch],
                      %{action_item_count: 3}, %{canvas_id: ^canvas_id, project_id: ^project_id}},
                     500
    end

    test "emits one :tasks_created_from_meeting event per successful create", %{
      project: project,
      canvas: canvas
    } do
      items = [
        %{title: "Ship Q3 launch plan"},
        %{title: "Draft Globex engagement letter"}
      ]

      {:ok, %{filed: [t1, t2]}} =
        Triage.file_tasks_from_canvas(canvas,
          project_id: project.id,
          action_items: items
        )

      canvas_id = canvas.id
      t1_id = t1.id
      t2_id = t2.id

      # One event per task, order matches insertion.
      assert_receive {:telemetry_event, [:platform, :meetings, :tasks_created_from_meeting],
                      %{count: 1},
                      %{task_id: ^t1_id, canvas_id: ^canvas_id, source: "meetings.triage"}},
                     500

      assert_receive {:telemetry_event, [:platform, :meetings, :tasks_created_from_meeting],
                      %{count: 1}, %{task_id: ^t2_id, canvas_id: ^canvas_id}},
                     500
    end

    test "skip path (dedup match) does NOT emit :tasks_created_from_meeting", %{
      project: project,
      canvas: canvas
    } do
      {:ok, _existing} =
        Tasks.create_task(%{project_id: project.id, title: "Provision Neven Acme account"})

      {:ok, %{filed: [], skipped: [_]}} =
        Triage.file_tasks_from_canvas(canvas,
          project_id: project.id,
          action_items: [%{title: "Provision Neven Acme account"}]
        )

      # dispatch fires (batch entered) but no per-task event
      assert_receive {:telemetry_event, [:platform, :meetings, :triage_dispatch], _, _}, 500

      refute_receive {:telemetry_event, [:platform, :meetings, :tasks_created_from_meeting], _,
                      _},
                     200
    end

    test "meeting_id + transcript_id from opts flow into event metadata", %{
      project: project,
      canvas: canvas
    } do
      meeting_id = Ecto.UUID.generate()
      transcript_id = Ecto.UUID.generate()

      {:ok, _} =
        Triage.file_tasks_from_canvas(canvas,
          project_id: project.id,
          action_items: [%{title: "Prep board slides"}],
          meeting_id: meeting_id,
          transcript_id: transcript_id
        )

      assert_receive {:telemetry_event, [:platform, :meetings, :triage_dispatch], _,
                      %{meeting_id: ^meeting_id}},
                     500

      assert_receive {:telemetry_event, [:platform, :meetings, :tasks_created_from_meeting], _,
                      %{meeting_id: ^meeting_id, transcript_id: ^transcript_id}},
                     500
    end
  end

  describe "file_tasks_from_canvas/2 — per-canvas cap (stage 4)" do
    setup do
      test_pid = self()
      handler_id = "triage-cap-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:platform, :meetings, :triage_cap_hit],
        fn event, measurements, metadata, _cfg ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :ok
    end

    test "batch of 25 items with cap 20 files exactly 20 and drops the last 5", %{
      project: project,
      canvas: canvas
    } do
      # Fully distinct titles so the fuzzy-dedup gate does not collapse
      # the batch — this test isolates the cap counter. Common shared
      # prefixes push Jaro-Winkler above 0.85 (it rewards prefix
      # matches heavily), so we avoid a common lead word entirely.
      titles = [
        "Confirm venue booking for offsite",
        "Draft Globex engagement letter",
        "Kickoff Neven onboarding",
        "Schedule board dry-run rehearsal",
        "Prep quarterly finance packet",
        "Order laptops for the new hires",
        "Review Robin slide deck for Q3",
        "Book photographer for retreat",
        "Publish revised handbook",
        "File H1B extension paperwork",
        "Rotate S3 access keys",
        "Deprecate legacy webhook endpoint",
        "Investigate Postgres slow query",
        "Ship telemetry dashboards",
        "Refactor billing pipeline",
        "Move DNS from Cloudflare",
        "Renew wildcard TLS certificate",
        "Backup vault before rotation",
        "Prune docker registry",
        "Onboard new intern next month",
        "Sync with Globex legal counsel",
        "Restore staging database",
        "Ship mobile app v2.3",
        "Rebuild search index nightly",
        "Automate contract renewal emails"
      ]

      items = for t <- titles, do: %{title: t}

      assert {:ok, %{filed: filed, capped?: true, cap_dropped: dropped}} =
               Triage.file_tasks_from_canvas(canvas,
                 project_id: project.id,
                 action_items: items,
                 per_canvas_cap: 20
               )

      assert length(filed) == 20
      assert dropped == 5

      # DB round-trip — exactly 20 tasks land, tagged with the canvas id
      # via metadata["source_canvas_id"].
      canvas_id = canvas.id

      db_count =
        Repo.aggregate(
          from(t in Task,
            where: is_nil(t.deleted_at),
            where: fragment("(? ->> 'source_canvas_id') = ?", t.metadata, ^canvas_id)
          ),
          :count
        )

      assert db_count == 20
    end

    test "cap-hit telemetry event fires with measurements + metadata", %{
      project: project,
      canvas: canvas
    } do
      # Distinct titles across a wide vocabulary so the fuzzy-dedup
      # gate does not collapse the batch and starve the cap counter.
      items = [
        %{title: "Confirm venue booking"},
        %{title: "Draft Globex engagement letter"},
        %{title: "Kickoff Neven onboarding"},
        %{title: "Schedule board dry-run"},
        %{title: "Prep quarterly finance packet"},
        %{title: "Order laptops for offsite"},
        %{title: "Review Robin's slide deck"},
        %{title: "Book photographer for retreat"}
      ]

      {:ok, _} =
        Triage.file_tasks_from_canvas(canvas,
          project_id: project.id,
          action_items: items,
          per_canvas_cap: 5,
          meeting_id: "mtg-stage4"
        )

      canvas_id = canvas.id
      project_id = project.id

      assert_receive {:telemetry_event, [:platform, :meetings, :triage_cap_hit],
                      %{cap: 5, attempted: 8, dropped: 3},
                      %{canvas_id: ^canvas_id, project_id: ^project_id, meeting_id: "mtg-stage4"}},
                     500
    end

    test "cap-hit note is appended to the source canvas", %{
      project: project,
      canvas: canvas
    } do
      # Distinct titles — see the "batch of 25" test for why the
      # dedup gate collapses same-prefix batches.
      items = [
        %{title: "Alpha catering estimate"},
        %{title: "Beta wire transfer form"},
        %{title: "Charlie handbook rewrite"},
        %{title: "Delta hire panel booking"},
        %{title: "Echo forecast reconciliation"},
        %{title: "Foxtrot venue A/V setup"},
        %{title: "Golf caterer contract review"}
      ]

      {:ok, _} =
        Triage.file_tasks_from_canvas(canvas,
          project_id: project.id,
          action_items: items,
          per_canvas_cap: 4
        )

      {:ok, %{document: doc}} =
        Platform.Chat.Canvas.Server.describe(canvas.id)

      children = get_in(doc, ["root", "children"]) || []

      assert Enum.any?(children, fn child ->
               child["type"] == "text" and
                 (get_in(child, ["props", "value"]) || "") ==
                   "triage capped at 4 tasks — 3 action items skipped"
             end),
             "expected canvas to carry a cap note; children=#{inspect(children)}"
    end

    test "pre-existing tasks on the canvas count against the cap across invocations", %{
      project: project,
      canvas: canvas
    } do
      # Preseed 3 tasks that already carry this canvas as source. A
      # subsequent 5-item batch under cap-4 should file exactly 1
      # (3 existing + 1 new = 4 → cap) and drop the other 4.
      for i <- 1..3 do
        {:ok, _} =
          Tasks.create_task(%{
            project_id: project.id,
            title: "Preseed cap #{i}",
            metadata: %{"source" => "meetings.triage", "source_canvas_id" => canvas.id}
          })
      end

      items = [
        %{title: "Confirm venue booking for offsite"},
        %{title: "Draft Globex engagement letter"},
        %{title: "Rotate S3 access keys"},
        %{title: "Ship mobile app v2.3"},
        %{title: "Rebuild search index nightly"}
      ]

      assert {:ok, %{filed: [_only], capped?: true, cap_dropped: 4}} =
               Triage.file_tasks_from_canvas(canvas,
                 project_id: project.id,
                 action_items: items,
                 per_canvas_cap: 4
               )
    end

    test "no cap hit when under the limit — capped? stays false", %{
      project: project,
      canvas: canvas
    } do
      test_pid = self()

      # Register a listener that fails the test if the cap event fires.
      :telemetry.attach(
        "no-cap-listener-#{System.unique_integer([:positive])}",
        [:platform, :meetings, :triage_cap_hit],
        fn _, _, _, _ -> send(test_pid, :cap_fired) end,
        %{}
      )

      items = [
        %{title: "Confirm venue booking for offsite"},
        %{title: "Ship mobile app v2.3"},
        %{title: "Rotate S3 access keys"}
      ]

      assert {:ok, %{filed: filed, capped?: false, cap_dropped: 0}} =
               Triage.file_tasks_from_canvas(canvas,
                 project_id: project.id,
                 action_items: items,
                 per_canvas_cap: 20
               )

      assert length(filed) == 3
      refute_receive :cap_fired, 200
    end

    test "cap of 0 rejects every item", %{
      project: project,
      canvas: canvas
    } do
      items = [%{title: "Should be dropped 1"}, %{title: "Should be dropped 2"}]

      assert {:ok, %{filed: [], capped?: true, cap_dropped: 2}} =
               Triage.file_tasks_from_canvas(canvas,
                 project_id: project.id,
                 action_items: items,
                 per_canvas_cap: 0
               )
    end

    test "cap is scoped to canvas — tasks on a DIFFERENT canvas do not count", %{
      project: project,
      canvas: canvas
    } do
      slug = "other-canvas-#{System.unique_integer([:positive])}"

      {:ok, other_space} =
        Chat.create_space(%{name: "Other #{slug}", slug: slug, kind: "channel"})

      {:ok, other_participant} =
        Chat.add_participant(other_space.id, %{
          participant_type: "agent",
          participant_id: Ecto.UUID.generate(),
          display_name: "Other",
          joined_at: DateTime.utc_now()
        })

      {:ok, other_canvas} =
        Chat.create_canvas(%{
          "space_id" => other_space.id,
          "created_by" => other_participant.id,
          "title" => "Other canvas"
        })

      # Preseed 10 tasks tagged to the OTHER canvas. These must NOT
      # count against the cap on `canvas`.
      for i <- 1..10 do
        {:ok, _} =
          Tasks.create_task(%{
            project_id: project.id,
            title: "Other-canvas seed #{i}",
            metadata: %{
              "source" => "meetings.triage",
              "source_canvas_id" => other_canvas.id
            }
          })
      end

      items = [
        %{title: "Confirm venue booking for offsite"},
        %{title: "Draft Globex engagement letter"},
        %{title: "Kickoff Neven onboarding"},
        %{title: "Ship mobile app v2.3"}
      ]

      assert {:ok, %{filed: filed, capped?: false}} =
               Triage.file_tasks_from_canvas(canvas,
                 project_id: project.id,
                 action_items: items,
                 per_canvas_cap: 5
               )

      assert length(filed) == 4
    end
  end

  describe "junk_batch/2 — batch soft-delete (stage 5)" do
    test "soft-deletes every non-deleted task filed from the canvas", %{
      project: project,
      canvas: canvas
    } do
      items = [
        %{title: "Confirm venue booking for offsite"},
        %{title: "Draft Globex engagement letter"},
        %{title: "Kickoff Neven onboarding"},
        %{title: "Rotate S3 access keys"},
        %{title: "Ship mobile app v2.3"}
      ]

      {:ok, %{filed: filed}} =
        Triage.file_tasks_from_canvas(canvas,
          project_id: project.id,
          action_items: items
        )

      assert length(filed) == 5

      assert {:ok, 5} = Triage.junk_batch(canvas, actor_id: Ecto.UUID.generate())

      # Every filed task now has a non-nil `deleted_at`.
      for %Task{id: id} <- filed do
        task = Repo.get!(Task, id)
        assert task.deleted_at, "expected #{id} to be soft-deleted"
      end
    end

    test "idempotent — second invocation returns {:ok, 0} without a duplicate audit row", %{
      project: project,
      canvas: canvas
    } do
      items = [
        %{title: "Confirm venue booking for offsite"},
        %{title: "Ship mobile app v2.3"}
      ]

      {:ok, _} =
        Triage.file_tasks_from_canvas(canvas, project_id: project.id, action_items: items)

      assert {:ok, 2} = Triage.junk_batch(canvas)
      before_count = junk_audit_count(canvas.id)

      assert {:ok, 0} = Triage.junk_batch(canvas)
      after_count = junk_audit_count(canvas.id)

      assert after_count == before_count,
             "expected the idempotent no-op branch to skip the audit insert"
    end

    test "records an audit row of type meetings.triage.batch_junked with task_ids + actor_id", %{
      project: project,
      canvas: canvas
    } do
      actor_id = Ecto.UUID.generate()

      items = [
        %{title: "Ship mobile app v2.3"},
        %{title: "Rotate S3 access keys"},
        %{title: "Draft Globex engagement letter"}
      ]

      {:ok, %{filed: filed}} =
        Triage.file_tasks_from_canvas(canvas, project_id: project.id, action_items: items)

      filed_ids = Enum.map(filed, & &1.id) |> Enum.sort()

      assert {:ok, 3} = Triage.junk_batch(canvas, actor_id: actor_id)

      [event] = Platform.Audit.list(event_type: "meetings.triage.batch_junked")

      assert event.resource_id == canvas.id
      assert event.resource_type == "meetings"
      assert event.action == "junk_batch"
      assert event.actor_id == actor_id
      assert event.actor_type == "user"

      metadata_ids =
        event.metadata
        |> Map.get("task_ids")
        |> List.wrap()
        |> Enum.sort()

      assert metadata_ids == filed_ids
      assert event.metadata["count"] == 3
      assert event.metadata["canvas_id"] == canvas.id
    end

    test "appends a `N tasks soft-deleted at <ISO8601>` note to the source canvas", %{
      project: project,
      canvas: canvas
    } do
      items = [
        %{title: "Ship mobile app v2.3"},
        %{title: "Rotate S3 access keys"}
      ]

      {:ok, _} =
        Triage.file_tasks_from_canvas(canvas, project_id: project.id, action_items: items)

      assert {:ok, 2} = Triage.junk_batch(canvas)

      {:ok, %{document: doc}} =
        Platform.Chat.Canvas.Server.describe(canvas.id)

      children = get_in(doc, ["root", "children"]) || []

      # M5b (task 019f6e2c) stage 5 wording: `N tasks soft-deleted at <ISO8601 UTC>`.
      # Unambiguous for any auditor reading a canvas revision later; relative-time
      # is a downstream polish, not the source of truth.
      matcher = ~r/\A2 tasks soft-deleted at \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z\z/

      assert Enum.any?(children, fn child ->
               child["type"] == "text" and
                 Regex.match?(matcher, get_in(child, ["props", "value"]) || "")
             end),
             "expected canvas to carry the M5b-format batch-junk note; children=#{inspect(children)}"
    end

    test "uses singular `task` when exactly one row is soft-deleted", %{
      project: project,
      canvas: canvas
    } do
      {:ok, _} =
        Triage.file_tasks_from_canvas(canvas,
          project_id: project.id,
          action_items: [%{title: "Ship mobile app v2.3"}]
        )

      assert {:ok, 1} = Triage.junk_batch(canvas)

      {:ok, %{document: doc}} =
        Platform.Chat.Canvas.Server.describe(canvas.id)

      children = get_in(doc, ["root", "children"]) || []
      matcher = ~r/\A1 task soft-deleted at \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z\z/

      assert Enum.any?(children, fn child ->
               child["type"] == "text" and
                 Regex.match?(matcher, get_in(child, ["props", "value"]) || "")
             end),
             "expected singular `task` copy for the 1-row case"
    end

    test "unknown canvas id returns {:error, :canvas_not_found}" do
      assert {:error, :canvas_not_found} =
               Triage.junk_batch(Ecto.UUID.generate())
    end

    test "no tasks tagged with this canvas returns {:ok, 0}", %{canvas: canvas} do
      # Fresh canvas with no filings — junk_batch is a legal no-op.
      assert {:ok, 0} = Triage.junk_batch(canvas)
    end

    test "does not touch tasks filed from a DIFFERENT canvas", %{
      project: project,
      canvas: canvas
    } do
      slug = "keeper-#{System.unique_integer([:positive])}"

      {:ok, other_space} =
        Chat.create_space(%{name: "Keep #{slug}", slug: slug, kind: "channel"})

      {:ok, other_participant} =
        Chat.add_participant(other_space.id, %{
          participant_type: "agent",
          participant_id: Ecto.UUID.generate(),
          display_name: "Keeper",
          joined_at: DateTime.utc_now()
        })

      {:ok, other_canvas} =
        Chat.create_canvas(%{
          "space_id" => other_space.id,
          "created_by" => other_participant.id,
          "title" => "Other canvas"
        })

      # File on the ORIGINAL canvas.
      {:ok, %{filed: [task_to_junk]}} =
        Triage.file_tasks_from_canvas(canvas,
          project_id: project.id,
          action_items: [%{title: "Ship mobile app v2.3"}]
        )

      # File on the OTHER canvas.
      {:ok, %{filed: [task_to_keep]}} =
        Triage.file_tasks_from_canvas(other_canvas,
          project_id: project.id,
          action_items: [%{title: "Rotate S3 access keys"}]
        )

      assert {:ok, 1} = Triage.junk_batch(canvas)

      assert Repo.get!(Task, task_to_junk.id).deleted_at
      refute Repo.get!(Task, task_to_keep.id).deleted_at
    end
  end

  describe "file_tasks_from_canvas/2 — junk action_row (stage 5)" do
    test "appends a `Junk this batch` action_row to the source canvas on a successful batch",
         %{project: project, canvas: canvas} do
      {:ok, _} =
        Triage.file_tasks_from_canvas(canvas,
          project_id: project.id,
          action_items: [%{title: "Ship mobile app v2.3"}]
        )

      {:ok, %{document: doc}} =
        Platform.Chat.Canvas.Server.describe(canvas.id)

      children = get_in(doc, ["root", "children"]) || []

      action_row =
        Enum.find(children, fn child ->
          child["type"] == "action_row" and
            String.starts_with?(child["id"] || "", "triage-junk-actions-")
        end)

      assert action_row, "expected an action_row node; children=#{inspect(children)}"

      [action] = get_in(action_row, ["props", "actions"])
      assert action["label"] == "Junk this batch"
      assert action["variant"] == "danger"
      assert action["value"] == "junk_batch:#{canvas.id}"
    end

    test "empty batch (all items skipped by dedup) does NOT emit an action_row",
         %{project: project, canvas: canvas} do
      {:ok, _existing} =
        Tasks.create_task(%{project_id: project.id, title: "Ship mobile app v2.3"})

      {:ok, %{filed: [], skipped: [_]}} =
        Triage.file_tasks_from_canvas(canvas,
          project_id: project.id,
          action_items: [%{title: "Ship mobile app v2.3"}]
        )

      {:ok, %{document: doc}} =
        Platform.Chat.Canvas.Server.describe(canvas.id)

      children = get_in(doc, ["root", "children"]) || []

      refute Enum.any?(children, fn child ->
               child["type"] == "action_row" and
                 String.starts_with?(child["id"] || "", "triage-junk-actions-")
             end),
             "expected no action_row on an empty-batch filing"
    end
  end

  # ── M5b (task 019f6e2c) Stage 4 — preview_batch/1 ───────────────────────

  describe "preview_batch/1 — cheap survivor-count read" do
    setup do
      slug = "preview-#{System.unique_integer([:positive])}"

      {:ok, project} =
        Tasks.create_project(%{
          name: "Preview #{slug}",
          repo_url: "https://github.com/test/preview-#{slug}"
        })

      {:ok, space} =
        Chat.create_space(%{name: "Preview #{slug}", slug: slug, kind: "channel"})

      {:ok, participant} =
        Chat.add_participant(space.id, %{
          participant_type: "agent",
          participant_id: Ecto.UUID.generate(),
          display_name: "Preview officer",
          joined_at: DateTime.utc_now()
        })

      {:ok, canvas} =
        Chat.create_canvas(%{
          "space_id" => space.id,
          "created_by" => participant.id,
          "title" => "Preview canvas"
        })

      %{project: project, canvas: canvas}
    end

    test "zero survivors returns count 0", %{canvas: canvas} do
      assert {:ok, %{canvas_id: id, surviving_task_count: 0}} = Triage.preview_batch(canvas)
      assert id == canvas.id
    end

    test "N survivors returns count N and excludes soft-deleted rows",
         %{project: project, canvas: canvas} do
      {:ok, %{filed: filed}} =
        Triage.file_tasks_from_canvas(canvas,
          project_id: project.id,
          action_items: [
            %{title: "Ship mobile app v2.3"},
            %{title: "Rotate S3 access keys"},
            %{title: "Draft Globex engagement letter"}
          ]
        )

      assert length(filed) == 3
      assert {:ok, %{surviving_task_count: 3}} = Triage.preview_batch(canvas)

      # Soft-delete one and re-preview.
      [first | _] = filed
      Tasks.soft_delete_task(first)

      assert {:ok, %{surviving_task_count: 2}} = Triage.preview_batch(canvas)

      # After junk_batch the count is zero.
      {:ok, _} = Triage.junk_batch(canvas)
      assert {:ok, %{surviving_task_count: 0}} = Triage.preview_batch(canvas)
    end

    test "unknown canvas id returns {:error, :canvas_not_found}" do
      assert {:error, :canvas_not_found} = Triage.preview_batch(Ecto.UUID.generate())
    end
  end

  # ── M5b (task 019f6e2c) Stage 5 — batch broadcast on junk_batch/2 ───────

  describe "junk_batch/2 — kanban batch broadcast" do
    setup do
      slug = "batch-broadcast-#{System.unique_integer([:positive])}"

      {:ok, project} =
        Tasks.create_project(%{
          name: "Broadcast #{slug}",
          repo_url: "https://github.com/test/broadcast-#{slug}"
        })

      {:ok, space} =
        Chat.create_space(%{name: "Broadcast #{slug}", slug: slug, kind: "channel"})

      {:ok, participant} =
        Chat.add_participant(space.id, %{
          participant_type: "agent",
          participant_id: Ecto.UUID.generate(),
          display_name: "Broadcast officer",
          joined_at: DateTime.utc_now()
        })

      {:ok, canvas} =
        Chat.create_canvas(%{
          "space_id" => space.id,
          "created_by" => participant.id,
          "title" => "Broadcast canvas"
        })

      %{project: project, canvas: canvas}
    end

    test "emits exactly one {:tasks_batch_deleted, ids, meta} broadcast per invocation",
         %{project: project, canvas: canvas} do
      # 6 filings → 6 rows to soft-delete → ONE broadcast, not six. Titles
      # must be lexically distinct so the dedup gate (`similar_open_titles/3`
      # trigram threshold) doesn't collapse them into one filed row.
      titles = [
        %{title: "Ship mobile app v2.3"},
        %{title: "Rotate S3 access keys"},
        %{title: "Draft Globex engagement letter"},
        %{title: "Wire up Klaviyo webhook"},
        %{title: "Migrate legacy PDF pipeline"},
        %{title: "Audit RBAC roles"}
      ]

      {:ok, %{filed: filed}} =
        Triage.file_tasks_from_canvas(canvas, project_id: project.id, action_items: titles)

      filed_ids = filed |> Enum.map(& &1.id) |> Enum.sort()

      Platform.Tasks.subscribe_board()

      assert {:ok, 6} = Triage.junk_batch(canvas, actor_id: Ecto.UUID.generate())

      canvas_id = canvas.id

      assert_receive {:tasks_batch_deleted, ids, meta}, 500

      assert Enum.sort(ids) == filed_ids
      assert meta.canvas_id == canvas_id
      assert meta.count == 6
      assert %DateTime{} = meta.soft_deleted_at

      # No sibling per-row :task_deleted broadcasts fire from the same call.
      refute_receive {:task_deleted, _}, 200

      # Second (idempotent) invocation emits nothing.
      assert {:ok, 0} = Triage.junk_batch(canvas)
      refute_receive {:tasks_batch_deleted, _, _}, 200
      refute_receive {:task_deleted, _}, 200
    end

    test "empty-batch invocation emits no broadcast", %{canvas: canvas} do
      # Fresh canvas — junk_batch is a legal no-op that must not leak a
      # zero-count broadcast to subscribers.
      Platform.Tasks.subscribe_board()

      assert {:ok, 0} = Triage.junk_batch(canvas)

      refute_receive {:tasks_batch_deleted, _, _}, 200
    end
  end

  # Counts ONLY the batch-junk audit rows belonging to this canvas.
  #
  # The idempotency test previously used
  # `Repo.aggregate(Platform.Audit.Event, :count, :id)` — a GLOBAL tally.
  # This case is `async: false`, which puts the sandbox in `{:shared, self()}`
  # mode, so every process on the node writes through this test's connection.
  # `Platform.Audit.TelemetryHandler` persists `[:platform, :historian | _]`
  # events from a spawned `Task.Supervisor` child (telemetry_handler.ex:170,187);
  # such a child belonging to an earlier test can still be in flight and land
  # its row here, inflating the global count between the two reads. That fails
  # an assertion about a code path which provably wrote nothing:
  # `Triage.junk_batch/2`'s idempotent branch (triage.ex:291-295) returns
  # `{:ok, 0}` without ever calling `record_junk_audit/4`.
  #
  # Scoping to this canvas's own event type asserts exactly the intended
  # contract and is unaffected by unrelated audit traffic.
  defp junk_audit_count(canvas_id) do
    from(e in Platform.Audit.Event,
      where: e.event_type == "meetings.triage.batch_junked",
      where: e.resource_id == ^canvas_id
    )
    |> Repo.aggregate(:count, :id)
  end
end
