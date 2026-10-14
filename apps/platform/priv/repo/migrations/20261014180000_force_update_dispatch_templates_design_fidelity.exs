defmodule Platform.Repo.Migrations.ForceUpdateDispatchTemplatesDesignFidelity do
  use Ecto.Migration

  require Logger

  @moduledoc """
  Task `01a13ae7` (Design fidelity) force-update for the dispatch template
  rows the task edits.

  Stage 2: `dispatch.planning` replaces "read the design canvas and let it
  constrain the UI stages" with
  `PromptTemplates.planning_design_fidelity_section/0`, a canvas-anchored
  inventory plus one fidelity `e2e_behavior` case per canvas-backed screen.

  Stage 3: `dispatch.in_progress` gains
  `PromptTemplates.in_progress_design_fidelity_section/0` (screenshot every
  canvas first, build to the inventory, post `Design deviations — stage <n>`)
  and `dispatch.review_e2e` gains
  `PromptTemplates.review_e2e_design_fidelity_section/0` (how a
  `Fidelity case — canvas <id>` case is judged: side-by-side evidence canvas,
  per-row inventory check, declared deviations).

  `seed_defaults/0` is INSERT-only and a served row wins over its descriptor,
  so the descriptor edit alone reaches no existing deployment. This writes
  `default_content_for_slug/1` for each slug, guarded three ways by the md5 of
  the live row:

  - row equals the new descriptor: skip (idempotent, and a fresh install's
    row is seeded from current code);
  - md5 of the row is the measured pre-change md5: write the descriptor;
  - anything else: `Logger.warning` naming the slug and md5, then SKIP. An
    operator edit is never silently deleted; fold it into the descriptor and
    add its md5 here instead.

  Slugs with no row are skipped: `seed_defaults/0` owns first boot.

  Measured read-only on 2026-10-14 against image revision 18c1f549, on both
  installs (fabrikam `core-platform`, ellis `core-platform-milv`):

  - `dispatch.planning`: `907e72e9a10990cfaaacad81025be5cd` on both, equal to
    the descriptor on main 18c1f549. No experiment targets the slug on either
    install. Re-measured, same value on both, immediately before the stage-2
    push.
  - `dispatch.in_progress`: `9239973ef0a842177565e1b4eb40c491` on both.
  - `dispatch.review_e2e`: `e75607564b0fcfbb16a925d210a8002a` on both.

  Both stage-3 slugs were measured equal to the descriptor on main 18c1f549
  on both installs, and re-measured read-only (same values on both, image
  revision 18c1f549 on both, no experiment targeting either slug)
  immediately before the stage-3 push.

  `down/0` is a no-op, as in
  `20260924171000_force_update_architect_and_planning_templates_experiment_surface.exs`.
  """

  @pre_change_md5 %{
    "dispatch.planning" => "907e72e9a10990cfaaacad81025be5cd",
    "dispatch.in_progress" => "9239973ef0a842177565e1b4eb40c491",
    "dispatch.review_e2e" => "e75607564b0fcfbb16a925d210a8002a"
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
              "force_update_dispatch_templates_design_fidelity: skipping #{slug}: " <>
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
