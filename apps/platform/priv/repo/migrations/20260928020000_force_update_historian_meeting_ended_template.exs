defmodule Platform.Repo.Migrations.ForceUpdateHistorianMeetingEndedTemplate do
  use Ecto.Migration

  @moduledoc """
  Task `01a0a12e` stage 4 (ticket clauses 6 and 7): the
  `historian.meeting_ended` body stops instructing a `memory_search` filter
  that does not exist, stops pointing at an unroutable
  `<meeting_id>-ended.md` journal path, says what an UNKNOWN summary means,
  and no longer tells the Historian to write meeting content into the
  project-wide `decisions.md` page. Meeting curation is withheld by default
  at the handler (stage 3); this is the body an operator gets if they opt in.

  `seed_defaults/0` is INSERT-only and the row exists on every deployment,
  so editing the descriptor alone would leave live rows serving the old
  body. Same force-update shape as
  `20260924170000_force_update_architect_templates_experiment_surface.exs`:
  content AND description are read from `PromptTemplates.default_templates/0`
  rather than frozen here, and a missing row is skipped (fresh boots pick it
  up via `seed_defaults/0`). Unlike that sibling this one also syncs
  `variables`, because the descriptor gains `date` and the admin prompts page
  lists a row's variables from the row.

  Both live installs were read before this was written (2026-09-28): their
  rows were byte-identical to the pre-change descriptor (no hand edit), so
  the overwrite discards nothing a human wrote.
  """

  @slugs ["historian.meeting_ended"]

  def slugs, do: @slugs

  def up do
    alias Platform.Orchestration.PromptTemplates

    for slug <- @slugs do
      with template when not is_nil(template) <- PromptTemplates.get_template_by_slug(slug),
           %{content: content, description: description, variables: variables} <-
             Enum.find(PromptTemplates.default_templates(), &(&1.slug == slug)) do
        {:ok, _} =
          PromptTemplates.update_template(template, %{
            content: content,
            description: description,
            variables: variables
          })
      else
        _ -> :skip
      end
    end

    :ok
  end

  def down do
    :ok
  end
end
