defmodule Platform.Repo.Migrations.ForceUpdateReviewE2eTemplateBrowserSessionCheck do
  use Ecto.Migration

  @slug "dispatch.review_e2e"

  @moduledoc """
  Makes the browser-session check in `dispatch.review_e2e` durable.

  Admitted by ticket 01a0918b (no agent-reachable browser holds a session, so
  an e2e case behind a login is currently unmeasurable), and by PR #1012, which
  shipped a UI fix that a LiveView test could not see.

  On 2026-09-11 the row was patched directly in the install A database via
  `prompt_template_update` (17:39:05Z) to add one instruction: before any
  browser-driven verdict, record the final URL and page title, and treat an
  identity-provider URL or a "Sign in" title as `could_not_evaluate` with the
  reason "no authenticated session" rather than as a pass or a plain fail.
  The sibling change to `do_default_templates/0` makes the descriptor
  byte-identical to that patched row.

  THIS MIGRATION IS THE DELIVERABLE, not the descriptor edit. `seed_defaults/0`
  is INSERT-only, so a descriptor-only change reaches no existing deployment,
  and a row edit alone reaches only the one install it was typed against. Both
  halves were true here at once: install A held the new body (6703 chars) while install B
  still held the old one (5996 chars), and the two would have stayed divergent
  indefinitely because nothing compares them.

  Verified before writing, so this is not a blind overwrite: the install A body is a
  strict superset of the install B body — `diff` reports nine added lines and ZERO
  lines present only on install B. No operator text is lost on either install. (That
  check is the one `20260812230100` skips by design when it accepts overwriting
  an operator edit; here it was cheap, so it was done rather than assumed.)

  Reads the body from the descriptor rather than freezing it, following
  `20260911003000_force_update_prompt_templates_sync_live_rows_2026_09_10`,
  which is the most recent force-update for this slug and therefore what a
  fresh install currently serves.

  ## Why there is no row-vs-descriptor pinning test

  There is a tempting one, and it would be VACUOUS. Because this migration
  reads `default_content_for_slug/1` at migration time, a fresh test database
  runs it against the current descriptor and the row therefore equals the
  descriptor by construction — the assertion could never fail, whatever anyone
  later edits. (That is the trade the frozen-body shape at `20260812230100`
  buys, and the reason it exists; it is not free either, since a frozen body
  drifts from the descriptor silently.)

  What a test CAN catch is the wording being deleted, so the guard is a content
  assertion on the descriptor in `prompt_templates_test.exs` rather than a
  byte-equality pin here. What no test can catch is a descriptor edit shipped
  WITHOUT a new force-update migration: existing installs keep the old row, CI
  stays green, and the served prompt silently lags the source. That is the
  standing hazard for this slug and the reason this file exists at all.

  `down/0` is an explicit no-op: the prior body differs only by the absence of
  an instruction, and a reviewer that cannot tell a login screen from the
  feature is not a state worth returning to.
  """

  def up do
    alias Platform.Orchestration.PromptTemplates

    case PromptTemplates.get_template_by_slug(@slug) do
      nil ->
        # Fresh boot: `seed_defaults/0` writes the descriptor, which already
        # carries this instruction. Nothing to force.
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
