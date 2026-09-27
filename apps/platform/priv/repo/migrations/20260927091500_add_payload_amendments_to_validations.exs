defmodule Platform.Repo.Migrations.AddPayloadAmendmentsToValidations do
  @moduledoc """
  Add `validations.payload_amendments`, the append-only history written by
  `Platform.Tasks.amend_validation_payload/4` (task 01a0acb4 stage 1).

  When an `e2e_behavior` case on an approved or executing plan is defective
  (its actions send a header the pipeline refuses, a threshold was copied
  from another run), the correction replaces `evaluation_payload` in place
  and appends one entry here recording the prior payload, who amended it,
  when, why, and the last archived ruling at amend time.

  ## Why a new column, and not `evidence` or `evaluation_payload`

  * `evidence` is REPLACED wholesale on every `e2e_behavior` verdict:
    `Platform.Tasks.EvidenceCarry.carry_prior_rulings/2` carries
    `prior_rulings` across a write for `manual_approval` rows only. A history
    kept in `evidence` would be erased by the next verdict (measured in
    production on task 01a0e091: a case ruled failed in three rounds now
    carries round 3 only).
  * `evaluation_payload` is written straight from planner input by
    `plan_create` / `plan_update`, so a history kept there could be forged
    by a planner.

  The column is deliberately NOT in `Platform.Tasks.Validation.changeset/2`'s
  cast list; only `Validation.payload_amendment_changeset/3` writes it.

  Additive and NOT NULL with a `[]` default, so every existing row reads as
  "never amended" with no backfill.
  """
  use Ecto.Migration

  def change do
    alter table(:validations) do
      add(:payload_amendments, {:array, :map}, null: false, default: [])
    end
  end
end
