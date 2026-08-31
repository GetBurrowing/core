defmodule Platform.Tasks.EvidenceCarry do
  @moduledoc """
  Carries a validation's `prior_rulings` archive forward across an evidence
  write.

  The archive survives only because it is merged AT THE WRITE, not because
  every caller remembers to re-attach it. `ReviewRequests` used to copy the
  archive forward itself before calling into the engine (that duplicate was
  removed at task `01a006f6` stage 3) — a habit of the callers, not a
  property of the write. `Platform.Federation.ToolSurface`'s
  `execute("validation_evaluate", ...)` calls
  `PlanEngine.evaluate_validation/2` DIRECTLY with agent-supplied evidence and
  never touches `ReviewRequests`, so without the merge here an agent
  dispositioning a manual gate through the tool surface destroys the human's
  recorded words with no error and no failed gate. Merging at the write makes
  the guarantee caller-independent.

  Two functions write a validation's `evidence`, and BOTH route the incoming
  map through `carry_prior_rulings/2`:

    * `Platform.Tasks.PlanEngine.evaluate_validation/2` — the lifecycle
      writer (transaction, `evaluated_by`, telemetry, stage advance). This is
      the path production and the MCP tool surface reach.
    * `Platform.Tasks.evaluate_validation/3` — the bare row write. Until task
      `01a0167c` it replaced `evidence` wholesale, so the "enforced at the
      write" claim above was true of the engine only.

  The guarantee therefore holds for whichever writer a caller reaches. That
  agreement is pinned by `test/platform/tasks/evidence_carry_agreement_test.exs`,
  which runs both writers against the database and asserts the persisted
  maps are equal — it is not a convention either writer is trusted to keep.

  `Platform.Tasks.evaluate_validation/3` was KEPT rather than deleted (task
  `01a0167c`): at that task's branch tip it has zero callers under `lib/` and
  21 call sites across 8 files under `test/`, all of which need a recorded
  evaluation WITHOUT a transaction, telemetry, or a stage advance. The
  engine cannot substitute for that — it loads the validation's stage inside
  its transaction and advances it when the last gate resolves — so deleting
  the arity-3 writer would mean rewriting those fixtures around lifecycle
  they do not test.

  Deliberately narrow: an explicit caller-supplied `"prior_rulings"` wins (so
  `ReviewRequests` stays idempotent), nothing is invented where there was no
  archive, and only `manual_approval` rows are touched — the archive has no
  meaning on deploy/test kinds and must not leak into them.
  """

  alias Platform.Tasks.Validation

  @doc """
  Returns `evidence` with the loaded `validation`'s non-empty `prior_rulings`
  archive attached under `"prior_rulings"`, unless the incoming evidence
  already carries that key.

  Only a `%Validation{kind: "manual_approval"}` with map evidence is touched;
  every other row gets its evidence back unchanged.
  """
  @spec carry_prior_rulings(Validation.t(), map()) :: map()
  def carry_prior_rulings(%Validation{kind: "manual_approval"} = validation, evidence)
      when is_map(evidence) do
    case validation.evidence do
      %{"prior_rulings" => [_ | _] = prior} ->
        if Map.has_key?(evidence, "prior_rulings") do
          evidence
        else
          Map.put(evidence, "prior_rulings", prior)
        end

      _ ->
        evidence
    end
  end

  def carry_prior_rulings(_validation, evidence), do: evidence
end
