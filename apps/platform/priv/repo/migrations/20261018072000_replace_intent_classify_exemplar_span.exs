defmodule Platform.Repo.Migrations.ReplaceIntentClassifyExemplarSpan do
  use Ecto.Migration

  require Logger

  @moduledoc """
  Task `01a14dce-d2d8-7000-becf-79544fe7cf98` (Burrow rename A3b), stage 1:
  replace ONE line of the stored `meetings.intent_classify.v1` prompt, the
  first exemplar under "An unaddressed ask KEEPS its intent and takes
  `target_role: null`". That line quoted a real meeting utterance naming a
  real person. It becomes an invented line of the same shape: a speaker says
  they will fetch a person who is not on the agent roster, no agent is
  addressed, and the expected answer stays `action_items` with
  `target_role: null`.

  ## Why this is matched by digest, one line at a time

  The force-update migrations that wrote this row
  (`20260826120000`, `20260902140000`, `20260911030000`) overwrite the whole
  body blindly and log the prior content. Neither is acceptable here:

    * logging the prior content would print the utterance this migration
      exists to remove into every deploy log; and
    * a blind overwrite clobbers any hand edit an operator made to the row.

  So this migration never spells the old line. It holds only
  `@old_line_sha256`, the sha256 of the exact old line (leading whitespace
  included, newline excluded), splits the row on `"\\n"` and compares each
  line's digest to the pin:

    * no row: skip (`seed`/the migration chain owns first creation);
    * exactly one matching line: replace that line with `@new_line` and write
      the content back. Every other byte is unchanged and `variables` is not
      touched;
    * no matching line (a hand-edited or already-neutral row): skip, with
      `Logger.info` naming the slug and the row's sha256;
    * two or more matching lines: skip, with `Logger.warning`. The row is not
      the shape this migration was written against, so it is left for a human.

  Only digests are logged, never content. `down/0` is a no-op, as in
  `20261017230000_force_update_prompt_templates_burrow_rename.exs`.
  """

  @slug "meetings.intent_classify.v1"

  # sha256 of the exact old exemplar line as the row stores it.
  @old_line_sha256 "532cd085a06254f993d53c2cfb8562a798cda2fbbd5af9d7531d1d3462df0c22"

  @new_line ~S|  - "Nah, I'm gonna get Sam in here."                                 -> `action_items`, `target_role: null` (a concrete commitment; the owner is a person)|

  def slug, do: @slug
  def old_line_sha256, do: @old_line_sha256
  def new_line, do: @new_line

  def up do
    run(@old_line_sha256)
    :ok
  end

  def down, do: :ok

  @doc """
  Applies the digest-matched swap to the `#{@slug}` row, replacing the one
  line whose sha256 is `old_line_sha256` with `@new_line`. Public so tests
  can drive it with a pin of their own.

  Returns `:swapped`, `:no_row`, `:no_match` or `:ambiguous`.
  """
  def run(old_line_sha256) when is_binary(old_line_sha256) do
    alias Platform.Orchestration.PromptTemplates

    case PromptTemplates.get_template_by_slug(@slug) do
      %{content: content} = template when is_binary(content) ->
        lines = String.split(content, "\n")

        matches =
          for {line, index} <- Enum.with_index(lines), sha256(line) == old_line_sha256, do: index

        case matches do
          [index] ->
            new_content = lines |> List.replace_at(index, @new_line) |> Enum.join("\n")
            {:ok, _} = PromptTemplates.update_template(template, %{content: new_content})
            :swapped

          [] ->
            Logger.info(
              "replace_intent_classify_exemplar_span: skipping #{@slug}: no line matches " <>
                "the pinned exemplar digest; row sha256 #{sha256(content)}"
            )

            :no_match

          many ->
            Logger.warning(
              "replace_intent_classify_exemplar_span: skipping #{@slug}: #{length(many)} lines " <>
                "match the pinned exemplar digest, expected one; row sha256 #{sha256(content)}"
            )

            :ambiguous
        end

      _ ->
        :no_row
    end
  end

  defp sha256(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
end
