defmodule Platform.Repo.Migrations.AddArchitectureAuditToStages do
  use Ecto.Migration

  # Task 019fa61c stage 1 — the `architecture.audit_diff` fire's outcome,
  # recorded per STAGE.
  #
  # WHY THIS COLUMN EXISTS. `architecture.review_plan` is observable
  # because it has a tool that writes a row (`plans.architecture_verdict`,
  # 20260726051454). `architecture.audit_diff` has no equivalent, so its
  # success rate is unobservable BY CONSTRUCTION: 28 broadcasts in a
  # 3.3-hour window produced no durable evidence anywhere, and the
  # original payload defect ran six days behind that blind spot. This
  # column is the same artefact `review_plan` already has, applied to the
  # per-stage responsibility.
  #
  # ON `stages` AND NOT ON `plans` — the subject of an audit_diff fire is
  # one stage's diff. `PlanEngine.after_stage_completed/1` fires it once
  # per stage transition, so a plan-level slot would make the second
  # stage's audit overwrite the first's, and the coverage invariant
  # (stage 5) would count one row where two fires happened.
  #
  # NULLABLE, NO DEFAULT — deliberately, and for the same reason
  # 20260726051454 gives: the ABSENCE of a value is meaningful ("no fire
  # was ever recorded for this stage"). A `%{}` default would make "never
  # fired" and "fired and produced nothing" the same value, which is
  # precisely the conflation this task exists to remove.
  #
  # NO INDEX — every read is by stage primary key (`StageAudit.read/1`)
  # or by a project-scoped join already anchored on `plans`/`tasks`
  # (`StageAudit.coverage/1`, stage 5). There is no "list all stages with
  # an open audit" scan; the expiry projection is level-triggered off a
  # row already loaded, not swept.
  def change do
    alter table(:stages) do
      add(:architecture_audit, :map)
    end
  end
end
