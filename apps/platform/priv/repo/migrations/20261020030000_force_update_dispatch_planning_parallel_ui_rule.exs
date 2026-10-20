defmodule Platform.Repo.Migrations.ForceUpdateDispatchPlanningParallelUiRule do
  use Ecto.Migration

  require Logger

  @moduledoc """
  Task `01a156cb-71f8-7000-89f2-7842bacbdbf1` (Parallel-UI debt ledger),
  stage 3: force-update the `dispatch.planning` row so planners are told the
  parallel-UI rule.

  The descriptor gains `PromptTemplates.planning_parallel_ui_rule/0`: a stage
  that keeps a legacy event, field, column, dual write or route alive for a
  parallel UI registers it in `Platform.ParallelUI` (entry plus markers, and a
  column comment for a column) in the same commit. The same text is
  interpolated into `HeartbeatScheduler.hardcoded_dispatch_planning/4`.

  `seed_defaults/0` is INSERT-only and a served row wins over its descriptor,
  so the descriptor edit alone reaches no existing deployment. This writes
  `default_content_for_slug/1` for the slug, guarded three ways by the md5 of
  the live row:

  - row equals the new descriptor: skip (idempotent, and a fresh install's
    row is seeded from current code);
  - md5 of the row is the measured pre-change md5: write the descriptor;
  - anything else: `Logger.warning` naming the slug and md5, then SKIP. An
    operator edit is never silently deleted; fold it into the descriptor and
    add its md5 here instead.

  A slug with no row is skipped: `seed_defaults/0` owns first boot.

  Measured read-only (SELECT under `default_transaction_read_only`) on
  2026-10-20 ~03:10Z on all four installs on the production host. Installs
  are named by letter, not by host or database, so this file passes the
  install-identity guard (task 01a14b9e). Installs A, B and C run image
  revision 60af1f6fe (this branch's base):

  | install | md5                                | updated_at (UTC)           | updated_by        | schema version |
  | ------- | ---------------------------------- | -------------------------- | ----------------- | -------------- |
  | A       | `a01b8696047ae6fc8f4912490e8f232f` | 2026-10-14 18:41:36.846005 | dalton            | 20261018223000 |
  | B       | `a01b8696047ae6fc8f4912490e8f232f` | 2026-10-14 18:41:53.515841 | dalton            | 20261018223000 |
  | C       | `a01b8696047ae6fc8f4912490e8f232f` | 2026-10-14 18:42:04.322669 | (null)            | 20261018223000 |
  | D (exp) | `907e72e9a10990cfaaacad81025be5cd` | 2026-10-14 06:05:26.227021 | (null)            | 20261013180000 |

  **This migration also delivers #1271's CI-evidence rewording.** The
  `dispatch.planning` descriptor on main 60af1f6fe has md5
  `a0ca095a07d7bb702e5c30d5699fe1f8` (measured on the test rig), not
  `a01b8696…`. Every line of the A/B/C rows appears verbatim in the
  descriptor as it stood before #1271 (e9741d5db, "Burrow rename A3"), which
  rewrote one sentence of `planning_ci_evidence_section/0` (the local-rig
  sentence: install-specific test-host commands became "the rig your org's
  test-rig skill names") and shipped no force-update for this slug. So
  A, B and C never received that rewording; guarding on `a01b8696…` writes
  it to them together with the parallel-UI rule. Accepted deliberately
  (task 01a156cb stage 3, coordinator decision 2026-10-20): #1271's text is
  the intended text on main.

  Install D's row is the pre-change md5 of
  `20261014180000_force_update_dispatch_templates_design_fidelity`, not an
  operator edit. D's schema predates that migration, so it runs first and,
  because it writes `default_content_for_slug/1` as of the deployed code,
  writes the CURRENT descriptor (rule and rewording included); this one then
  takes the descriptor-equality skip.

  No experiment targets `dispatch.planning` on any install (`experiments`
  has 2 rows on A, neither on this slug, and 0 on B, C and D); the
  `planner.stage_budget` surface appends its directive at render time and
  never replaces the row.

  `down/0` is a no-op, as in
  `20261014180000_force_update_dispatch_templates_design_fidelity.exs`.
  """

  @pre_change_md5 %{
    "dispatch.planning" => "a01b8696047ae6fc8f4912490e8f232f"
  }

  def pre_change_md5, do: @pre_change_md5

  def up, do: run(@pre_change_md5)

  def down, do: :ok

  @doc """
  Applies the three-way guard for every `slug => md5` in `pre_change`.
  Public so tests can model a deployed row with a stale body of their own.
  """
  def run(pre_change) when is_map(pre_change) do
    alias Platform.Orchestration.PromptTemplates

    for {slug, expected_md5} <- pre_change do
      with %{} = template <- PromptTemplates.get_template_by_slug(slug),
           content when is_binary(content) <- PromptTemplates.default_content_for_slug(slug) do
        live_md5 = md5(template.content)

        cond do
          template.content == content ->
            :skip

          live_md5 == expected_md5 ->
            {:ok, _} = PromptTemplates.update_template(template, %{content: content})

          true ->
            Logger.warning(
              "force_update_dispatch_planning_parallel_ui_rule: skipping #{slug}: " <>
                "live md5 #{live_md5} is neither the pre-change md5 #{expected_md5} " <>
                "nor the new descriptor; an operator edit is preserved, fold it into the descriptor"
            )

            :skip
        end
      else
        _ -> :skip
      end
    end

    :ok
  end

  defp md5(content) when is_binary(content),
    do: :crypto.hash(:md5, content) |> Base.encode16(case: :lower)

  defp md5(_), do: nil
end
