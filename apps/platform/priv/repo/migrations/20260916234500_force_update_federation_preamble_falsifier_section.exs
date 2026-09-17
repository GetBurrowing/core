defmodule Platform.Repo.Migrations.ForceUpdateFederationPreambleFalsifierSection do
  use Ecto.Migration

  @moduledoc """
  Force-updates the `federation.preamble` prompt template row so the served
  preamble carries the new "Filing a ticket — state its falsifier" section
  (task 01a0a5f5 stage 4).

  THIS MIGRATION IS THE DELIVERABLE, not the stage-2 edit to
  `@federation_preamble`. `PromptTemplates.seed_defaults/0` is INSERT-only
  (skip-if-exists), so every environment that has ever booted already holds
  the row, and `federation_preamble/1` PREFERS that row — falling back on the
  constant only when the row is missing, non-binary, blank after trim, or
  `Repo` raises. An attribute-only edit therefore reaches no deployed
  dispatch: CI goes green against the constant while roughly fifteen
  `dispatch.*` templates keep rendering the old text.

  ## Content is read from the descriptor, not frozen as a literal

  As in `20260816120000_force_update_federation_preamble_content`, the content
  comes from `PromptTemplates.default_content_for_slug/1`. The invariant this
  stack maintains is `row.content == PromptTemplates.federation_preamble()` —
  the row and the fallback must never disagree. A frozen literal would be a
  second copy of a ~6 KB block that a later attribute edit could silently
  diverge from.

  Note for whoever writes the test: reading the comparand from the descriptor
  makes `row.content == federation_preamble()` VACUOUS on its own — the row
  equals the descriptor by construction once `up/0` has run, and the assertion
  cannot go red. The accompanying test drives the row STALE first and asserts
  the section is absent before running `up/0`. See
  `test/platform/repo/migrations/force_update_federation_preamble_falsifier_section_test.exs`.

  ## Force-update, unconditionally

  Guarded only by non-blank descriptor content; zero matching rows is a no-op,
  not an error (`seed_defaults/0` owns first boot). It is NOT conditional on
  whether an operator edited the row through the admin form, and it therefore
  overwrites such an edit. That cost is accepted deliberately: the suite pins
  the row against the constant, so a "skip if edited" branch would leave an
  edited row permanently failing that pin with no signal to anyone. Same trade
  the prior force-update documented.

  This migration touches the `prompt_templates` row ONLY. No `tasks` schema
  change exists anywhere in task 01a0a5f5's plan — the human-form falsifier
  field is composed into the existing `description` body, not a column.

  `down/0` is an explicit no-op. The prior body differs only by the absence of
  the falsifier section; returning to it is not a state worth restoring.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Orchestration.PromptTemplates

  @slug "federation.preamble"

  def up do
    content = PromptTemplates.default_content_for_slug(@slug)

    if is_binary(content) and String.trim(content) != "" do
      Platform.Repo.update_all(
        from(t in "prompt_templates", where: t.slug == ^@slug),
        set: [content: content, updated_at: DateTime.utc_now()]
      )
    end

    :ok
  end

  def down do
    :ok
  end
end
