defmodule Platform.Repo.Migrations.AddFeedbackGuidancePlaceholderToPromptTemplates do
  @moduledoc """
  Task 01a11ec3 stage 2: put the `{{feedback_guidance}}` slot into the LIVE
  rows of every task dispatch template and the nudge.

  `seed_defaults/0` is insert-only and a served row wins over its descriptor,
  so the descriptor edit in `PromptTemplates.do_default_templates/0` alone
  would reach no existing install. This is the force-update that carries it.

  ## Surgical, not a rewrite

  Unlike the descriptor-overwrite force-updates before it, this migration
  does NOT replace the row with the descriptor: it applies
  `PromptTemplates.insert_feedback_placeholder/1` to the row's own content,
  which adds only the placeholder (after the last `{{federation_preamble}}`,
  or at the end of the nudge body) and leaves every other byte alone. An
  operator's edit to any of these rows survives. For an unedited row the
  result is byte-identical to the descriptor. Rows that already carry the
  placeholder are untouched, so the migration is idempotent; `variables` gains
  `"feedback_guidance"` when it is missing.

  ## Policy-independent by design

  The row gets the slot whatever `FEEDBACK_POLICY` says at deploy time. What
  fills it is decided per render by `Platform.Feedback.Policy.enabled?/0`
  (`PromptTemplates.feedback_guidance/1`); a disabled install renders `""`
  into the slot, i.e. exactly the pre-migration text. Evaluating the policy
  here would freeze a capability into data.

  Slugs with no row are skipped; a fresh install gets the descriptor (which
  already carries the slot) from `seed_defaults/0`. `down/0` removes exactly
  the placeholder this migration inserts.
  """
  use Ecto.Migration

  import Ecto.Query, only: [from: 2]

  alias Platform.Orchestration.PromptTemplates

  def up do
    for slug <- PromptTemplates.feedback_guidance_slugs() do
      case row(slug) do
        nil ->
          :skip

        {content, variables} ->
          new_content = PromptTemplates.insert_feedback_placeholder(content)
          new_variables = add_variable(variables)

          if new_content != content or new_variables != variables do
            write(slug, new_content, new_variables)
          end
      end
    end

    :ok
  end

  def down do
    placeholder = PromptTemplates.feedback_guidance_placeholder()

    for slug <- PromptTemplates.feedback_guidance_slugs() do
      case row(slug) do
        nil ->
          :skip

        {content, variables} ->
          write(
            slug,
            String.replace(content, placeholder, ""),
            List.delete(variables || [], "feedback_guidance")
          )
      end
    end

    :ok
  end

  defp row(slug) do
    Platform.Repo.one(
      from(t in "prompt_templates",
        where: t.slug == ^slug,
        select: {t.content, t.variables}
      )
    )
  end

  defp write(slug, content, variables) do
    Platform.Repo.update_all(
      from(t in "prompt_templates", where: t.slug == ^slug),
      set: [content: content, variables: variables, updated_at: DateTime.utc_now()]
    )
  end

  defp add_variable(nil), do: ["feedback_guidance"]

  defp add_variable(variables) when is_list(variables) do
    if "feedback_guidance" in variables, do: variables, else: variables ++ ["feedback_guidance"]
  end
end
