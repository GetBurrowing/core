defmodule Platform.Repo.Migrations.ForceUpdateDreamingPromptInsights do
  use Ecto.Migration

  require Logger

  @moduledoc """
  Task `01a13867-3213-7001-a128-6b4c6b34283f` (Insights), stage 1:
  force-update the two dreaming prompt rows, `historian.dreaming` and
  `memory.dreaming.v1`, to the `<synthesis-insight>` grammar.

  The shared descriptor (`@dreaming_content` in
  `Platform.Orchestration.PromptTemplates`) now asks for insights with four
  action types (`page_edit | briefing | question | task`), states the
  grounding rule (a `page_edit` without a `page:/journal:/task:/message:/query:`
  `source` is downgraded to a question), and no longer points at an
  approval page. The Maintenance ops section and the template variables are
  unchanged. The copy names no person, host or install.

  `seed_defaults/0` is INSERT-only and a served row wins over its
  descriptor, so the descriptor edit alone reaches no existing deployment.
  This writes `default_content_for_slug/1` for each slug, guarded three ways
  by the md5 of the live row (the guard of
  `20261017230000_force_update_prompt_templates_burrow_rename`):

  - row equals the new descriptor: skip;
  - md5 of the row is the measured pre-change md5: write the descriptor;
  - anything else: `Logger.warning` naming the slug and md5, then SKIP, so
    an operator edit is never silently deleted.

  Slugs with no row are skipped: `seed_defaults/0` owns first boot.

  Measured read-only (SELECT under `default_transaction_read_only = on`) on
  2026-10-18 03:40Z on all four deployed installs. Every row equals md5 of the
  descriptor on origin/main c95b7518 (computed from the source), so none
  carries an operator edit. `20261017230000` did not touch either slug.

  | slug                 | pre-change md5                     | install 1 | install 2 | install 3 | install 4 (exp) |
  | -------------------- | ---------------------------------- | --------- | --------- | --------- | --------------- |
  | `historian.dreaming` | `19bb74b76eab7b9b59650724114b6c58` | match     | match     | match     | match           |
  | `memory.dreaming.v1` | `19bb74b76eab7b9b59650724114b6c58` | match     | match     | match     | match           |

  Sibling task A3 (01a14b9e-c802) neutralises personal names in the same
  descriptor and ships no migration for it. Whichever of the two merges
  second reconciles `@dreaming_content`; this migration then carries the
  reconciled text into the live rows, which is intended.

  `down/0` is a no-op, as in the migration whose guard this copies.
  """

  @pre_change_md5 %{
    "historian.dreaming" => "19bb74b76eab7b9b59650724114b6c58",
    "memory.dreaming.v1" => "19bb74b76eab7b9b59650724114b6c58"
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
              "force_update_dreaming_prompt_insights: skipping #{slug}: " <>
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
