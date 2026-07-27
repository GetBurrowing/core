defmodule Platform.Tasks.ArchitectureEscalationTest do
  @moduledoc """
  ADR-0046 member 6 stage 4 — what happens at iteration 2: the human gets
  the DISAGREEMENT, and the planner does NOT get woken up.

  Stage 3 landed the bound; this file is about the notification hanging off
  it. The two things that can silently break are (a) the digest showing only
  the latest verdict, which reads fine and answers the wrong question, and
  (b) the digest being posted as an ENGAGEMENT, which reads fine and reopens
  the loop the bound just closed. Both have a detector below.

  Not `async: true`: `resolve_architecture_gate/3` and `reject_plan/3` both
  broadcast `{:plan_updated, _}` on `tasks:board`, which wakes the singleton
  `TaskRouterWatcher`.

  ## Why the digest is selected by CONTENT and not by metadata

  `ExecutionSpace.post_log/2` takes no metadata option — it writes a fixed
  `%{"source" => "task_router", "kind" => "log", "log_only" => true}` —
  whereas `post_engagement/3` merges the caller's map, which is how stage 3's
  feedback post carries `"reason" => "plan_rejected"`. Selecting the digest
  by any metadata key would therefore mean the mandatory detonation (revert
  `post_log/2` to `post_engagement/3`) fails in the SELECTOR, and the
  `log_only` assertion — the one that actually encodes "this must not wake
  the planner" — would never be reached. Stage 2 measured exactly that
  substitution on `PlanRejection` and found the metadata filter, not the
  `log_only` assertion, was doing the catching. `digest_messages/1` matches
  on the digest's own header text so the assertion under test is the one
  that fires.

  ## VACUITY CONTROLS, MEASURED (10/10 detected, at commit 56ab108e)

  Control set: this file (7 tests), `architecture_rejection_loop_test.exs`
  (11) and `architecture_rejection_streak_test.exs` (18) — 36 tests, 0
  failures unmodified, seed 0. Each control changes exactly one thing in the
  SOURCE and nothing in any test file. Named by the assertion that actually
  fires, not by the failure count.

    1. THE DIGEST POSTED AS AN ENGAGEMENT (`post_log/2` -> `post_engagement/3`
       in `post_digest/2`) — the mandatory detonation, and the realistic
       "tidy the two posts into one" mutation. 3 failures, ALL THREE on
       `log_only == true`. Detected, and detected on the RIGHT line: the
       content-based selector still finds the message, so the assertion that
       fires is the one that says the planner must not be woken.
    1b. `log_only` FLIPPED IN ISOLATION (`ExecutionSpace.post_log/2`'s
       `log_only: true` -> `false`, its metadata left saying `"kind" =>
       "log"`, so the message is a log by every other measure). Stage 2's
       instruction to this stage, and the sharper of the two: the SAME 3
       failures on the SAME 3 lines. Detected — which is the evidence that
       these assertions test the WAKE-UP PROPERTY itself and not merely
       which function was called. The two controls are indistinguishable
       from the test suite's side, which is the point: `log_only` is the
       whole mechanism, and the API name is only how you spell it.
    2. THE DIGEST TRUNCATED TO THE LATEST VERDICT (`compose_digest/2` over
       `Enum.take(history, 1)`). 1 failure, on `digest.content =~ "--- Plan
       v1"`. Detected. FINDING: the v1-SPECIFIC assertions below it (the v1
       constraint literal, the v1 summary, the v1 stage name) are NEVER
       REACHED — the header assertion catches it first. Control 2b exists
       because of that.
    2b. THE FINDINGS BLANKED ON EVERY ROUND BUT THE NEWEST, headers kept —
       the subtler "older rounds are summarised, the newest gets detail"
       tidy, which a `"Plan v1"` check passes. 1 failure, on
       `digest.content =~ "cross_context_coupling"`, the v1 constraint
       literal. Detected, and this is the control that proves the digest
       carries the DISAGREEMENT rather than a list of version numbers.
    3. THE STACK TIER DROPPED (`escalation_recipient/1`'s `%Stack{}` clause
       removed). 1 failure, on `assert [row] = plan_review_rows(stack_sponsor.id)`
       — the POSITIVE half of the paired nil-sponsor test. Detected, and
       this is what makes the zero-row half of that test non-vacuous. The
       `recipient == "stack_sponsor"` assertion below it is not reached.
    4. THE INBOX ROUTED THROUGH `maybe_emit_plan_review_inbox/1`'s GATE
       (`auto_approve_plan == false` added to the emit condition) — the
       "reuse the existing producer" tidy, and the reason this stage emits
       directly. 3 failures: the mandatory detector's sponsor row, the
       paired test's stack-sponsor row, and the idempotence test's
       `rows_after_first == 1`. Detected: every fixture here runs
       `auto_approve_plan: true` precisely because the headless task is the
       one the row matters most on.
    5. `escalated?/1` REDUCED TO `escalation_due?/1` (the `pending_review`
       half dropped). 1 failure, on `refute ArchitectureRejection.escalated?`
       after the human approves. Detected — the streak stays at 2 forever
       after an escalation, so without the plan-status half member 8 would
       render "awaiting a human" for the rest of the task's life.
    6. THE GATE'S ONE-SHOT REMOVED (member 5's `:gate_already_resolved`
       clause AND the `WHERE state = 'pending'` fragment), so a second
       `:reject` re-enters `handle/1`. 2 failures, both on `{:error,
       :gate_already_resolved}`: this file's idempotence test and the loop
       file's "cannot reach handle/1 once a stage has started". Detected —
       and it confirms the claim the module makes instead of a dedup key.
       FINDING: the count-delta assertions below the return match are not
       reached, the same shape stage 3 measured on its control 1.
    7. `escalation_due?/1` FORCED TRUE — the bound collapsed in the opposite
       direction from stage 3's `>=` -> `>`, i.e. escalate on the FIRST
       rejection. 16 failures across all three files, 6 in this one.
       Detected. FINDING: none of the 6 fires on this file's BOUNDARY
       assertions (`digest_messages(space.id) == []` after round one) —
       they fire on return shapes and on `Tasks.create_plan/1` refusing a
       v2 while v1 is still `pending_review`, all of which precede the
       boundary. Control 8 exists because of that.
    8. THE HUMAN NOTIFIED ON EVERY ROUND (`send_feedback/1` also runs
       `escalate/2`) — the "surely the sponsor wants to know each time"
       mutation, which leaves every return shape and the whole feedback
       path intact. 4 failures, the first of them on
       `assert digest_messages(space.id) == []` in the mandatory detector.
       Detected, and this is the control that makes the below-the-limit
       absence assertions load-bearing.

  ### Assertions that pass trivially, declared rather than counted

    * `assert Repo.get!(Task, task.id).auto_approve_plan == true` and
      `assert task.sponsor_user_id == user.id` are FIXTURE assertions. They
      exist so the "not auto-approved" and "the sponsor was notified"
      assertions beside them are real, not accidents of a task that could
      never have auto-approved or a sponsor who was never set. On their own
      they assert nothing about this stage.
    * `assert row.source_type == "task"` / `row.url == "/tasks/..."` cannot
      fail for any mutation of the recipient chain or the digest — they pin
      the row SHAPE against a future edit, not this stage's behaviour.
    * In the third-edge-case test, `refute escalated?` is implied by
      `streak == 1`; it is asserted anyway because member 8 will read
      `escalated?/1` rather than the streak.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Inbox
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.ArchitectureRejection
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Stacks
  alias Platform.Tasks.Task

  @escalation_event [:platform, :plan, :architecture_reject_loop_escalated]

  defp u, do: System.unique_integer([:positive])

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Arch Escalation Project #{u()}"})
    %{project: project}
  end

  defp user_fixture do
    Repo.insert!(%Platform.Accounts.User{
      name: "Sponsor #{u()}",
      email: "arch-escalation-#{u()}@example.com",
      oidc_sub: "arch-escalation-sub-#{u()}"
    })
  end

  # `auto_approve_plan: true` throughout, and both `auto_approve_precondition/2`
  # legs satisfied: this is the HEADLESS task shape, the one where "the task
  # looks busy while nobody is coming" is the actual failure mode, and the
  # one `maybe_emit_plan_review_inbox/1`'s gate would suppress.
  defp task_fixture(project, opts \\ []) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Arch escalation task #{u()}",
        status: "planning",
        auto_approve_plan: true,
        sponsor_user_id: Keyword.get(opts, :sponsor_user_id),
        phase_assignees: %{
          "execution" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"},
          "review" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
        }
      })

    task
  end

  defp stack_fixture(project, sponsor_user_id) do
    slug = "arch-escalation-#{u()}"

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Arch escalation stack #{u()}",
        rollup_branch: slug,
        sponsor_user_id: sponsor_user_id
      })

    stack
  end

  # Written through the schema rather than `Tasks.update_task/2`: the context
  # writer runs the `task_sponsor_assigned` inbox producer, and this fixture
  # is used inside tests that COUNT inbox rows.
  defp attach_to_stack!(task, stack) do
    Repo.get!(Task, task.id) |> Task.changeset(%{stack_id: stack.id}) |> Repo.update!()
  end

  defp plan_fixture(task, stage_names) do
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

    stages =
      stage_names
      |> Enum.with_index(1)
      |> Enum.map(fn {name, position} ->
        {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: position, name: name})
        stage
      end)

    {Repo.get!(Plan, plan.id), stages}
  end

  defp open_gate!(task, plan, architect_id \\ nil) do
    {:ok, submitted} = plan |> Plan.changeset(%{status: "pending_review"}) |> Repo.update()
    {:ok, gated} = Tasks.open_architecture_gate(submitted, architect_id)
    {:ok, _task} = Tasks.set_planning_step(task.id, :architecting)
    gated
  end

  # History written straight onto a plan, bypassing the gate. Used ONLY to
  # set up prior versions; the version under test always goes through either
  # the real gate or `handle/1` itself.
  defp seed_verdict!(%Plan{} = plan, state, opts) do
    verdict = %{
      "state" => state,
      "summary" => Keyword.get(opts, :summary),
      "findings" => Keyword.get(opts, :findings, []),
      "resolved_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "resolved_by" => Keyword.get(opts, :resolved_by),
      "source" => "mcp"
    }

    plan
    |> Plan.architecture_verdict_changeset(%{architecture_verdict: verdict})
    |> Repo.update!()
  end

  # A version in the state a completed rejection leaves behind: `rejected`
  # status, `rejected` verdict. `status` is the real post-rejection value, so
  # the NEXT `Tasks.create_plan/1` is admitted (it refuses while the latest
  # version is still `draft` or `pending_review`).
  defp seed_rejected_history!(task, stage_names, opts) do
    {plan, stages} = plan_fixture(task, stage_names)

    seeded =
      plan
      |> Plan.changeset(%{status: Keyword.get(opts, :status, "rejected")})
      |> Repo.update!()
      |> seed_verdict!("rejected",
        summary: Keyword.get(opts, :summary),
        findings: Keyword.get(opts, :findings, [])
      )

    {seeded, stages}
  end

  defp finding(stage, constraint, detail) do
    %{"stage_id" => stage.id, "constraint" => constraint, "detail" => detail}
  end

  defp space_for!(task) do
    {:ok, space} = ExecutionSpace.find_or_create(task.id)
    space
  end

  defp messages_in(space_id) do
    Repo.all(from(m in Chat.Message, where: m.space_id == ^space_id, order_by: m.inserted_at))
  end

  # Selected by the digest's own header, NOT by metadata — see the moduledoc.
  defp digest_messages(space_id) do
    space_id
    |> messages_in()
    |> Enum.filter(&(&1.content =~ "Escalating to a human"))
  end

  defp rejection_messages(space_id) do
    space_id
    |> messages_in()
    |> Enum.filter(&(Map.get(&1.metadata || %{}, "reason") == "plan_rejected"))
  end

  defp plan_review_rows(user_id) do
    Inbox.list_unread_for_user(user_id, kind: "task_plan_review")
  end

  defp all_plan_review_row_count do
    Repo.aggregate(from(i in Inbox.Item, where: i.kind == "task_plan_review"), :count)
  end

  defp reload(%Plan{id: id}), do: Repo.get!(Plan, id)

  defp attach_telemetry do
    handler_id = "arch-escalation-#{u()}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      @escalation_event,
      fn event, measurements, metadata, pid ->
        send(pid, {:telemetry, event, measurements, metadata})
      end,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  defp reject!(gated, summary, findings) do
    Tasks.resolve_architecture_gate(gated, :reject,
      source: "mcp",
      summary: summary,
      findings: findings
    )
  end

  # ── DETECTOR (MANDATORY): the human is summoned, the planner is not ────

  describe "the escalation" do
    # The whole terminal state in one assertion block: v2 parked in
    # `pending_review` on a task that WOULD have auto-approved, one inbox row
    # for the sponsor, one log-only digest — and, below the limit, none of
    # those three. The boundary half is what stops this passing against an
    # implementation that escalates on every rejection.
    test "the second rejection parks v2, summons the sponsor and posts a log-only digest", %{
      project: project
    } do
      user = user_fixture()
      task = task_fixture(project, sponsor_user_id: user.id)
      assert task.sponsor_user_id == user.id

      space = space_for!(task)
      {v1, [v1_stage]} = plan_fixture(task, ["Round one stage"])
      gated_v1 = open_gate!(task, v1)

      assert {:ok, %Plan{status: "rejected"}} =
               reject!(gated_v1, "Round one", [
                 finding(v1_stage, "cross_context_coupling", "Split the context.")
               ])

      # THE BOUNDARY. One rejection is a conversation, not an escalation:
      # no digest, no inbox row. Asserted here rather than in a separate
      # test so it runs against the same fixture as the positive below.
      assert digest_messages(space.id) == []
      assert plan_review_rows(user.id) == []
      refute ArchitectureRejection.escalated?(task.id)

      {v2, [v2_stage]} = plan_fixture(task, ["Round two stage"])
      gated_v2 = open_gate!(task, v2)

      assert {:ok, %Plan{status: "pending_review"}} =
               reject!(gated_v2, "Round two", [
                 finding(v2_stage, "duplicated_logic", "Still duplicated.")
               ])

      # v2 is left for a human to act on: still pending_review, still
      # carrying the architect's objection, and NOT floated through by
      # `auto_approve_plan` — `maybe_auto_approve/1` runs only from
      # `settle_plan_submission/1`, which the `:reject` branch never calls.
      reloaded = reload(gated_v2)
      assert reloaded.status == "pending_review"
      assert reloaded.auto_approved_at == nil
      assert reloaded.approved_by == nil
      assert reloaded.rejection_reason == nil
      assert reloaded.architecture_verdict["state"] == "rejected"
      assert Repo.get!(Task, task.id).auto_approve_plan == true

      # THE SUMMONS: exactly one row, on the reused `task_plan_review` kind,
      # with a title that says which of the two this is.
      assert [row] = plan_review_rows(user.id)
      assert row.title == "Architecture escalation: #{task.title}"
      assert row.body =~ "2 consecutive architecture rejections"
      assert row.body =~ "v2, v1"
      assert row.source_type == "task"
      assert row.source_id == task.id
      assert row.url == "/tasks/#{task.id}"

      # THE DIGEST, and the half that stops the loop reopening.
      assert [digest] = digest_messages(space.id)
      assert digest.log_only == true
      assert digest.content =~ "2 consecutive rejections"

      assert ArchitectureRejection.escalated?(task.id)
    end

    # GUARD (PAIRED — the wake-up asymmetry). Neither half alone
    # distinguishes "we post logs" from "we post engagements": the first
    # rejection MUST wake the planner (it is the only thing that causes a v2
    # to be authored) and the second MUST NOT (a v3 is the spin the bound
    # exists to stop). Same test, same space, both directions.
    test "the first rejection posts a wake-up and the second posts a log", %{project: project} do
      task = task_fixture(project, sponsor_user_id: user_fixture().id)
      space = space_for!(task)
      {v1, [v1_stage]} = plan_fixture(task, ["Round one stage"])
      gated_v1 = open_gate!(task, v1)

      assert {:ok, _} =
               reject!(gated_v1, "Round one", [
                 finding(v1_stage, "module_boundary", "Two contexts.")
               ])

      newest = List.last(messages_in(space.id))
      assert newest.content =~ "iteration 1 of #{ArchitectureRejection.reject_limit()}"
      assert newest.log_only == false

      {v2, [v2_stage]} = plan_fixture(task, ["Round two stage"])
      gated_v2 = open_gate!(task, v2)

      assert {:ok, _} =
               reject!(gated_v2, "Round two", [
                 finding(v2_stage, "module_boundary", "Still two contexts.")
               ])

      newest = List.last(messages_in(space.id))
      assert newest.content =~ "Escalating to a human"
      assert newest.log_only == true

      # And the wake-up did not happen twice: the engagement post is the
      # planner's re-dispatch, so a second one IS a v3 request.
      assert length(rejection_messages(space.id)) == 1
    end

    # GUARD (the disagreement, not the verdict). A digest carrying only the
    # latest round reads perfectly well and answers the wrong question — the
    # human cannot tell "the planner ignored the objection" from "the planner
    # addressed it and drew a new one". Both rounds' constraint literals AND
    # both rounds' stage names, because the stage names are what the PLANNER
    # produced and the findings are what the ARCHITECT asked for.
    test "the digest carries every round: both versions, both sets of findings", %{
      project: project
    } do
      task = task_fixture(project, sponsor_user_id: user_fixture().id)
      space = space_for!(task)

      {v1, [v1_stage, _]} = plan_fixture(task, ["Parse the payload", "Persist the payload"])
      gated_v1 = open_gate!(task, v1)

      assert {:ok, _} =
               reject!(gated_v1, "v1 puts orchestration in the chat context.", [
                 finding(v1_stage, "cross_context_coupling", "Move the dispatch out of Chat.")
               ])

      {v2, [v2_stage]} = plan_fixture(task, ["Rewrite the walk"])
      gated_v2 = open_gate!(task, v2)

      assert {:ok, _} =
               reject!(gated_v2, "v2 reimplements the same walk twice.", [
                 finding(v2_stage, "duplicated_logic", "Extract the walk.")
               ])

      assert [digest] = digest_messages(space.id)

      # Newest first, and BOTH rounds present.
      assert digest.content =~ "--- Plan v2"
      assert digest.content =~ "--- Plan v1"

      v2_at = :binary.match(digest.content, "--- Plan v2") |> elem(0)
      v1_at = :binary.match(digest.content, "--- Plan v1") |> elem(0)
      assert v2_at < v1_at

      # The v1 half specifically. A truncated digest passes a naive check
      # for "a constraint literal" because v2 carries one too.
      assert digest.content =~ "cross_context_coupling"
      assert digest.content =~ "Move the dispatch out of Chat."
      assert digest.content =~ "v1 puts orchestration in the chat context."

      # …and at least one stage name from EACH version's plan. The verdicts
      # carried only a `stage_id`, so a name in the body can ONLY have come
      # from a lookup against that version's stages.
      assert digest.content =~ "Parse the payload"
      assert digest.content =~ "Persist the payload"
      assert digest.content =~ "Rewrite the walk"
      assert digest.content =~ ~s(@ "Parse the payload")

      # The v2 half, and the decision the human actually has to make.
      assert digest.content =~ "duplicated_logic"
      assert digest.content =~ "Plan v2 is still awaiting review at /tasks/#{task.id}"
    end

    # GUARD (PAIRED — the recipient chain's floor and its middle tier).
    # The zero-row half is an ABSENCE assertion, which is worth nothing
    # without a positive on the same mechanism: the stack-sponsor half runs
    # the identical fixture with a stack attached and expects exactly one
    # row. Both halves also assert the telemetry, because `recipient` is how
    # an operator finds out that a task escalated to nobody.
    test "no sponsor and no stack notifies nobody; a stack sponsor is notified", %{
      project: project
    } do
      attach_telemetry()

      # TIER 3: nobody. There is no admin/owner concept to fall back to and
      # `task.reported_by` is not a user id, so the honest answer is no row.
      orphan = task_fixture(project)
      assert orphan.sponsor_user_id == nil
      assert orphan.stack_id == nil
      orphan_space = space_for!(orphan)

      seed_rejected_history!(orphan, ["Orphan v1 stage"],
        summary: "Orphan round one",
        findings: [
          %{"stage_id" => nil, "constraint" => "data_model", "detail" => "Normalise it."}
        ]
      )

      {orphan_v2, [orphan_v2_stage]} =
        seed_rejected_history!(orphan, ["Orphan v2 stage"], status: "pending_review")

      orphan_v2 =
        seed_verdict!(orphan_v2, "rejected",
          summary: "Orphan round two",
          findings: [finding(orphan_v2_stage, "data_model", "Still denormalised.")]
        )

      before_rows = all_plan_review_row_count()

      assert {:ok, :escalated, %Plan{status: "pending_review"}} =
               ArchitectureRejection.handle(orphan_v2)

      # Nobody was notified — and nothing else was skipped because of it.
      assert all_plan_review_row_count() == before_rows
      assert [orphan_digest] = digest_messages(orphan_space.id)
      assert orphan_digest.log_only == true

      assert_receive {:telemetry, @escalation_event, %{count: 1}, orphan_meta}
      assert orphan_meta.recipient == "none"
      assert orphan_meta.iterations == 2
      assert orphan_meta.task_id == orphan.id
      assert orphan_meta.plan_id == orphan_v2.id
      assert orphan_meta.action == "architecture_escalated"
      assert orphan_meta.actor_type == "system"

      # POSITIVE CONTROL, same mechanism: a task with no sponsor of its own
      # but a stack that HAS one. A stack member inherits its stack's
      # sponsor — this stack is itself configured that way.
      stack_sponsor = user_fixture()
      stack = stack_fixture(project, stack_sponsor.id)
      member = task_fixture(project)
      attach_to_stack!(member, stack)
      member_space = space_for!(member)

      seed_rejected_history!(member, ["Member v1 stage"], summary: "Member round one")

      {member_v2, [member_v2_stage]} =
        seed_rejected_history!(member, ["Member v2 stage"], status: "pending_review")

      member_v2 =
        seed_verdict!(member_v2, "rejected",
          summary: "Member round two",
          findings: [finding(member_v2_stage, "module_boundary", "Two contexts.")]
        )

      assert {:ok, :escalated, _} = ArchitectureRejection.handle(member_v2)

      assert [row] = plan_review_rows(stack_sponsor.id)
      assert row.title == "Architecture escalation: #{member.title}"
      assert row.source_id == member.id
      assert [_digest] = digest_messages(member_space.id)

      assert_receive {:telemetry, @escalation_event, %{count: 1}, stack_meta}
      assert stack_meta.recipient == "stack_sponsor"
      assert stack_meta.task_id == member.id
    end

    # GUARD (idempotence at the boundary, asserted as a count DELTA). The
    # gate is one-shot — `record_architecture_verdict/3` arbitrates with an
    # `UPDATE ... WHERE state = 'pending'` — so a second `:reject` never
    # reaches `handle/1` and no dedup key is needed inside this module.
    # That is a claim about the CALLER, so it is asserted from outside.
    test "a second :reject on a resolved gate escalates nothing twice", %{project: project} do
      user = user_fixture()
      task = task_fixture(project, sponsor_user_id: user.id)
      space = space_for!(task)

      {v1, [v1_stage]} = plan_fixture(task, ["Round one stage"])
      gated_v1 = open_gate!(task, v1)
      assert {:ok, _} = reject!(gated_v1, "Round one", [finding(v1_stage, "data_model", "d")])

      {v2, [v2_stage]} = plan_fixture(task, ["Round two stage"])
      gated_v2 = open_gate!(task, v2)
      assert {:ok, _} = reject!(gated_v2, "Round two", [finding(v2_stage, "data_model", "d")])

      rows_after_first = length(plan_review_rows(user.id))
      digests_after_first = length(digest_messages(space.id))
      assert rows_after_first == 1
      assert digests_after_first == 1

      assert {:error, :gate_already_resolved} =
               reject!(reload(gated_v2), "Round two again", [
                 finding(v2_stage, "data_model", "d")
               ])

      assert length(plan_review_rows(user.id)) == rows_after_first
      assert length(digest_messages(space.id)) == digests_after_first
    end
  end

  # ── GUARD: the counter does not carry into an unrelated argument ───────

  describe "the third edge case" do
    # Architect rejects v1, PASSES v2, a human later rejects v2 with their
    # own direction, the planner writes v3, the architect objects again.
    # That objection is a FRESH disagreement — the pass settled the old one
    # — so v3 must take the feedback path, not the escalation path. Run end
    # to end through the real API because the whole risk is that some other
    # writer (the approval, the human rejection) leaves state behind.
    test "an architect pass ends the streak, so a later rejection asks for a v4", %{
      project: project
    } do
      user = user_fixture()
      task = task_fixture(project, sponsor_user_id: user.id)
      space = space_for!(task)

      {v1, [v1_stage]} = plan_fixture(task, ["V1 stage"])
      gated_v1 = open_gate!(task, v1)

      assert {:ok, %Plan{status: "rejected"}} =
               reject!(gated_v1, "Round one", [finding(v1_stage, "module_boundary", "Split it.")])

      # v2 PASSES the gate and auto-approves (the task is headless).
      {v2, _} = plan_fixture(task, ["V2 stage"])
      gated_v2 = open_gate!(task, v2)
      assert {:ok, _} = Tasks.resolve_architecture_gate(gated_v2, :pass, source: "mcp")
      assert reload(gated_v2).status == "approved"

      # The human rejects it later with their own direction.
      assert {:ok, %Plan{status: "rejected"}} =
               Tasks.reject_plan(reload(gated_v2), user.id, "Not what I asked for.")

      # Approval ran `apply_dispatch_gate/1`, which moves a `planning` task
      # into execution; the reopen path (`reopen_with_feedback/3`) is what
      # normally puts it back. Done explicitly so the assertion below is
      # about the STREAK — without it stage 3's in-flight guard would refuse
      # first and this test would pass for the wrong reason.
      Repo.get!(Task, task.id) |> Task.changeset(%{status: "planning"}) |> Repo.update!()

      {v3, [v3_stage]} = plan_fixture(task, ["V3 stage"])
      gated_v3 = open_gate!(task, v3)

      assert {:ok, %Plan{status: "rejected"}} =
               reject!(gated_v3, "Round three", [
                 finding(v3_stage, "module_boundary", "Still two contexts.")
               ])

      # ONE rejection in the current run, not three: the pass ended the
      # first argument.
      assert ArchitectureRejection.streak(task.id) == 1
      refute ArchitectureRejection.escalation_due?(task.id)
      refute ArchitectureRejection.escalated?(task.id)

      # v3 took the FEEDBACK path — persisted reason, engagement posted…
      reloaded_v3 = reload(gated_v3)
      assert reloaded_v3.rejection_reason =~ "Still two contexts."
      assert reloaded_v3.rejection_reason =~ "iteration 1 of"

      wake_ups = rejection_messages(space.id)
      assert length(wake_ups) == 2
      assert List.last(wake_ups).log_only == false

      # …and NOTHING escalated.
      assert plan_review_rows(user.id) == []
      assert digest_messages(space.id) == []
    end
  end

  # ── GUARD: the flag member 8 will render ──────────────────────────────

  describe "escalated?/1" do
    # False, then true, then false again. The last transition is the one
    # that needs the `pending_review` half: the streak stays at 2 after the
    # human answers, because approving does not rewrite v2's verdict (the
    # gate is already resolved and refuses a second write). Reading
    # `escalation_due?/1` alone would leave the task flagged forever.
    test "goes true at the bound and false again once a human decides", %{project: project} do
      user = user_fixture()
      task = task_fixture(project, sponsor_user_id: user.id)
      _space = space_for!(task)

      {v1, [v1_stage]} = plan_fixture(task, ["Round one stage"])
      gated_v1 = open_gate!(task, v1)
      assert {:ok, _} = reject!(gated_v1, "Round one", [finding(v1_stage, "data_model", "d")])

      refute ArchitectureRejection.escalated?(task.id)

      {v2, [v2_stage]} = plan_fixture(task, ["Round two stage"])
      gated_v2 = open_gate!(task, v2)
      assert {:ok, _} = reject!(gated_v2, "Round two", [finding(v2_stage, "data_model", "d")])

      assert ArchitectureRejection.escalated?(task.id)

      # The human approves over the architect's objection. The gate guard is
      # INERT (the gate is resolved, not open), so this is an ordinary
      # approval — no override recorded, no verdict rewritten.
      assert {:ok, %Plan{status: "approved"}} = Tasks.approve_plan(reload(gated_v2), user.id)

      assert reload(gated_v2).architecture_verdict["state"] == "rejected"
      assert ArchitectureRejection.streak(task.id) == 2
      assert ArchitectureRejection.escalation_due?(task.id)
      refute ArchitectureRejection.escalated?(task.id)
    end
  end
end
