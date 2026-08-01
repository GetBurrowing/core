defmodule Platform.Orchestration.HeartbeatSchedulerContextAnchorTest do
  @moduledoc """
  Task 019fba28 v2 stage 1 — `insert_before_context/2` must splice each phase
  contract in BEFORE the dispatch body's closing guidance block, not append it
  at the end.

  ## Why these assertions are byte offsets and not `assert prompt =~ …`

  The regression this file guards did not remove the contract from the prompt.
  It MOVED it. v1 stages 1 and 3 deleted the "The attention signal …" sentence
  from `dispatch.in_progress` and `dispatch.in_review`, and that sentence was
  simultaneously the only anchor `insert_before_context/2` knew about, so the
  post-processor fell through to its `prompt <> addition` clause and the Stage
  Execution Contract landed after the federation preamble instead of before it.
  A presence assertion passes in BOTH layouts and therefore measures nothing.
  Every check here compares `:binary.match/2` offsets.

  Each test carries exactly ONE offset assertion. Two offset assertions in one
  test would leave the second unreachable under any mutation that reddens the
  first, and the mutation control for this stage is meant to demonstrate that
  each render path is individually covered.

  ## Why this file is `Platform.DataCase` and not `ExUnit.Case`

  The DB-row path is the one every deployed environment takes.
  `heartbeat_scheduler_test.exs` is `use ExUnit.Case` with no DB ownership, so
  `PromptTemplates.render_template/2` rescues its `Repo` call there and every
  `dispatch_prompt/4` silently takes the hardcoded fallback. That is exactly
  how this regression shipped green across 10,164 tests. Coverage added there
  would not have caught it and would not catch the next one.

  For the same reason the setup below ASSERTS the seeded rows exist and equal
  `PromptTemplates.default_content_for_slug/1` rather than overwriting them
  with a probe body. A test that replaces the content it protects can only
  prove the assign is wired — see
  `heartbeat_scheduler_federation_preamble_test.exs`, which looks like coverage
  for this and is not.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Orchestration.PromptTemplate
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo

  @execution_contract "## Stage Execution Contract"
  @review_contract "## Review Validation Contract"

  # Trailing block of the rendered DB bodies: `{{federation_preamble}}` is the
  # last line of both dispatch.in_progress and dispatch.in_review, and it sits
  # AFTER the anchor paragraph. If the contract's offset is greater than this
  # one, the contract was appended rather than spliced.
  @db_tail_block "## Subagent-spawn discipline"

  # The hardcoded fallbacks do NOT interpolate `PromptTemplates.federation_preamble/0`
  # — they close with `@evidence_workflow_reference` followed by
  # `@skills_reference`. Their equivalent trailing landmark is the evidence
  # workflow heading, which likewise sits after the anchor paragraph.
  @fallback_tail_block "## Submitting evidence for a `manual_approval` validation"

  @dispatch_slugs ["dispatch.in_progress", "dispatch.in_review"]

  setup do
    # Prove we are exercising the real seeded bodies before asserting anything
    # about where text lands inside them.
    for slug <- @dispatch_slugs do
      row = Repo.get_by(PromptTemplate, slug: slug)

      assert row,
             "#{slug} is not seeded in this database; this test must exercise the DB-row " <>
               "path, not the hardcoded fallback"

      assert row.content == PromptTemplates.default_content_for_slug(slug),
             "#{slug}'s seeded body has drifted from default_content_for_slug/1; the offsets " <>
               "asserted here would be measuring an operator-customized row, not the shipped one"
    end

    :ok
  end

  describe "insert_before_context/2 against the seeded DB rows" do
    test "in_progress splices the Stage Execution Contract before the federation preamble" do
      prompt = HeartbeatScheduler.dispatch_prompt(in_progress_task(), plan(), execution_stage())

      assert offset!(prompt, @execution_contract) < offset!(prompt, @db_tail_block),
             """
             The Stage Execution Contract landed AFTER the federation preamble in the rendered \
             dispatch.in_progress row, which means insert_before_context/2 found none of \
             HeartbeatScheduler.context_anchors/0 and fell through to `prompt <> addition`. \
             Either the anchor sentence was removed from the dispatch.in_progress body, or the \
             new sentence that replaced it has not been added to @context_anchors.
             """
    end

    test "in_review splices the Review Validation Contract before the federation preamble" do
      prompt = HeartbeatScheduler.dispatch_prompt(in_review_task(), plan(), review_stage())

      assert offset!(prompt, @review_contract) < offset!(prompt, @db_tail_block),
             """
             The Review Validation Contract landed AFTER the federation preamble in the rendered \
             dispatch.in_review row. Same cause as the in_progress case: no entry of \
             HeartbeatScheduler.context_anchors/0 is present in the body.
             """
    end
  end

  describe "insert_before_context/2 against the hardcoded fallbacks" do
    setup do
      # Delete inside the sandbox transaction so `render_template/2` returns
      # `{:error, :not_found}` and `dispatch_prompt/4` takes the fallback. The
      # rollback restores both rows.
      {2, _} = Repo.delete_all(from(t in PromptTemplate, where: t.slug in ^@dispatch_slugs))

      for slug <- @dispatch_slugs do
        refute Repo.get_by(PromptTemplate, slug: slug),
               "#{slug} still resolves; this describe block is not exercising the fallback"
      end

      :ok
    end

    test "in_progress splices the Stage Execution Contract before the evidence workflow block" do
      prompt = HeartbeatScheduler.dispatch_prompt(in_progress_task(), plan(), execution_stage())

      assert offset!(prompt, @execution_contract) < offset!(prompt, @fallback_tail_block),
             """
             The Stage Execution Contract landed AFTER the evidence-workflow block in the \
             hardcoded in_progress fallback, so insert_before_context/2 matched no anchor there \
             either. The fallback carries the same closing paragraph as the DB body \
             (heartbeat_scheduler.ex:1009) and must stay in sync with @context_anchors.
             """
    end

    test "in_review splices the Review Validation Contract before the evidence workflow block" do
      prompt = HeartbeatScheduler.dispatch_prompt(in_review_task(), plan(), review_stage())

      assert offset!(prompt, @review_contract) < offset!(prompt, @fallback_tail_block),
             """
             The Review Validation Contract landed AFTER the evidence-workflow block in the \
             hardcoded in_review fallback (heartbeat_scheduler.ex:1073).
             """
    end
  end

  describe "@context_anchors contract" do
    test "declares the old sentence first and the replacement paragraph second" do
      assert HeartbeatScheduler.context_anchors() == [
               "\nThe attention signal",
               "\nThe Stage Description block above"
             ],
             """
             Order is load-bearing: the FIRST entry present in the prompt wins, so the legacy \
             sentence must stay at the head to preserve the pre-branch insertion point on the \
             slugs that still carry it (dispatch.planning, dispatch.deploying, dispatch.fallback, \
             dispatch.review_e2e).
             """
    end

    test "every anchor begins with a newline so it can only match at a line start" do
      for anchor <- HeartbeatScheduler.context_anchors() do
        assert String.starts_with?(anchor, "\n"),
               """
               #{inspect(anchor)} does not begin with a newline. dispatch.in_review contains a \
               mid-line, lower-cased "the Stage Description block above" in its first-turn rule; \
               an anchor that can match mid-line would splice the contract into the middle of a \
               bullet.
               """
      end
    end
  end

  describe "operator-customized row carrying no anchor at all" do
    setup do
      row = Repo.get_by(PromptTemplate, slug: "dispatch.in_progress")

      {:ok, _} =
        PromptTemplates.update_template(row, %{
          content: """
          Plan approved — execute the current stage.

          Task: {{task_title}}
          {{stage_info}}
          {{stage_description}}

          OPERATOR-TAIL-SENTINEL
          """
        })

      :ok
    end

    test "still receives the contract, appended, rather than losing it" do
      prompt = HeartbeatScheduler.dispatch_prompt(in_progress_task(), plan(), execution_stage())

      assert offset!(prompt, @execution_contract) > offset!(prompt, "OPERATOR-TAIL-SENTINEL"),
             """
             The `prompt <> addition` fallback clause of insert_before_context/2 was removed or \
             changed. A row an operator has rewritten may legitimately carry neither anchor, and \
             appending the contract at the end is still better than dropping it.
             """
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp project, do: %{repo_url: "https://github.com/StartupSuite/core", default_branch: "main"}

  defp in_progress_task do
    %{
      id: "019fba28-anchor-in-progress",
      title: "Context anchor probe (execution)",
      description: "Execution-phase anchor probe",
      status: "in_progress",
      priority: "medium",
      project: project()
    }
  end

  defp in_review_task do
    %{
      id: "019fba28-anchor-in-review",
      title: "Context anchor probe (review)",
      description: "Review-phase anchor probe",
      status: "in_review",
      priority: "medium",
      project: project()
    }
  end

  defp plan, do: %{version: 1, stages: [%{}]}

  defp execution_stage do
    %{
      id: "019fba28-stage-exec",
      position: 1,
      name: "coding",
      description: "ANCHOR-PROBE-STAGE-DESCRIPTION — the planner's authored specification.",
      validations: [%{id: "val-test-1", kind: "test_pass"}]
    }
  end

  defp review_stage do
    %{
      id: "019fba28-stage-review",
      position: 1,
      name: "review",
      description: "ANCHOR-PROBE-STAGE-DESCRIPTION — the planner's authored specification.",
      validations: [%{id: "val-manual-1", kind: "manual_approval"}]
    }
  end

  defp offset!(prompt, needle) do
    case :binary.match(prompt, needle) do
      {start, _len} ->
        start

      :nomatch ->
        flunk("""
        expected #{inspect(needle)} to be present in the rendered prompt so its byte offset \
        could be compared, but it is absent entirely. Rendered prompt was #{byte_size(prompt)} \
        bytes.
        """)
    end
  end
end
