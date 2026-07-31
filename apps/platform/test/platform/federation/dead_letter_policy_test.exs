defmodule Platform.Federation.DeadLetterPolicyTest do
  use Platform.DataCase, async: true

  alias Platform.Federation.DeadLetter
  alias Platform.Federation.DeadLetterPolicy
  alias Platform.Federation.DeadLetters
  alias Platform.Repo
  alias Platform.Responsibilities.Responsibility
  alias Platform.Tasks
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Stage

  # ── Fixtures ─────────────────────────────────────────────────────────
  #
  # `classify/1` is a pure function of a row plus the SUBJECT's state in
  # Postgres, so the subject rows below are real. The `%DeadLetter{}` itself
  # is built in memory (with the string-valued `trigger_kind` the column
  # actually holds); "record/1 produces a row classify/1 agrees with" below is
  # the bridge test that pins the in-memory shape to the persisted one.

  defp row(attrs) do
    struct!(
      %DeadLetter{
        runtime_id: "rt-policy",
        source: "system_event",
        responsibility_key: "architecture.audit_diff",
        feature: "architecture",
        trigger_kind: "event_topic",
        payload: %{"signal" => %{"reason" => "system_event", "metadata" => %{}}},
        disposition: "pending",
        attempts: 0,
        occurred_at: DateTime.utc_now()
      },
      attrs
    )
  end

  defp audit_diff_subject do
    suffix = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Policy Project #{suffix}"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Policy Task #{suffix}"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

    {:ok, stage} =
      Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build", status: "passed"})

    %{project: project, task: task, plan: plan, stage: stage}
  end

  defp audit_diff_row(%{stage: stage}, overrides \\ %{}) do
    row(Map.merge(%{subject_type: "stage", subject_id: stage.id}, overrides))
  end

  defp review_plan_subject do
    suffix = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Review Project #{suffix}"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Review Task #{suffix}"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "pending_review"})

    %{project: project, task: task, plan: plan}
  end

  defp review_plan_row(%{plan: plan}, overrides \\ %{}) do
    row(
      Map.merge(
        %{
          responsibility_key: "architecture.review_plan",
          subject_type: "plan",
          subject_id: plan.id
        },
        overrides
      )
    )
  end

  # The lifecycle guards in `Tasks.update_task/2` are not under test here and
  # would refuse some of these jumps; the schema changeset is the narrowest
  # way to put the SUBJECT in the state whose staleness we are ruling on.
  defp force_status!(%Stage{} = stage, status) do
    stage |> Stage.changeset(%{status: status}) |> Repo.update!()
  end

  defp force_status!(%Plan{} = plan, status) do
    plan |> Plan.changeset(%{status: status}) |> Repo.update!()
  end

  defp force_task_status!(task, status) do
    task |> Platform.Tasks.Task.changeset(%{status: status}) |> Repo.update!()
  end

  # ── The trigger_kind table ───────────────────────────────────────────

  describe "classify/1 per trigger_kind" do
    test "cron never replays — it is self-healing, not merely stale" do
      assert {:drop, :stale_by_wall_clock} =
               DeadLetterPolicy.classify(
                 row(%{
                   trigger_kind: "cron",
                   responsibility_key: "memory.dreaming",
                   subject_type: nil,
                   subject_id: nil
                 })
               )
    end

    test "webhook is declined as an unvalidated kind in v1" do
      assert {:drop, :unvalidated_kind} =
               DeadLetterPolicy.classify(
                 row(%{trigger_kind: "webhook", responsibility_key: "ci.build_finished"})
               )
    end

    test "chat_pattern is declined because its envelope is derived, not scalar" do
      assert {:drop, :chat_payload_not_replayable} =
               DeadLetterPolicy.classify(row(%{trigger_kind: "chat_pattern"}))
    end

    test "any chat-sourced row is declined regardless of trigger_kind" do
      assert {:drop, :chat_payload_not_replayable} =
               DeadLetterPolicy.classify(row(%{source: "chat", trigger_kind: nil, payload: nil}))

      # Even if a chat row somehow carried an event_topic kind and a payload,
      # source wins — the chat envelope is not replayable by construction.
      assert {:drop, :chat_payload_not_replayable} =
               DeadLetterPolicy.classify(row(%{source: "chat", trigger_kind: "event_topic"}))
    end

    test "a nil or unrecognised trigger_kind is DENIED by default" do
      assert {:drop, :unclassified} = DeadLetterPolicy.classify(row(%{trigger_kind: nil}))
      assert {:drop, :unclassified} = DeadLetterPolicy.classify(row(%{trigger_kind: ""}))

      assert {:drop, :unclassified} =
               DeadLetterPolicy.classify(row(%{trigger_kind: "telepathy"}))
    end

    test "event_topic with a registered predicate and a fresh subject REPLAYS" do
      subject = audit_diff_subject()

      assert :replay = DeadLetterPolicy.classify(audit_diff_row(subject))
    end

    test "event_topic with no registered predicate drops rather than replaying blind" do
      assert {:drop, :no_freshness_predicate} =
               DeadLetterPolicy.classify(
                 row(%{
                   responsibility_key: "meetings.summarize_transcript",
                   subject_type: "task",
                   subject_id: Ecto.UUID.generate()
                 })
               )

      # And a nil key is not a wildcard into the registry.
      assert {:drop, :no_freshness_predicate} =
               DeadLetterPolicy.classify(row(%{responsibility_key: nil}))
    end

    test "an event_topic row whose payload cannot rebuild an envelope drops" do
      subject = audit_diff_subject()

      # Positive twin first: the same subject with a real payload replays, so
      # the drop below is about the payload and nothing else.
      assert :replay = DeadLetterPolicy.classify(audit_diff_row(subject))

      assert {:drop, :no_replayable_payload} =
               DeadLetterPolicy.classify(audit_diff_row(subject, %{payload: nil}))

      assert {:drop, :no_replayable_payload} =
               DeadLetterPolicy.classify(
                 audit_diff_row(subject, %{payload: %{"not_a_signal" => true}})
               )
    end

    test "every declared trigger_kind has a ruling — a new kind turns this red" do
      for kind <- Responsibility.trigger_kinds() do
        result = DeadLetterPolicy.classify(row(%{trigger_kind: kind}))

        refute result == {:drop, :unclassified},
               "trigger_kind #{inspect(kind)} has no ruling in DeadLetterPolicy"
      end
    end
  end

  # ── The closed drop vocabulary ───────────────────────────────────────

  describe "drop_reasons/0" do
    test "partitions exactly into policy refusals and staleness findings" do
      policy = DeadLetterPolicy.policy_drop_reasons()
      stale = DeadLetterPolicy.stale_drop_reasons()

      assert Enum.sort(policy ++ stale) == Enum.sort(DeadLetterPolicy.drop_reasons())
      assert policy -- stale == policy, "a reason cannot be both a policy refusal and stale"
    end

    test "disposition_for/1 is total over the vocabulary and lands in the schema's" do
      dispositions = DeadLetter.dispositions()

      for reason <- DeadLetterPolicy.drop_reasons() do
        disposition = DeadLetterPolicy.disposition_for(reason)
        assert disposition in dispositions
        assert disposition in ["dropped_policy", "dropped_stale"]
      end

      assert DeadLetterPolicy.disposition_for(:stale_by_wall_clock) == "dropped_policy"
      assert DeadLetterPolicy.disposition_for(:subject_superseded) == "dropped_stale"
      assert DeadLetterPolicy.disposition_for(:gate_already_settled) == "dropped_stale"
    end

    test "every reason classify/1 can emit is in the closed list" do
      subject = audit_diff_subject()
      review = review_plan_subject()

      emitted =
        [
          row(%{trigger_kind: "cron"}),
          row(%{trigger_kind: "webhook"}),
          row(%{trigger_kind: "chat_pattern"}),
          row(%{trigger_kind: "telepathy"}),
          row(%{responsibility_key: "meetings.summarize_transcript"}),
          audit_diff_row(subject, %{payload: nil}),
          audit_diff_row(subject, %{subject_id: Ecto.UUID.generate()}),
          review_plan_row(review, %{subject_id: Ecto.UUID.generate()})
        ]
        |> Enum.map(&DeadLetterPolicy.classify/1)
        |> Enum.map(fn {:drop, reason} -> reason end)
        |> Enum.uniq()

      assert emitted != []
      assert emitted -- DeadLetterPolicy.drop_reasons() == []
    end
  end

  # ── architecture.audit_diff freshness, both directions ───────────────

  describe "architecture.audit_diff freshness" do
    test "a stage re-opened for execution is no longer a subject worth auditing" do
      subject = audit_diff_subject()

      assert :replay = DeadLetterPolicy.classify(audit_diff_row(subject))

      force_status!(subject.stage, "running")

      assert {:drop, :subject_superseded} = DeadLetterPolicy.classify(audit_diff_row(subject))
    end

    test "a stage whose plan is no longer the task's current plan is superseded" do
      subject = audit_diff_subject()

      assert :replay = DeadLetterPolicy.classify(audit_diff_row(subject))

      # A genuine second plan version, exactly the ADR-0046 reject-then-replan
      # shape `Tasks.current_plan/1` was scoped to in commit ca2d183c.
      {:ok, v2} = Tasks.create_plan(%{task_id: subject.task.id, status: "approved"})
      assert v2.version == subject.plan.version + 1
      assert Tasks.current_plan(subject.task.id).id == v2.id

      assert {:drop, :subject_superseded} = DeadLetterPolicy.classify(audit_diff_row(subject))
    end

    test "a cancelled task's stage is not re-audited" do
      subject = audit_diff_subject()

      assert :replay = DeadLetterPolicy.classify(audit_diff_row(subject))

      force_task_status!(subject.task, "cancelled")

      assert {:drop, :subject_superseded} = DeadLetterPolicy.classify(audit_diff_row(subject))
    end

    test "a deleted or unknown stage cannot be proven current, so it drops" do
      subject = audit_diff_subject()

      assert :replay = DeadLetterPolicy.classify(audit_diff_row(subject))

      assert {:drop, :subject_superseded} =
               DeadLetterPolicy.classify(
                 audit_diff_row(subject, %{subject_id: Ecto.UUID.generate()})
               )

      assert {:drop, :subject_superseded} =
               DeadLetterPolicy.classify(
                 audit_diff_row(subject, %{subject_type: nil, subject_id: nil})
               )
    end

    test "a malformed subject id drops instead of raising out of the drain" do
      subject = audit_diff_subject()

      assert :replay = DeadLetterPolicy.classify(audit_diff_row(subject))

      # `Repo.get/2` RAISES Ecto.Query.CastError on a malformed id. Raising
      # here would abort stage 3's whole drain for the runtime, so one bad row
      # would withhold every good one — see repo_lookup_boundary_test.exs.
      assert {:drop, :subject_superseded} =
               DeadLetterPolicy.classify(audit_diff_row(subject, %{subject_id: "not-a-uuid"}))
    end

    test "a fire naming a plan rather than a stage is not an audit_diff subject" do
      subject = audit_diff_subject()

      assert {:drop, :subject_superseded} =
               DeadLetterPolicy.classify(
                 audit_diff_row(subject, %{subject_type: "plan", subject_id: subject.plan.id})
               )
    end
  end

  # ── architecture.review_plan freshness, both directions ──────────────

  describe "architecture.review_plan freshness" do
    test "an open gate replays and a settled one does not — the 07-27 expired case" do
      subject = review_plan_subject()

      # No gate opened yet: nothing has ruled, so the review is still wanted.
      assert :replay = DeadLetterPolicy.classify(review_plan_row(subject))

      {:ok, opened} = Tasks.open_architecture_gate(subject.plan)
      assert opened.architecture_verdict["state"] == "pending"
      assert :replay = DeadLetterPolicy.classify(review_plan_row(subject))

      # The documented case: the 15-minute deadline settled the gate while the
      # architect's runtime was offline. Replaying now asks for a second
      # verdict on a decided plan.
      {:ok, _} =
        Tasks.record_architecture_verdict(opened, %{"state" => "expired"}, source: "deadline")

      assert Repo.get!(Plan, subject.plan.id).architecture_verdict["state"] == "expired"

      assert {:drop, :gate_already_settled} =
               DeadLetterPolicy.classify(review_plan_row(subject))
    end

    test "a gate past its deadline but not yet written is ALSO settled" do
      subject = review_plan_subject()

      {:ok, opened} = Tasks.open_architecture_gate(subject.plan)
      assert :replay = DeadLetterPolicy.classify(review_plan_row(subject))

      # `Tasks.architecture_gate/1` is level-triggered: an overdue pending
      # verdict reads as expired WITHOUT being written. A predicate reading
      # the raw column would replay here and contradict every other reader.
      overdue =
        Map.put(
          opened.architecture_verdict,
          "deadline_at",
          DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
        )

      {:ok, _} =
        opened
        |> Plan.architecture_verdict_changeset(%{architecture_verdict: overdue})
        |> Repo.update()

      assert Repo.get!(Plan, subject.plan.id).architecture_verdict["state"] == "pending"
      assert {:resolved, %{"state" => "expired"}} = Tasks.architecture_gate(subject.plan.id)

      assert {:drop, :gate_already_settled} =
               DeadLetterPolicy.classify(review_plan_row(subject))
    end

    test "a superseded plan version is not reviewed" do
      subject = review_plan_subject()

      assert :replay = DeadLetterPolicy.classify(review_plan_row(subject))

      # Inserted through the schema rather than `Tasks.create_plan/1`, which
      # refuses a second version while v1 is still pending_review. Only
      # latest-ness changes here; v1's own status and gate are untouched.
      {:ok, v2} =
        %Plan{}
        |> Plan.changeset(%{
          task_id: subject.task.id,
          version: subject.plan.version + 1,
          status: "pending_review"
        })
        |> Repo.insert()

      assert Tasks.latest_plan(subject.task.id).id == v2.id

      assert {:drop, :subject_superseded} = DeadLetterPolicy.classify(review_plan_row(subject))
    end

    test "a plan that has left pending_review is not reviewed" do
      subject = review_plan_subject()

      assert :replay = DeadLetterPolicy.classify(review_plan_row(subject))

      force_status!(subject.plan, "approved")

      assert {:drop, :subject_superseded} = DeadLetterPolicy.classify(review_plan_row(subject))
    end

    test "a deleted, unknown or malformed plan id cannot be proven current" do
      subject = review_plan_subject()

      assert :replay = DeadLetterPolicy.classify(review_plan_row(subject))

      assert {:drop, :subject_superseded} =
               DeadLetterPolicy.classify(
                 review_plan_row(subject, %{subject_id: Ecto.UUID.generate()})
               )

      assert {:drop, :subject_superseded} =
               DeadLetterPolicy.classify(review_plan_row(subject, %{subject_id: "not-a-uuid"}))

      assert {:drop, :subject_superseded} =
               DeadLetterPolicy.classify(
                 review_plan_row(subject, %{subject_type: nil, subject_id: nil})
               )
    end
  end

  # ── The registry, and the bridge to the persisted row ────────────────

  describe "freshness_predicate_keys/0" do
    test "names exactly the keys that can reach a predicate" do
      keys = DeadLetterPolicy.freshness_predicate_keys()

      assert "architecture.audit_diff" in keys
      assert "architecture.review_plan" in keys

      # Every registered key is dispatchable: none falls through to
      # :no_freshness_predicate, and none raises.
      for key <- keys do
        result =
          DeadLetterPolicy.classify(
            row(%{
              responsibility_key: key,
              subject_type: "stage",
              subject_id: Ecto.UUID.generate()
            })
          )

        refute result == {:drop, :no_freshness_predicate}
      end
    end
  end

  describe "record/1 produces a row classify/1 agrees with" do
    test "a persisted row classifies the same as the in-memory one" do
      subject = audit_diff_subject()

      envelope = %{
        signal: %{
          reason: :system_event,
          agent_id: Ecto.UUID.generate(),
          agent_slug: "moore",
          responsibility_key: "architecture.audit_diff",
          feature: "architecture",
          trigger_kind: :event_topic,
          prompt: "Audit the diff.",
          metadata: %{
            responsibility_key: "architecture.audit_diff",
            feature: "architecture",
            trigger_kind: :event_topic,
            task_id: subject.task.id,
            plan_id: subject.plan.id,
            stage_id: subject.stage.id
          }
        }
      }

      {:ok, inserted} =
        DeadLetters.record(%{
          runtime_id: "rt-bridge-#{System.unique_integer([:positive])}",
          source: "system_event",
          responsibility_key: "architecture.audit_diff",
          feature: "architecture",
          trigger_kind: :event_topic,
          payload: envelope,
          reason: "runtime_offline",
          metadata: envelope.signal.metadata
        })

      persisted = Repo.get!(DeadLetter, inserted.id)

      assert persisted.subject_type == "stage"
      assert persisted.subject_id == subject.stage.id
      assert persisted.trigger_kind == "event_topic"
      assert :replay = DeadLetterPolicy.classify(persisted)

      # And the same row goes stale for the same reason once its subject does.
      force_status!(subject.stage, "failed")
      assert {:drop, :subject_superseded} = DeadLetterPolicy.classify(persisted)
    end
  end
end
