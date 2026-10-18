defmodule Platform.Repo.Migrations.ForceUpdateDeployingTemplateAutoMergeConditional do
  use Ecto.Migration

  @slug "dispatch.deploying"

  @moduledoc """
  The deploy template told every deployer not to arm auto-merge. That became
  false on 2026-09-11.

  The old "Merge mechanics" section said arming is unsafe "on this repository"
  because `main` required only `Test`, whose conclusion is `success` for a
  failed-then-retried run as well as a clean one (ticket 01a08d81). At ~15:2xZ
  `first-run-green` was added to the required contexts, which is exactly what
  makes a retry-green block the merge — so the instruction inverted, and a
  deployer following the served prompt had to be overridden by brief to do the
  now-correct thing.

  The replacement is CONDITIONAL rather than a flipped absolute: verify that
  `main`'s required contexts include both `Test` and `first-run-green` before
  arming, every time. A flipped absolute would be wrong again the next time
  branch protection changes, and nothing would report it — which is how the
  first version came to be wrong.

  THIS MIGRATION IS THE DELIVERABLE, not the descriptor edit. `seed_defaults/0`
  is INSERT-only, so a descriptor-only change reaches no existing deployment,
  and the row edit it carries reached only the install it was typed against:
  install A held the new body (5078 chars, 17:57:00Z) while install B still held the old
  one (4501 chars, 01:48:15Z).

  ## What was checked before overwriting, because this one is NOT a superset

  Unlike `20260911180000`, the new body is not the old body plus lines — the
  section was rewritten in place, so `diff` shows three lines only on install B and
  four only on install A. Each dropped line was confirmed to survive in rewritten
  form rather than to have been lost: the ANNOTATIONS / retry-sentinel rule,
  the known-flake list, and the `mergedAt`-as-a-field check all still appear,
  and the new body additionally carries the `git ls-remote` check (a merged
  `--delete-branch` from a worktree skips the REMOTE delete — found on #1012).

  ## The descriptor edit is surgical, and it has to be

  `do_default_templates/0`'s body for this slug contains the interpolation
  `\#{task_ack_preamble}`. Replacing the descriptor wholesale with the live row
  — which is what the review_e2e sibling migration does safely, because that
  body has no interpolation — would freeze an EXPANDED preamble into a literal
  and silently detach this template from the shared ack text. Only the seven
  lines of the "Merge mechanics" section were swapped.

  A consequence worth stating: because the descriptor interpolates and the row
  was hand-written, this migration may also normalise the preamble region of
  the served row to whatever `task_ack_preamble` currently expands to. That is
  the intended direction — the descriptor becomes the source of truth — but it
  is a change beyond the section that was edited.

  `down/0` is an explicit no-op: the prior body asserts a rule that is now
  false, and restoring it is not a state worth returning to.
  """

  def up do
    alias Platform.Orchestration.PromptTemplates

    case PromptTemplates.get_template_by_slug(@slug) do
      nil ->
        :ok

      template ->
        case PromptTemplates.default_content_for_slug(@slug) do
          nil -> :ok
          content -> {:ok, _} = PromptTemplates.update_template(template, %{content: content})
        end
    end

    :ok
  end

  def down do
    :ok
  end
end
