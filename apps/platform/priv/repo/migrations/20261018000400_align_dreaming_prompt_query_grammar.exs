defmodule Platform.Repo.Migrations.AlignDreamingPromptQueryGrammar do
  use Ecto.Migration

  require Logger

  @moduledoc """
  Task `01a13867-3213-7001-a128-6b4c6b34283f` (Insights), stage 4: align the
  dreaming prompt's `source` grammar with the grounding grammar.

  Stage 1's descriptor told the model to cite `query:<memory_search query>`.
  Stage 2's `Platform.Memory.Insights.Grounding` accepts `query:<name>` only
  for a name in `Grounding.queries/0`, so every page_edit sourced that way
  was downgraded to a question and page edits never applied. The descriptor
  now names the valid queries and sends free-text search evidence to
  `page:` / `journal:` refs.

  ## What this writes, and when

  `render_template/2` serves the DB row, so the descriptor edit alone is a
  runtime no-op on any install whose row holds the stage-1 text. For each of
  `historian.dreaming` and `memory.dreaming.v1`:

    * row equals the current descriptor: skip (the normal case on a deploy:
      `20261018000200` runs in the same deploy, with the same compiled
      descriptor, and has already written the new text);
    * md5 of the row is the STAGE-1 descriptor's md5 (`@stage_one_md5`): the
      grammar sentence `@old_span` is replaced by `@new_span`, and nothing
      else in the row changes;
    * anything else, a hand-edited row included: `Logger.warning` naming the
      slug and the md5 only (never the row content), then SKIP.

  A slug with no row is skipped: `seed_defaults/0` owns first boot. No other
  row is read or written, and nothing is force-written: a row is changed only
  when its whole body is byte-for-byte the stage-1 text.

  `down/0` is a no-op, as in `20261018000200`.
  """

  @slugs ["historian.dreaming", "memory.dreaming.v1"]

  # md5 of the stage-1 descriptor (`@dreaming_content` at branch commit
  # 4d1c0a7c, task 01a13867 stage 3), the only body this migration rewrites.
  @stage_one_md5 "e5d2ca47680024052e865d7e3ae5ff34"

  @old_span "`message:<id>` or `query:<memory_search query>`."

  @new_span "`message:<id>` or `query:<name>` for a named query. Named queries: " <>
              "`query:agent_runtimes.last_connected_at` (slug and last_connected_at of every agent runtime). " <>
              "A `query:` ref with any other name does not resolve, so for something you found with `memory_search`, " <>
              "cite the page or journal the hit came from (`page:<path>` or `journal:<path>`), never the search text."

  def slugs, do: @slugs
  def stage_one_md5, do: @stage_one_md5
  def old_span, do: @old_span
  def new_span, do: @new_span

  def up, do: run(@stage_one_md5)

  def down, do: :ok

  @doc """
  Apply the guard for both slugs against `expected_md5`. Public so tests can
  model a stage-1 row of their own.
  """
  def run(expected_md5) when is_binary(expected_md5) do
    alias Platform.Orchestration.PromptTemplates

    for slug <- @slugs do
      with %{} = template <- PromptTemplates.get_template_by_slug(slug),
           descriptor when is_binary(descriptor) <- PromptTemplates.default_content_for_slug(slug) do
        live_md5 = md5(template.content)

        cond do
          template.content == descriptor ->
            :skip

          live_md5 == expected_md5 and
              length(String.split(template.content, @old_span)) == 2 ->
            content = String.replace(template.content, @old_span, @new_span)
            {:ok, _} = PromptTemplates.update_template(template, %{content: content})

          true ->
            Logger.warning(
              "align_dreaming_prompt_query_grammar: skipping #{slug}: " <>
                "live md5 #{live_md5} is not the stage-1 md5 #{expected_md5}; " <>
                "a hand edit is preserved, fold the query grammar into it by hand"
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
