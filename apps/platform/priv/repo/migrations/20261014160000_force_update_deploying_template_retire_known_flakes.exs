defmodule Platform.Repo.Migrations.ForceUpdateDeployingTemplateRetireKnownFlakes do
  use Ecto.Migration

  @slug "dispatch.deploying"

  @moduledoc """
  Task 01a13aac stage 4: retire the known-flake list from the deploy template.

  The "Merge mechanics" section of `dispatch.deploying` told deployers that
  four tests (ProofOfLifeTest, LocalRunnerTest force_stop,
  SandboxHelpersScopedDrainTest, conn_case_supervised_orphan_test) "may be
  merged past with the names recorded in the PR body". Task 01a13aac stage 1
  measured the 320 most recent ci.yml runs (2026-09-26..2026-10-14, 372 Test
  job attempts, 55 retry-green annotations): each of the four had 0
  retry-green occurrences. The list licensed merging past tests that were
  not flaking, and said nothing about the ones that were (stages 1-3 deleted
  or fixed the repeat offenders; single-occurrence flakes were left alone).
  The sentence now says there is no known-flake list: a test the retry
  greened is a red run, named in the PR body and filed.

  `seed_defaults/0` is INSERT-only and `render_template/2` prefers the
  seeded row, so the descriptor edit alone reaches no existing install.
  This migration writes `default_content_for_slug/1` over the row.

  Checked before overwriting (read-only, 2026-10-14): the live row on fabrikam
  (`core_platform`, updated 2026-10-11 06:18:09Z) and milv (`milv_platform`,
  updated 2026-10-11 06:18:19Z) are identical (4966 chars, same md5) and
  equal the pre-edit branch descriptor with `task_ack_preamble` expanded.
  Neither carries a hand edit the branch lacks; the only change this writes
  is the one sentence.

  `down/0` is a no-op: restoring the list would restore a permission the
  measurement does not support.
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
