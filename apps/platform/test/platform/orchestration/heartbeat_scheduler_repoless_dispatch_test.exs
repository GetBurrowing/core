defmodule Platform.Orchestration.HeartbeatSchedulerRepolessDispatchTest do
  @moduledoc """
  Task 019fba28 v2 stage 2 — a task whose project resolves to no usable repo
  must lose the "## Git Workflow (CRITICAL)" block and NOTHING ELSE.

  ## What went wrong, measured

  On this branch before the fix, a repo-less execution dispatch rendered
  **1,873 bytes** where the repo-PRESENT render of the same fixture was
  **11,841**. (The plan's own artifacts, taken on a slightly smaller fixture,
  read 2,004 B against origin/main's 10,027 B.) Everything after the git block
  was gone: the federation preamble, the skills reference, the
  evidence-workflow chain, and the paragraphs telling the agent that the Stage
  Description block is its specification.

  Cause, in three parts: `in_progress_prompt/4` assigned
  `git_workflow_block` unconditionally; `non_stack_git_workflow_section/1`
  emits its heading regardless of the resolved repo set; and
  `maybe_strip_git_workflow/2`'s regex ended
  `(?=\\nThe attention signal|\\z)`, so once v1 deleted that sentence from the
  dispatch bodies the lazy quantifier ran to end-of-string.

  ## Why every assertion here is an ASSERT and not a REFUTE

  The three pre-existing repo-less tests — `heartbeat_scheduler_test.exs:381`,
  `:1856` and `:2058` — are all `refute prompt =~ "Git Workflow (CRITICAL)"`.
  A refute cannot distinguish "correctly absent" from "catastrophically
  deleted": an over-consuming strip satisfies it perfectly. That is precisely
  how an 8,000-byte amputation shipped green across 10,164 tests. The refutes
  are kept below, but only standing next to the survival asserts that make
  them mean something.

  ## Why `Platform.DataCase`

  The DB-row path is the one every deployed environment takes.
  `heartbeat_scheduler_test.exs` is `use ExUnit.Case` with no DB ownership, so
  `PromptTemplates.render_template/2` rescues its `Repo` call there and every
  `dispatch_prompt/4` silently takes the hardcoded fallback. Note also that
  `heartbeat_scheduler_federation_preamble_test.exs` IS DataCase-backed but
  substitutes a probe body of `{{federation_preamble}}` alone and uses a real
  `repo_url`; it looks like coverage for this and is not. The setup below
  asserts the seeded rows equal `default_content_for_slug/1` rather than
  overwriting them, so the shipped body is what is under test.

  ## The two changes are covered by two different tests, deliberately

  Producer-side suppression (the `git_workflow_block` assign) and the
  fail-closed strip fix the same symptom by different routes, so each needs a
  fixture the other does not rescue:

    * `"an operator row that interpolates the block but carries no anchor"`
      isolates the PRODUCER. Revert the conditional assign and this reds: the
      block is rendered into a body the strip cannot bound, so it survives into
      the prompt and a warning is logged.
    * `"an operator row that hardcodes a git section and carries no anchor"`
      isolates the STRIP. Restore `|\\z` in the lookahead and this reds: the
      tail sentinel is deleted. The producer change cannot help here, because
      the operator wrote the section by hand.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Orchestration.PromptTemplate
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo

  # The federation preamble's own heading. Last block of both rendered dispatch
  # bodies, and the first thing an over-consuming strip destroys.
  @preamble "## Subagent-spawn discipline"

  # Nested INSIDE the federation preamble today. Asserted separately so that a
  # future split of the two is caught rather than silently uncovered.
  @skills "## Skill discovery — do this BEFORE you start executing"

  # The paragraph v1 stages 1 and 3 substituted for the deleted "The attention
  # signal …" sentence, and the second entry of `context_anchors/0`.
  #
  # The two dispatch bodies do NOT share a sentence, only the anchor PREFIX:
  # dispatch.in_progress (prompt_templates.ex:562) continues "… is your
  # specification — it is the planner's own authored text", while
  # dispatch.in_review (:785) continues "… is the planner's own authored
  # specification for this stage". Assert each slug's own literal, and the
  # shared prefix — which is what `context_anchors/0` actually matches on —
  # separately.
  @anchor_prefix "\nThe Stage Description block above"
  @spec_paragraph "The Stage Description block above is your specification"
  @review_spec_paragraph "The Stage Description block above is the planner's own authored specification"

  @stage_description_heading "## Stage Description (authored by the planner"

  @git_heading "## Git Workflow (CRITICAL)"
  @placeholder_repo "example.invalid"

  @top_sentinel "REPOLESS-SENTINEL-TOP"
  @tail_sentinel "REPOLESS-SENTINEL-TAIL"

  # DISTINCT from the two sentinels above, and that distinctness is
  # load-bearing. The operator-row describe blocks below put their trailing
  # text AFTER a git section and assert it survives. Reusing @tail_sentinel
  # there made the assertion vacuous: the sentinel also appears inside
  # {{stage_description}}, which renders BEFORE the git block and is therefore
  # never at risk, so the assertion passed under a mutation that deleted the
  # operator's actual tail. Caught by the M2 control, which reddened on a later
  # assertion than it should have.
  @operator_tail "OPERATOR-TAIL-SENTINEL"

  # Distinguishing fragment of the fail-closed `Logger.warning`.
  @unbounded_warning "cannot be bounded"

  # Measured on this fixture at ca17b4cd (pre-fix) and after the fix. Quoted in
  # the byte_size failure message so a future reader gets the scale of the
  # regression rather than a bare comparison.
  @measured_regression "repo-PRESENT rendered 11,841 B; the branch regression rendered 1,873 B " <>
                         "on this same fixture (the plan's artifacts read 10,027 B against " <>
                         "origin/main and 2,004 B on the branch)"

  @dispatch_slugs ["dispatch.in_progress", "dispatch.in_review"]

  setup do
    for slug <- @dispatch_slugs do
      row = Repo.get_by(PromptTemplate, slug: slug)

      assert row,
             "#{slug} is not seeded in this database; this test must exercise the DB-row " <>
               "path, not the hardcoded fallback"

      assert row.content == PromptTemplates.default_content_for_slug(slug),
             "#{slug}'s seeded body has drifted from default_content_for_slug/1; this file " <>
               "would be measuring an operator-customized row, not the shipped one"
    end

    :ok
  end

  describe "repo-less dispatch.in_progress against the seeded default row" do
    test "the federation preamble survives" do
      assert repoless_in_progress() =~ @preamble,
             """
             The federation preamble is gone from a repo-less execution dispatch. Either the \
             git block is being produced for a task with no usable repo, or \
             maybe_strip_git_workflow/2 has regained an end-of-string branch and deleted \
             everything after the git heading. #{@measured_regression}
             """
    end

    test "the skills reference survives" do
      assert repoless_in_progress() =~ @skills,
             """
             The skill-discovery block is gone from a repo-less execution dispatch. It is \
             nested inside the federation preamble today, so this normally fails alongside \
             that assertion; failing ALONE means the two have been split and the skills half \
             is no longer covered by the preamble assertion.
             """
    end

    test "the paragraph naming the stage description as the specification survives" do
      assert repoless_in_progress() =~ @spec_paragraph,
             """
             The "#{@spec_paragraph} …" paragraph is gone from a repo-less execution dispatch. \
             This paragraph is also the second entry of HeartbeatScheduler.context_anchors/0, \
             so losing it breaks contract insertion and git-block bounding at the same time.
             """
    end

    test "the planner's stage description survives, heading and both sentinels" do
      prompt = repoless_in_progress()

      assert prompt =~ @stage_description_heading
      assert prompt =~ @top_sentinel

      assert prompt =~ @tail_sentinel,
             """
             The stage description was truncated in a repo-less execution dispatch: its opening \
             sentinel survived but #{@tail_sentinel} did not. #{@measured_regression}
             """
    end

    test "the prompt is still a full-size dispatch" do
      # ITS OWN TEST on purpose. The first failing assertion ends a test, so a
      # byte_size check sharing a body with the string assertions above would
      # be unreachable under exactly the mutation it exists to catch.
      prompt = repoless_in_progress()

      assert byte_size(prompt) > 9_000,
             """
             A repo-less execution dispatch rendered only #{byte_size(prompt)} bytes. \
             #{@measured_regression}
             """
    end

    test "the git block and the placeholder repo url are absent" do
      prompt = repoless_in_progress()

      refute prompt =~ @git_heading,
             "a task with no usable repo was told to clone one"

      refute prompt =~ @placeholder_repo,
             "the placeholder repo url leaked into the dispatch"
    end
  end

  describe "repo-less dispatch.in_review against the seeded default row" do
    # dispatch.in_review interpolates no `{{git_workflow_block}}` and
    # `enrich_in_review_prompt/2` runs no strip, so these are a CONTROL: they
    # were green before this stage and must stay green. They pin that the fix
    # to in_progress did not reach across into the review body.
    test "the federation preamble, skills reference and specification paragraph survive" do
      prompt = repoless_in_review()

      assert prompt =~ @preamble
      assert prompt =~ @skills
      assert prompt =~ @review_spec_paragraph

      assert prompt =~ @anchor_prefix,
             """
             dispatch.in_review no longer carries a line-leading \
             "#{String.trim_leading(@anchor_prefix)} …", so the second entry of \
             HeartbeatScheduler.context_anchors/0 matches nothing here. Note the body ALSO \
             contains a mid-line, lower-cased "the Stage Description block above" in its \
             first-turn rule (prompt_templates.ex:776) which is NOT the anchor — the anchor is \
             the paragraph at :785 and both entries are newline-prefixed so they can only match \
             at a line start.
             """
    end

    test "the planner's stage description survives, heading and both sentinels" do
      prompt = repoless_in_review()

      assert prompt =~ @stage_description_heading
      assert prompt =~ @top_sentinel
      assert prompt =~ @tail_sentinel
    end

    test "the prompt is still a full-size dispatch" do
      prompt = repoless_in_review()

      assert byte_size(prompt) > 9_000,
             "a repo-less review dispatch rendered only #{byte_size(prompt)} bytes"
    end

    test "the git block and the placeholder repo url are absent" do
      prompt = repoless_in_review()

      refute prompt =~ @git_heading
      refute prompt =~ @placeholder_repo
    end
  end

  describe "repo-PRESENT control" do
    # Shows the change is surgical rather than a blanket suppression: the same
    # fixture shape with a real github url still gets the git block, AND still
    # gets the preamble.
    test "in_progress renders the git workflow block AND the federation preamble" do
      prompt = in_progress_prompt("https://github.com/StartupSuite/core")

      assert prompt =~ @git_heading,
             """
             A task with a real repo lost its git workflow block. The producer-side \
             suppression in in_progress_prompt/4 is gated on deploy_repos_present?/1 and must \
             not fire here.
             """

      assert prompt =~ @preamble
      assert prompt =~ "https://github.com/StartupSuite/core"
      assert byte_size(prompt) > 9_000
    end
  end

  describe "operator row that interpolates the block but carries no context anchor" do
    # PRODUCER-SIDE coverage. The body still uses `{{git_workflow_block}}`, so
    # only the conditional assign keeps the block out. There is no anchor after
    # the placeholder, so if the block IS produced the fail-closed strip cannot
    # bound it and has to leave it in place — which is what this refutes.
    setup do
      customize!("dispatch.in_progress", """
      Plan approved — execute the current stage.

      Task: {{task_title}}
      {{stage_info}}
      {{stage_description}}
      {{git_workflow_block}}
      #{@operator_tail}
      """)
    end

    test "no git block is produced at all" do
      prompt = repoless_in_progress()

      refute prompt =~ @git_heading,
             """
             A git workflow block was produced for a task with no usable repo. The \
             `git_workflow_block` assign in in_progress_prompt/4 must be gated on \
             deploy_repos_present?/1 — suppressing at the producer is what removes this class \
             of defect. The block landed in a body with no context anchor after it, so the \
             fail-closed strip correctly declined to delete it.
             """
    end

    test "nothing is left for the strip to bound, so no warning is logged" do
      log = capture_log(fn -> repoless_in_progress() end)

      refute log =~ @unbounded_warning,
             """
             maybe_strip_git_workflow/2 logged its fail-closed warning, which means a git block \
             reached the rendered body. Nothing should have been produced to strip.
             """
    end

    test "the operator's own trailing text survives" do
      assert repoless_in_progress() =~ @operator_tail
    end
  end

  describe "operator row that hardcodes a git section and carries no context anchor" do
    # STRIP-SIDE coverage. The operator wrote the section by hand rather than
    # interpolating, so producer-side suppression cannot help. The strip must
    # refuse to delete an unbounded block and say so.
    #
    # ONE assertion of interest per test throughout this describe block. These
    # are the assertions the M2 mutation control has to reach, and the first
    # failing assertion ends a test.
    setup do
      customize!("dispatch.in_progress", """
      Plan approved — execute the current stage.

      Task: {{task_title}}
      {{stage_info}}
      {{stage_description}}

      #{@git_heading}
      Repository: https://github.com/operator/hardcoded
      Base branch: main

      #{@operator_tail}
      """)
    end

    test "text after an unbounded git heading is not deleted to end-of-string" do
      assert repoless_in_progress() =~ @operator_tail,
             """
             Everything after a hardcoded "#{@git_heading}" heading was deleted. That is the \
             019fba28 regression exactly: maybe_strip_git_workflow/2 has an end-of-string \
             branch again. It must bound the block on HeartbeatScheduler.context_anchors/0 \
             and, finding none, leave the prompt alone. #{@measured_regression}
             """
    end

    test "the unbounded git block itself is left in place" do
      assert repoless_in_progress() =~ @git_heading,
             """
             The unbounded git block was removed after all. Leaving a stale git block in a \
             repo-less dispatch is the ACCEPTED failure mode here — it is cosmetic, where \
             over-deleting is a silent capability loss. If the strip found a terminator, this \
             fixture is no longer exercising the unbounded path and the M2 mutation control \
             proves nothing.
             """
    end

    test "the refusal is logged, naming the task and the anchor list" do
      log = capture_log(fn -> repoless_in_progress() end)

      assert log =~ @unbounded_warning,
             """
             The fail-closed path took effect silently. An operator who deletes the anchor \
             sentence from a customized row gets a degraded dispatch with no signal at all \
             unless this warning fires.
             """

      assert log =~ repoless_task_id()
      assert log =~ "The Stage Description block above"
    end
  end

  describe "operator row that hardcodes a git section AND carries a context anchor" do
    setup do
      customize!("dispatch.in_progress", """
      Plan approved — execute the current stage.

      Task: {{task_title}}
      {{stage_info}}
      {{stage_description}}

      #{@git_heading}
      Repository: https://github.com/operator/hardcoded
      Base branch: main

      #{@spec_paragraph} — it is the planner's own authored text.

      #{@operator_tail}
      """)
    end

    test "the bounded git section is removed" do
      refute repoless_in_progress() =~ @git_heading,
             "a bounded git block was left in place; the strip stopped working entirely"
    end

    test "the strip stops at the terminator instead of running past it" do
      assert repoless_in_progress() =~ @operator_tail,
             """
             The strip consumed past its terminator. It must stop at the FIRST \
             context_anchors/0 entry occurring after the heading — here \
             "#{@spec_paragraph}", the second entry — and never run to end-of-string.
             """
    end

    test "the terminator sentence itself survives" do
      assert repoless_in_progress() =~ @spec_paragraph,
             """
             The anchor the strip bounded on was consumed along with the git block. The \
             terminator is a LOOKAHEAD — it marks where deletion stops, and must not itself \
             be deleted.
             """
    end

    test "no warning is logged when the block could be bounded" do
      log = capture_log(fn -> repoless_in_progress() end)
      refute log =~ @unbounded_warning
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp customize!(slug, content) do
    row = Repo.get_by(PromptTemplate, slug: slug)
    {:ok, _} = PromptTemplates.update_template(row, %{content: content})
    :ok
  end

  defp repoless_in_progress, do: in_progress_prompt("https://example.invalid/no-repo")

  defp repoless_in_review do
    HeartbeatScheduler.dispatch_prompt(
      task("https://example.invalid/no-repo", "in_review"),
      plan(),
      review_stage()
    )
  end

  defp in_progress_prompt(repo_url) do
    HeartbeatScheduler.dispatch_prompt(task(repo_url, "in_progress"), plan(), execution_stage())
  end

  defp repoless_task_id, do: task("https://example.invalid/no-repo", "in_progress").id

  defp task(repo_url, status) do
    %{
      id: "019fba28-repoless-#{status}",
      title: "Repo-less dispatch probe",
      description: "Repo-less dispatch probe",
      status: status,
      priority: "medium",
      project: %{repo_url: repo_url, default_branch: "main"}
    }
  end

  defp plan, do: %{version: 1, stages: [%{}]}

  defp stage_description do
    "#{@top_sentinel} — the planner's authored specification for this stage, whose every " <>
      "byte must reach the executor. #{@tail_sentinel}"
  end

  defp execution_stage do
    %{
      id: "019fba28-repoless-stage-exec",
      position: 1,
      name: "coding",
      description: stage_description(),
      validations: [%{id: "val-test-1", kind: "test_pass"}]
    }
  end

  defp review_stage do
    %{
      id: "019fba28-repoless-stage-review",
      position: 1,
      name: "review",
      description: stage_description(),
      validations: [%{id: "val-manual-1", kind: "manual_approval"}]
    }
  end
end
