defmodule Platform.Architecture.StageAuditTest do
  @moduledoc """
  Unit cover for `Platform.Architecture.StageAudit` (task `019fa61c`
  stage 2).

  The end-to-end detector lives in
  `test/platform/responsibilities/architecture_audit_diff_native_artefact_test.exs`
  and drives the real plan-engine hook. This file exercises the parts of
  the module that hook cannot reach from a live fire: the level-triggered
  expiry projection, the deadline knob, and the rescue that keeps an
  unmapped fire shape from silently writing nothing.

  Not `async: true` — several cases set the module-level
  `:architecture_audit_timeout_ms` app env.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Architecture.StageAudit
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Stage

  setup do
    previous = Application.get_env(:platform, :architecture_audit_timeout_ms)

    on_exit(fn ->
      if previous do
        Application.put_env(:platform, :architecture_audit_timeout_ms, previous)
      else
        Application.delete_env(:platform, :architecture_audit_timeout_ms)
      end
    end)

    {:ok, project} = Tasks.create_project(%{name: "Stage Audit Unit Project"})

    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "Stage Audit", status: "in_progress"})

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Unit stage",
        description: "Edit only apps/platform/lib/platform/architecture/stage_audit.ex."
      })

    %{project: project, task: task, plan: plan, stage: stage}
  end

  defp reload(stage), do: Repo.get!(Stage, stage.id)

  # ── timeout_ms/0 ─────────────────────────────────────────────────────

  describe "timeout_ms/0" do
    test "defaults to 30 minutes" do
      Application.delete_env(:platform, :architecture_audit_timeout_ms)
      assert StageAudit.timeout_ms() == 30 * 60 * 1_000
    end

    test "is overridable per-environment (stage 5's e2e cases need it near zero)" do
      Application.put_env(:platform, :architecture_audit_timeout_ms, 1_000)
      assert StageAudit.timeout_ms() == 1_000
    end
  end

  # ── open_from_fire/2 ─────────────────────────────────────────────────

  describe "open_from_fire/2" do
    test "a dispatched fire opens the audit at pending with a deadline in the future", %{
      stage: stage,
      task: task,
      plan: plan
    } do
      Application.put_env(:platform, :architecture_audit_timeout_ms, 60_000)

      assert {:ok, updated} = StageAudit.open_from_fire(stage, {:ok, :dispatched})

      audit = updated.architecture_audit
      assert audit["state"] == "pending"
      assert audit["stage_id"] == stage.id
      assert audit["task_id"] == task.id
      assert audit["plan_id"] == plan.id
      assert audit["resolved_at"] == nil

      {:ok, dispatched_at, _} = DateTime.from_iso8601(audit["dispatched_at"])
      {:ok, deadline_at, _} = DateTime.from_iso8601(audit["deadline_at"])

      # Exactly `timeout_ms/0` apart, not merely "later" — a deadline
      # derived from the wrong clock or the wrong unit still reads as
      # "in the future" and would pass a laxer assertion.
      assert DateTime.diff(deadline_at, dispatched_at, :millisecond) == 60_000
      assert DateTime.compare(deadline_at, DateTime.utc_now()) == :gt
    end

    test "writes every required key, nil-valued where there is nothing yet", %{stage: stage} do
      {:ok, updated} = StageAudit.open_from_fire(stage, {:ok, :dispatched})

      # Against the schema's accessor, so the list and its enforcement
      # cannot drift apart.
      for key <- Stage.architecture_audit_required_keys() do
        assert Map.has_key?(updated.architecture_audit, key),
               "missing required key #{inspect(key)}"
      end
    end

    test "the two not_applicable fire shapes share a state but keep distinct reasons", %{
      stage: stage
    } do
      {:ok, unfilled} = StageAudit.open_from_fire(stage, {:ok, :unfilled})
      assert unfilled.architecture_audit["state"] == "skipped"
      assert unfilled.architecture_audit["reason"] == "unfilled"

      {:ok, unknown} = StageAudit.open_from_fire(reload(stage), {:ok, :unknown_responsibility})
      assert unknown.architecture_audit["state"] == "skipped"
      assert unknown.architecture_audit["reason"] == "unknown_responsibility"

      # The point: same bucket, different discriminator. Collapsing these
      # would rebuild the invisibility one level down.
      assert unfilled.architecture_audit["state"] == unknown.architecture_audit["state"]
      refute unfilled.architecture_audit["reason"] == unknown.architecture_audit["reason"]
    end

    test "an error fire records failed and carries the reason verbatim", %{stage: stage} do
      {:ok, updated} =
        StageAudit.open_from_fire(stage, {:error, {:dispatch_failed, :timeout}})

      assert updated.architecture_audit["state"] == "failed"
      assert updated.architecture_audit["reason"] == "{:dispatch_failed, :timeout}"
      # Terminal, so resolved the moment it was classified — nothing
      # further will arrive for it.
      assert is_binary(updated.architecture_audit["resolved_at"])
    end

    test "terminal states are resolved and pending is not", %{stage: stage} do
      {:ok, pending} = StageAudit.open_from_fire(stage, {:ok, :dispatched})
      assert pending.architecture_audit["resolved_at"] == nil

      {:ok, skipped} = StageAudit.open_from_fire(reload(stage), {:ok, :unfilled})
      assert is_binary(skipped.architecture_audit["resolved_at"])

      {:ok, failed} = StageAudit.open_from_fire(reload(stage), {:error, :boom})
      assert is_binary(failed.architecture_audit["resolved_at"])
    end

    test "`source` is nil for every fire — a fire is not a result", %{stage: stage} do
      for fire <- [{:ok, :dispatched}, {:ok, :unfilled}, {:error, :boom}] do
        {:ok, updated} = StageAudit.open_from_fire(reload(stage), fire)
        assert updated.architecture_audit["source"] == nil
      end
    end

    # `Responsibilities.outcome/1` has no catch-all and raises on an
    # unrecognised shape. That is correct for it and fatal here: the call
    # site is inside `evaluate_validation/2`'s transaction, and writing
    # NOTHING on rescue would restore the invisibility this task exists
    # to remove — a fire contract that grew a new value would go straight
    # back to looking like no fire at all.
    test "an unmapped fire shape is recorded as failed rather than dropped", %{stage: stage} do
      log =
        capture_log([level: :warning], fn ->
          assert {:ok, updated} = StageAudit.open_from_fire(stage, {:ok, :teleported})
          send(self(), {:audit, updated.architecture_audit})
        end)

      assert_received {:audit, audit}

      assert audit["state"] == "failed"
      assert audit["reason"] == "outcome_unmapped:{:ok, :teleported}"
      assert log =~ "no outcome mapping"

      # CONTROL that the probe can fire at all: the same call with a
      # SHAPE `outcome/1` does know must not take the rescue path. Without
      # this, a rescue that swallowed every input would pass the
      # assertions above.
      {:ok, mapped} = StageAudit.open_from_fire(reload(stage), {:ok, :dispatched})
      assert mapped.architecture_audit["state"] == "pending"
      refute mapped.architecture_audit["reason"]
    end

    test "a stage whose plan row is gone still records the fire, with a nil task_id", %{
      stage: stage,
      plan: plan
    } do
      # `after_stage_completed/1` documents that `plan` CAN be nil. A
      # `task_id` lookup that raised would record nothing, which is the
      # state this module exists to make impossible. DDL is transactional
      # and this case runs inside the DataCase sandbox transaction.
      Ecto.Adapters.SQL.query!(Repo, "ALTER TABLE stages DROP CONSTRAINT stages_plan_id_fkey")
      {1, _} = Repo.delete_all(from(p in Platform.Tasks.Plan, where: p.id == ^plan.id))

      assert {:ok, updated} = StageAudit.open_from_fire(stage, {:ok, :dispatched})
      assert updated.architecture_audit["state"] == "pending"
      assert updated.architecture_audit["stage_id"] == stage.id
      assert updated.architecture_audit["task_id"] == nil
    end
  end

  # ── read/1 ───────────────────────────────────────────────────────────

  describe "read/1" do
    test "returns :none when no fire was ever recorded", %{stage: stage} do
      assert StageAudit.read(stage) == :none
      assert StageAudit.read(stage.id) == :none
    end

    test "returns :none for an unknown or malformed id" do
      assert StageAudit.read(Ecto.UUID.generate()) == :none
      assert StageAudit.read("not-a-uuid") == :none
      assert StageAudit.read(nil) == :none
    end

    test "an in-deadline pending audit reads open; a past-deadline one reads expired", %{
      stage: stage
    } do
      # PAIRED, on the same construction. A bare "past deadline reads
      # expired" passes identically against a projection that reports
      # expired unconditionally.
      Application.put_env(:platform, :architecture_audit_timeout_ms, 60_000)
      {:ok, _} = StageAudit.open_from_fire(stage, {:ok, :dispatched})

      assert {:open, open_audit} = StageAudit.read(stage.id)
      assert open_audit["state"] == "pending"
      refute Map.has_key?(open_audit, "expired_note")

      Application.put_env(:platform, :architecture_audit_timeout_ms, 1)
      {:ok, _} = StageAudit.open_from_fire(reload(stage), {:ok, :dispatched})
      Process.sleep(20)

      assert {:resolved, expired} = StageAudit.read(stage.id)
      assert expired["state"] == "expired"
      assert expired["source"] == "deadline"
    end

    test "the expiry projection NEVER writes", %{stage: stage} do
      Application.put_env(:platform, :architecture_audit_timeout_ms, 1)
      {:ok, _} = StageAudit.open_from_fire(stage, {:ok, :dispatched})
      Process.sleep(20)

      assert {:resolved, %{"state" => "expired"}} = StageAudit.read(stage.id)

      # The raw row still says `pending`. `"expired"` is not in the
      # schema's persistable set precisely so one fact cannot acquire two
      # representations that can disagree.
      assert reload(stage).architecture_audit["state"] == "pending"

      # And re-reading is stable — a projection that wrote would flip the
      # row and change nothing visible here, so read it twice.
      assert {:resolved, %{"state" => "expired"}} = StageAudit.read(stage.id)
      assert reload(stage).architecture_audit["state"] == "pending"
    end

    test "a pending audit with a missing or unparseable deadline projects expired", %{
      stage: stage
    } do
      for deadline <- [nil, "whenever", 12_345] do
        audit = %{
          "state" => "pending",
          "stage_id" => stage.id,
          "task_id" => nil,
          "plan_id" => stage.plan_id,
          "dispatched_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "deadline_at" => deadline,
          "resolved_at" => nil,
          "source" => nil,
          "reason" => nil,
          "summary" => nil,
          "findings" => []
        }

        {:ok, _} =
          reload(stage)
          |> Stage.architecture_audit_changeset(%{architecture_audit: audit})
          |> Repo.update()

        assert {:resolved, %{"state" => "expired", "source" => "deadline"}} =
                 StageAudit.read(stage.id),
               "deadline_at #{inspect(deadline)} should project as expired"
      end
    end

    test "terminal states read resolved and are returned untouched", %{stage: stage} do
      {:ok, _} = StageAudit.open_from_fire(stage, {:ok, :unfilled})

      assert {:resolved, audit} = StageAudit.read(stage.id)
      assert audit["state"] == "skipped"
      assert audit["reason"] == "unfilled"
      # No `"source" => "deadline"` smeared onto it — that key belongs to
      # the pending projection alone.
      assert audit["source"] == nil
      assert audit == reload(stage).architecture_audit
    end

    test "re-reads the row rather than trusting the struct it was handed", %{stage: stage} do
      stale = reload(stage)
      assert stale.architecture_audit == nil

      {:ok, _} = StageAudit.open_from_fire(stale, {:ok, :dispatched})

      # The caller still holds the pre-write struct. Answering from it
      # would report `:none` for an audit that exists — the mirror-image
      # of the bug member 4's reviewer found in `AutoMerger`.
      assert {:open, %{"state" => "pending"}} = StageAudit.read(stale)
    end
  end
end
