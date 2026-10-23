defmodule Platform.Repo.Migrations.ForceUpdateDreamingPromptTaskTarget do
  use Ecto.Migration

  require Logger

  @moduledoc """
  Task `01a15ee1-48c8-7000-a8f1-33a5586cb458` (daily briefing in the Inbox),
  stage 2: force-update the two dreaming prompt rows, `historian.dreaming`
  and `memory.dreaming.v1`, to the grammar where a `task` insight carries
  `target="<project uuid>"`.

  The shared descriptor (`@dreaming_content` in
  `Platform.Orchestration.PromptTemplates`) now:

    * spells the block grammar's `target` as
      `<page path, for page_edit; project uuid, for task>`;
    * tells the model to set a task's `target` to the uuid of the project
      the work belongs to, and to omit it only when no project is named or
      implied (`Platform.Memory.Insights.Parser` lifts a uuid target of a
      task into `action["project_id"]`, and
      `Platform.Memory.Insights.ProjectInference` falls back from there);
    * says how to propose a message to someone outside the org (an email
      `addressee`, saved as a draft and never sent; stage 3 consumes it).

  `seed_defaults/0` is INSERT-only and a served row wins over its
  descriptor, so the descriptor edit alone reaches no existing deployment.
  This writes `default_content_for_slug/1` for each slug, guarded three ways
  by the md5 of the live row (the guard of
  `20261018000200_force_update_dreaming_prompt_insights`):

    * row equals the new descriptor: skip;
    * md5 of the row is the measured pre-change md5: write the descriptor;
    * anything else: `Logger.warning` naming the slug and md5, then SKIP, so
      an operator edit is never silently deleted.

  Slugs with no row are skipped: `seed_defaults/0` owns first boot.

  Measured read-only (`default_transaction_read_only = on`) on 2026-10-21
  around 16:00Z on both deployed installs. Every row's md5 equals the md5 of
  `@dreaming_content` on the branch before this edit, and `updated_by` is
  null on every row (last written by a migration), so none carries an
  operator edit:

  | slug                 | pre-change md5                     | install 1 | install 2 |
  | -------------------- | ---------------------------------- | --------- | --------- |
  | `historian.dreaming` | `24c2a2deb548681d274c779d76d02ec6` | match     | match     |
  | `memory.dreaming.v1` | `24c2a2deb548681d274c779d76d02ec6` | match     | match     |

  `down/0` is a no-op, as in the migration whose guard this copies.
  """

  @pre_change_md5 %{
    "historian.dreaming" => "24c2a2deb548681d274c779d76d02ec6",
    "memory.dreaming.v1" => "24c2a2deb548681d274c779d76d02ec6"
  }

  # The three edits this task made to `@dreaming_content`, as
  # `{before, after}` spans. Not used by `up/0`; tests undo them on the
  # current descriptor to rebuild the pre-change body and prove its md5 is
  # the one pinned above.
  @edits [
    {~s(target="<page path, for page_edit>">),
     ~s(target="<page path, for page_edit; project uuid, for task>">)},
    {"State the outcome, not the steps.\n",
     "State the outcome, not the steps. Set `target` to the uuid of the project the work " <>
       "belongs to, taken from where it was discussed (a `project/<uuid>/journal` path, the " <>
       "cited task's project, the space's project). Omit it only when no project is named " <>
       "or implied.\n\nTo propose a message to someone outside the org, set `addressee` to " <>
       "their email address and write the body as the message itself; Burrow saves it as an " <>
       "email draft and never sends it.\n"}
  ]

  def pre_change_md5, do: @pre_change_md5
  def edits, do: @edits

  @doc "Undo this task's edits on `content` (for tests)."
  def undo_edits(content) when is_binary(content) do
    Enum.reduce(@edits, content, fn {before, after_edit}, acc ->
      String.replace(acc, after_edit, before)
    end)
  end

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
              "force_update_dreaming_prompt_task_target: skipping #{slug}: " <>
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
